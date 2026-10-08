import Foundation

public struct TailscaleSnapshot {
    public let state:String,host:String
    public let online:Bool,serve:Bool,funnel:Bool
    public var webhookURL:String { host.isEmpty ? "" : "https://\(host)/pebble/v1/ingest" }
}
public struct TailscaleClient {
    public init() {}
    private func request(_ path:String,body:Data? = nil,etag:String? = nil) async throws -> ([String:Any],String?) {
        let directory=URL(fileURLWithPath:"/Library/Tailscale")
        let port=try FileManager.default.destinationOfSymbolicLink(atPath:directory.appendingPathComponent("ipnport").path)
        guard let number=Int(port),(1...65535).contains(number) else { throw IndexaError("tailscale_port_invalid") }
        let token=try String(contentsOf:directory.appendingPathComponent("sameuserproof-\(port)"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        guard !token.isEmpty else { throw IndexaError("tailscale_auth_unavailable") }
        var request=URLRequest(url:URL(string:"http://127.0.0.1:\(port)/localapi/v0/\(path)")!)
        request.timeoutInterval=10;request.httpMethod=body == nil ? "GET":"POST";request.httpBody=body
        request.setValue("Basic "+Data(":\(token)".utf8).base64EncodedString(),forHTTPHeaderField:"Authorization")
        request.setValue("local-tailscaled.sock",forHTTPHeaderField:"Host")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let etag { request.setValue(etag,forHTTPHeaderField:"If-Match") }
        let session=URLSession(configuration:.ephemeral,delegate:LocalNoRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode == 200 else { throw IndexaError("tailscale_api_rejected") }
        let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        return (result,http.value(forHTTPHeaderField:"Etag"))
    }
    public func snapshot(port:Int) async throws -> TailscaleSnapshot {
        let (status,_)=try await request("status?peers=false"),(config,_)=try await request("serve-config")
        let me=status["Self"] as? [String:Any] ?? [:]
        let host=(me["DNSName"] as? String ?? "").trimmingCharacters(in:CharacterSet(charactersIn:"."))
        let handlers=(((config["Web"] as? [String:Any])?[host+":443"] as? [String:Any])?["Handlers"] as? [String:Any]) ?? [:]
        let proxy=(handlers["/"] as? [String:Any])?["Proxy"] as? String
        let publicAccess=(config["AllowFunnel"] as? [String:Bool])?[host+":443"] == true
        let enabled=proxy == "http://127.0.0.1:\(port)"
        return TailscaleSnapshot(state:status["BackendState"] as? String ?? "Unknown",host:host,online:me["Online"] as? Bool == true,serve:enabled && !publicAccess,funnel:enabled && publicAccess)
    }
    public func setServe(port:Int,enabled:Bool) async throws {
        let snapshot=try await snapshot(port:port)
        guard snapshot.online,snapshot.state == "Running" else { throw IndexaError("tailscale_offline") }
        let (current,etag)=try await request("serve-config")
        guard let etag,!etag.isEmpty else { throw IndexaError("tailscale_etag_missing") }
        let config=try Self.serveConfiguration(current:current,host:snapshot.host,port:port,enabled:enabled)
        _ = try await request("serve-config",body:JSONSerialization.data(withJSONObject:config),etag:etag)
        let after=try await self.snapshot(port:port)
        guard after.serve == enabled && !after.funnel else { throw IndexaError("tailscale_readback_failed") }
    }
    public static func serveConfiguration(current:[String:Any],host:String,port:Int,enabled:Bool) throws -> [String:Any] {
        guard host.hasSuffix(".ts.net"),host.utf8.allSatisfy({(97...122).contains($0) || (48...57).contains($0) || [45,46].contains($0)}),(1024...65535).contains(port) else { throw IndexaError("invalid_serve_target") }
        var config=current,tcp=current["TCP"] as? [String:Any] ?? [:],web=current["Web"] as? [String:Any] ?? [:],allow=current["AllowFunnel"] as? [String:Bool] ?? [:]
        let target=host+":443",proxy="http://127.0.0.1:\(port)"
        let existing=web[target] as? [String:Any]
        let handlers=existing?["Handlers"] as? [String:Any]
        let owned=handlers?.count == 1 && (handlers?["/"] as? [String:Any])?["Proxy"] as? String == proxy
        if (tcp["443"] != nil || existing != nil || web.keys.contains(where:{$0.hasSuffix(":443")})) && !owned { throw IndexaError("serve_port_in_use") }
        if enabled {
            tcp["443"]=["HTTPS":true];web[target]=["Handlers":["/":["Proxy":proxy]]];allow.removeValue(forKey:target)
        } else {
            guard owned else { throw IndexaError("serve_not_owned") }
            web.removeValue(forKey:target);allow.removeValue(forKey:target)
            if !web.keys.contains(where:{$0.hasSuffix(":443")}) { tcp.removeValue(forKey:"443") }
        }
        config["TCP"]=tcp;config["Web"]=web;config["AllowFunnel"]=allow
        return config
    }
}

private final class LocalNoRedirect:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}
