import SwiftUI
import WebKit
import CoreImage.CIFilterBuiltins

struct QRLoginView:View {
    @ObservedObject var runtime:Runtime
    @Environment(\.dismiss) private var dismiss
    @State private var state=[String:Any]()
    @State private var code=""
    @State private var error=""
    @State private var busy=false
    @State private var consentURL:URL?
    @State private var deadline=Date.distantFuture
    @State private var disconnected=false
    @State private var visible=true
    @State private var generation=UUID()
    private var phase:String { state["state"] as? String ?? "starting" }
    var body:some View {
        VStack(spacing:16) {
            Text("Logowanie Element X").font(.title2)
            switch phase {
            case "qr":
                Text("Włącz Tailscale na iPhonie. W Element X wybierz logowanie kodem QR i zeskanuj ten kod.")
                if let encoded=state["data"] as? String,let picture=qrImage(encoded) {
                    Image(nsImage:picture).interpolation(.none).resizable().frame(width:280,height:280)
                        .padding(16).background(.white).accessibilityLabel("Kod QR do logowania Element X")
                }
                TimelineView(.periodic(from:.now,by:1)) { context in
                    let seconds=max(0,Int(deadline.timeIntervalSince(context.date)))
                    Text(seconds > 0 ? "Pozostało około \(seconds) s na parowanie." : "Sprawdzanie wyniku parowania…").font(.caption)
                }
            case "code":
                Text("Wpisz kod wyświetlony przez Element X na Twoim iPhonie.")
                TextField("Kod z telefonu",text:$code).frame(width:140)
                Button("Potwierdź kod") {
                    guard let value=Int(code), (0..<100).contains(value) else { return }
                    Task { await command(["code":value]) }
                }.disabled(busy || Int(code).map{ !(0..<100).contains($0) } != false)
            case "consent":
                Text("Potwierdź poniżej logowanie swojego iPhone’a. Porównaj kod urządzenia z kodem w Element X.")
                if let url=consentURL {
                    PairingConsentView(url:url,username:runtime.matrixOwner,password:runtime.ownerPassword())
                        .frame(minHeight:380)
                }
            case "done":
                Label("Element X został zalogowany.",systemImage:"checkmark.circle.fill").foregroundStyle(.green)
            case "error":
                Text("Parowanie nie powiodło się lub kod wygasł. Sprawdź Tailscale na iPhonie i spróbuj ponownie.")
                Button("Wygeneruj nowy kod") { Task { await start() } }.disabled(busy)
            default:
                ProgressView()
                Text("Trwa bezpieczne parowanie…")
            }
            if busy { ProgressView().controlSize(.small) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            if disconnected && phase != "error" {
                Text("Połączenie zostanie ponowione automatycznie.").font(.caption)
                Button("Wygeneruj nowy kod") { Task { await start() } }.disabled(busy)
            }
            Button(phase == "done" ? "Gotowe":"Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width:600).frame(minHeight:240)
        .task {
            await start()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds:500_000_000)
                    if busy || phase == "done" || phase == "error" { continue }
                    let requestGeneration=generation
                    let next=try await runtime.pairing("status")
                    guard !Task.isCancelled,visible else { return }
                    guard requestGeneration == generation else { continue }
                    if let current=state["id"] as? String,next["id"] as? String != current {
                        state["state"]="error";error="Sesja parowania została zakończona. Wygeneruj nowy kod.";continue
                    }
                    state=next;disconnected=false;error=""
                    if let raw=next["url"] as? String,let url=URL(string:raw),sameOrigin(url,URL(string:runtime.matrixHomeserver)) { consentURL=url }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    self.error="Brak połączenia z lokalnym serwerem parowania.";disconnected=true
                    do { try await Task.sleep(nanoseconds:2_000_000_000) } catch { return }
                }
            }
        }
        .onDisappear {
            visible=false;generation=UUID()
            if phase != "done",let id=state["id"] as? String { Task { _ = try? await runtime.pairing("command",["id":id,"cancel":true]) } }
        }
    }
    private func start() async {
        guard !busy,visible else { return }
        busy=true;defer { busy=false };error="";code="";consentURL=nil;disconnected=false;deadline=Date().addingTimeInterval(180);state=["state":"starting"]
        generation=UUID()
        do {
            let next=try await runtime.pairing("start",[:])
            guard visible,!Task.isCancelled else {
                if let id=next["id"] as? String { _ = try? await runtime.pairing("command",["id":id,"cancel":true]) };return
            }
            state=next
        } catch {
            guard visible,!Task.isCancelled else { return }
            self.error="Nie można rozpocząć parowania. Jeśli żądanie dotarło do serwera, poprzednia próba wygaśnie automatycznie.";state=["state":"error"]
        }
    }
    private func command(_ value:[String:Any]) async {
        busy=true;defer { busy=false }
        guard let id=state["id"] as? String else { return }
        do {
            let next=try await runtime.pairing("command",value.merging(["id":id]){_,new in new})
            guard visible,!Task.isCancelled else { return };state=next
        }
        catch { self.error="Nie udało się potwierdzić tego kroku. Sprawdzamy stan sesji.";disconnected=true }
    }
    private func qrImage(_ encoded:String) -> NSImage? {
        // Matrix uses unpadded Base64. QR contains raw MSC4108 bytes, not this text.
        let padded=encoded+String(repeating:"=",count:(4-encoded.count%4)%4)
        guard let bytes=Data(base64Encoded:padded) else { return nil }
        let filter=CIFilter.qrCodeGenerator();filter.message=bytes;filter.correctionLevel="M"
        guard let output=filter.outputImage,let cg=CIContext().createCGImage(output,from:output.extent) else { return nil }
        return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
    }
}

private func sameOrigin(_ url:URL,_ expected:URL?) -> Bool {
    guard let expected else { return false }
    return url.scheme == "https" && url.host == expected.host && url.port == expected.port && url.user == nil && url.password == nil
}

private struct PairingConsentView:NSViewRepresentable {
    let url:URL,username:String,password:String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> WKWebView {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let view=WKWebView(frame:.zero,configuration:config)
        view.navigationDelegate=context.coordinator
        view.load(URLRequest(url:url))
        return view
    }
    func updateNSView(_ view:WKWebView,context:Context) {}
    final class Coordinator:NSObject,WKNavigationDelegate {
        let parent:PairingConsentView
        init(_ parent:PairingConsentView) { self.parent=parent }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
            decisionHandler(action.request.url.map{sameOrigin($0,parent.url)} == true ? .allow:.cancel)
        }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
            guard let url=webView.url,sameOrigin(url,parent.url),url.path == "/login" else { return }
            // Fill only the pinned local MAS login form. The user submits and grants consent.
            webView.callAsyncJavaScript("""
                const user=document.querySelector('input[name="username"]');
                const pass=document.querySelector('input[name="password"]');
                if(user && pass) { user.value=username;pass.value=password; }
                """,arguments:["username":parent.username,"password":parent.password],in:nil,in:.defaultClient,completionHandler:nil)
        }
    }
}
