import Foundation

public struct TailscaleSnapshot {
    public let state:String,host:String
    public let online:Bool,serve:Bool,funnel:Bool
    public var webhookURL:String { host.isEmpty || !online || !serve || funnel ? "" : "https://\(host):8443/pebble/v1/ingest" }
}
public struct TailscaleClient {
    public init() {}
    private func request(_ path:String) async throws -> [String:Any] {
        let directory=URL(fileURLWithPath:"/Library/Tailscale")
        let port=try FileManager.default.destinationOfSymbolicLink(atPath:directory.appendingPathComponent("ipnport").path)
        guard let number=Int(port),(1...65535).contains(number) else { throw IndexaError("tailscale_port_invalid") }
        let token=try String(contentsOf:directory.appendingPathComponent("sameuserproof-\(port)"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        guard !token.isEmpty else { throw IndexaError("tailscale_auth_unavailable") }
        var request=URLRequest(url:URL(string:"http://127.0.0.1:\(port)/localapi/v0/\(path)")!)
        request.timeoutInterval=10
        request.setValue("Basic "+Data(":\(token)".utf8).base64EncodedString(),forHTTPHeaderField:"Authorization")
        request.setValue("local-tailscaled.sock",forHTTPHeaderField:"Host")
        let session=URLSession(configuration:.ephemeral,delegate:LocalNoRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode == 200 else { throw IndexaError("tailscale_api_rejected") }
        guard let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { throw IndexaError("tailscale_response_invalid") }
        return result
    }
    public func snapshot() async throws -> TailscaleSnapshot {
        let status=try await request("status?peers=false"),config=try await request("serve-config")
        return Self.snapshot(status:status,serveConfig:config)
    }
    public static func snapshot(status:[String:Any],serveConfig config:[String:Any]) -> TailscaleSnapshot {
        let me=status["Self"] as? [String:Any] ?? [:]
        let host=(me["DNSName"] as? String ?? "").trimmingCharacters(in:CharacterSet(charactersIn:"."))
        let validHost=host.hasSuffix(".ts.net") && host.utf8.allSatisfy({(97...122).contains($0) || (48...57).contains($0) || [45,46].contains($0)})
        let handlers=(((config["Web"] as? [String:Any])?[host+":8443"] as? [String:Any])?["Handlers"] as? [String:Any]) ?? [:]
        let proxy=(handlers["/"] as? [String:Any])?["Proxy"] as? String
        let tls=((config["TCP"] as? [String:Any])?["8443"] as? [String:Any])?["HTTPS"] as? Bool == true
        let overridden=handlers.keys.contains { $0 != "/" && "/pebble/v1/ingest".hasPrefix($0) }
        let publicAccess=(config["AllowFunnel"] as? [String:Bool])?[host+":8443"] == true
        let enabled=validHost && tls && !overridden && proxy == "http://127.0.0.1:18763"
        return TailscaleSnapshot(state:status["BackendState"] as? String ?? "Unknown",host:validHost ? host : "",online:status["BackendState"] as? String == "Running" && me["Online"] as? Bool == true,serve:enabled && !publicAccess,funnel:publicAccess)
    }
}

private final class LocalNoRedirect:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}
