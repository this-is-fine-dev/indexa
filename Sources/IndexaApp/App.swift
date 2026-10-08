import SwiftUI
import IndexaCore
import AppKit

@main
struct IndexaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var runtime=Runtime.shared
    var body: some Scene {
        MenuBarExtra("Indexa · \(runtime.summary)", systemImage: runtime.statusSymbol) { MenuView(runtime:runtime) }
        Window("Indexa",id:"indexa") { Dashboard(runtime:runtime).frame(minWidth:720,minHeight:580) }
            .defaultSize(width:800,height:660)
        Settings { SettingsView(runtime:runtime).frame(width:650,height:590) }
    }
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) { NSApp.setActivationPolicy(.accessory);Updater.shared.start();Task { await Runtime.shared.start() } }
    private var fallbackWindow:NSWindow?
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {
        if let window=sender.windows.first(where:{$0.title == "Indexa"}) {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window=NSWindow(contentViewController:NSHostingController(rootView:Dashboard(runtime:.shared).frame(minWidth:720,minHeight:580)))
            window.title="Indexa";window.setContentSize(NSSize(width:800,height:660));window.isReleasedWhenClosed=false
            window.center();window.makeKeyAndOrderFront(nil);fallbackWindow=window
        }
        sender.activate(ignoringOtherApps:true)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        let active=Runtime.shared.tasks.contains{["submitting","running","waiting_for_approval","stopping"].contains($0.state)}
        if active {
            let alert=NSAlert();alert.messageText="Hermes może nadal wykonywać zadanie"
            alert.informativeText="Zamknięcie Indexa zatrzyma odbiór i wyśle zakończenie gatewaya. Wcześniejsze zmiany nie zostaną cofnięte."
            alert.addButton(withTitle:"Zostań");alert.addButton(withTitle:"Zakończ")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        Task { let stopped=await Runtime.shared.shutdown();sender.reply(toApplicationShouldTerminate:stopped) }
        return .terminateLater
    }
}
