import Foundation

public struct APIError: Error, LocalizedError {
    public let code: Int
    public let retryAfter: Double?
    public let ambiguous: Bool
    public var errorDescription: String? { "api_\(code)" }
    public init(code:Int,retryAfter:Double? = nil,ambiguous:Bool = false) { self.code=code;self.retryAfter=retryAfter;self.ambiguous=ambiguous }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class HTTPJSON: @unchecked Sendable {
    private let session: URLSession
    public init(timeout:TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout + 5
        session = URLSession(configuration:config,delegate:NoRedirects(),delegateQueue:nil)
    }
    deinit { session.invalidateAndCancel() }
    public func request(_ url:URL,method:String = "GET",body:Data? = nil,headers:[String:String] = [:]) async throws -> [String:Any] {
        var request = URLRequest(url:url)
        request.httpMethod=method;request.httpBody=body
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        for (key,value) in headers { request.setValue(value,forHTTPHeaderField:key) }
        let data:Data, response:URLResponse
        do { (data,response) = try await session.data(for:request) }
        catch let e as URLError {
            let safe = [URLError.cannotFindHost,.cannotConnectToHost,.notConnectedToInternet,.dnsLookupFailed].contains(e.code)
            throw APIError(code:e.errorCode,ambiguous:!safe)
        } catch { throw APIError(code:-1,ambiguous:true) }
        guard let http=response as? HTTPURLResponse else { throw APIError(code:-2,ambiguous:true) }
        guard data.count <= 4*1024*1024 else { throw APIError(code:-3,ambiguous:true) }
        let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        guard (200..<300).contains(http.statusCode) else {
            let retry=((object?["parameters"] as? [String:Any])?["retry_after"] as? NSNumber)?.doubleValue
            throw APIError(code:http.statusCode,retryAfter:retry,ambiguous:http.statusCode >= 500 && object?["sent"] as? Bool != false)
        }
        guard let object else { throw APIError(code:-4,ambiguous:true) }
        return object
    }
}

public struct RunStatus {
    public let state:String
    public let output:String?
    public let approvalID:String?
    public let approvalDescription:String?
    public var createdAt:Double? = nil
    public var completedAt:Double? = nil
}
public struct HermesClient {
    public let baseURL:URL
    let key:String
    let http:HTTPJSON
    public init(baseURL:URL,key:String,http:HTTPJSON = HTTPJSON()) { self.baseURL=baseURL;self.key=key;self.http=http }
    public static let instructions = """
    Jesteś agentem aplikacji Indexa. Rozmawiaj po polsku, zwięźle. Bieżący input jest poleceniem użytkownika; historia jest tylko kontekstem.
    Wykonuj polecenia użytkownika dostępnymi narzędziami; nie ograniczaj rozmowy do notatek. Uprawnienia narzędzi ustala użytkownik w Indexie; nie próbuj obchodzić odmowy inną drogą.
    Do Apple Notes używaj MCP indexa-notes: notes_get, notes_create, notes_append, wyłącznie w folderze Indexa. Nie deklaruj zapisu bez verified=true potwierdzającego odczyt zapisanego note_id.
    Kalendarz: używaj MCP indexa-calendar; calendar_events czyta wszystkie istniejące kalendarze domyślnie. Przypomnienia: używaj MCP indexa-reminders. Daty podawaj z jawną strefą czasową, zachowuj operation_id przy ponowieniach, a przy needs_review nie powtarzaj zapisu z nowym ID. Nie deklaruj sukcesu bez verified=true. Alert wydarzenia lub przypomnienia nie jest budzikiem iPhone’a.
    Zapamiętuj note_id w kontekście, aby 'dopisz' dotyczyło tej samej notatki. Przy braku celu lub niejasności zadaj zwykłe pytanie w końcowej odpowiedzi; nie używaj clarify ani desktopowych formularzy.
    Nie wykonuj działań finansowych, nie usuwaj notatek. Nie wysyłaj wiadomości innym narzędziem. Wynik trafia do prywatnego pokoju Matrix właściciela; nie kopiuj całej notatki bez prośby.
    Unknown/needs_review oznacza niepewny skutek; nie powtarzaj zapisu. Każdy nowy zapis ma operation_id UUID, retry tego samego zapisu używa tego samego operation_id.
    """
    public func payload(input:String,session:String) throws -> Data {
        try JSONSerialization.data(withJSONObject:["input":input,"session_id":session,"instructions":Self.instructions],options:.sortedKeys)
    }
    public func capabilities() async throws -> [String:Any] {
        try await http.request(baseURL.appendingPathComponent("v1/capabilities"),headers:["Authorization":"Bearer \(key)"])
    }
    public func submit(payload:Data,key idempotency:String) async throws -> String {
        let result=try await http.request(baseURL.appendingPathComponent("v1/runs"),method:"POST",body:payload,headers:["Authorization":"Bearer \(key)","Idempotency-Key":idempotency])
        guard let id=result["run_id"] as? String, Self.validID(id) else { throw APIError(code:-5,ambiguous:true) }
        return id
    }
    private static func validID(_ id:String) -> Bool { !id.isEmpty && id.count <= 256 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
    public func status(_ run:String) async throws -> RunStatus {
        guard Self.validID(run) else { throw IndexaError("invalid_run_id") }
        let result=try await http.request(baseURL.appendingPathComponent("v1/runs/\(run)"),headers:["Authorization":"Bearer \(key)"])
        guard let state=result["status"] as? String, ["queued","started","running","waiting_for_approval","stopping","completed","failed","cancelled","interrupted"].contains(state) else { throw IndexaError("unknown_run_state") }
        let approval=result["approval"] as? [String:Any]
        return RunStatus(state:state,output:result["output"] as? String,approvalID:approval?["request_id"] as? String,approvalDescription:approval?["description"] as? String,createdAt:(result["created_at"] as? NSNumber)?.doubleValue,completedAt:(result["updated_at"] as? NSNumber)?.doubleValue)
    }
    public func stop(_ run:String) async throws {
        guard Self.validID(run) else { throw IndexaError("invalid_run_id") }
        _ = try await http.request(baseURL.appendingPathComponent("v1/runs/\(run)/stop"),method:"POST",body:Data("{}".utf8),headers:["Authorization":"Bearer \(key)"])
    }
    public func approve(run:String,request:String,choice:String) async throws {
        guard Self.validID(run), ["once","deny"].contains(choice), !request.isEmpty else { throw IndexaError("invalid_approval") }
        let body=try JSONSerialization.data(withJSONObject:["choice":choice,"request_id":request])
        let result=try await http.request(baseURL.appendingPathComponent("v1/runs/\(run)/approval"),method:"POST",body:body,headers:["Authorization":"Bearer \(key)"])
        guard (result["resolved"] as? Int) == 1 else { throw IndexaError("approval_not_resolved") }
    }
}

public struct MatrixClient {
    private let key:String,baseURL:URL,http:HTTPJSON
    public init(key:String,baseURL:URL = URL(string:"http://127.0.0.1:18764")!,http:HTTPJSON = HTTPJSON()) { self.key=key;self.baseURL=baseURL;self.http=http }
    public func call(_ path:String,_ body:[String:Any]? = nil) async throws -> [String:Any] {
        guard ["health","events","ack","send","typing","devices","trust","qr/start","qr/status","qr/command"].contains(path) else { throw IndexaError("invalid_matrix_operation") }
        return try await http.request(baseURL.appendingPathComponent(path),method:body == nil ? "GET":"POST",body:try body.map{try JSONSerialization.data(withJSONObject:$0)},headers:["Authorization":"Bearer \(key)"])
    }
    public func send(id:String,room:String,text:String) async throws -> String {
        let result=try await call("send",["id":id,"room":room,"text":text])
        guard let event=result["event_id"] as? String,!event.isEmpty else { throw APIError(code:-7,ambiguous:true) }
        return event
    }
}

public enum MatrixIdentity {
    public static func allowed(room:String,user:String,ownerRoom:String?,ownerUser:String?) -> Bool {
        !room.isEmpty && !user.isEmpty && room == ownerRoom && user == ownerUser
    }
}
