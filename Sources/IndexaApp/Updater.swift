import AppKit
import Sparkle

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published private(set) var status = "Aktualizacje nie są jeszcze skonfigurowane."
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    func start() {
        guard controller == nil,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        status = "Po pobraniu aktualizacji wybierz „Zainstaluj i uruchom ponownie”. Indexa sama wznowi usługi."
    }

    func checkForUpdates() {
        start()
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "Aktualizacje nie są jeszcze skonfigurowane"
            alert.informativeText = "Ta wersja nie ma publicznego kanału aktualizacji. Prywatne repozytorium GitHub nie udostępnia plików bez logowania."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        guard !controller.updater.canCheckForUpdates else { present(); return }
        observation?.invalidate()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in self?.observation?.invalidate(); self?.observation = nil; self?.present() }
        }
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
