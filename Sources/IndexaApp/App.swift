import SwiftUI
import IndexaCore
import AppKit

@main
struct IndexaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var runtime=Runtime.shared
    var body: some Scene {
        MenuBarExtra("Indexa · \(runtime.summary)", systemImage: runtime.statusSymbol) { MenuView(runtime:runtime) }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Ustawienia…") { AppWindow.shared.show(.settings) }.keyboardShortcut(",")
                }
            }
    }
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) { NSApp.setActivationPolicy(.accessory);Updater.shared.start();Task { await Runtime.shared.start() } }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {
        AppWindow.shared.show()
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
