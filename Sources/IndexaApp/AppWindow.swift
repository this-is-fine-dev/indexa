import AppKit
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case dashboard, matrix, pebble, settings, diagnostics
    var id: Self { self }
    var title: String {
        switch self {
        case .dashboard: return "Przegląd"
        case .matrix: return "Matrix"
        case .pebble: return "Pierścień"
        case .settings: return "Ustawienia"
        case .diagnostics: return "Diagnostyka"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .matrix: return "bubble.left.and.bubble.right"
        case .pebble: return "waveform"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// Every entry point (tray, Finder and in-app navigation) reuses this window.
@MainActor
final class AppWindow: ObservableObject {
    static let shared = AppWindow()
    @Published var page: AppPage = .dashboard
    private var window: NSWindow?

    func show(_ destination: AppPage? = nil) {
        if let destination { page = destination }
        // Finish the status-menu tracking cycle before claiming keyboard focus.
        DispatchQueue.main.async { self.present() }
    }

    private func present() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Indexa"
            created.identifier = NSUserInterfaceItemIdentifier("indexa")
            created.isReleasedWhenClosed = false
            created.contentMinSize = NSSize(width: 800, height: 650)
            created.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            created.contentViewController = NSHostingController(rootView: MainView(runtime: .shared))
            created.center()
            created.setFrameAutosaveName("IndexaMainWindow")
            window = created
        }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
