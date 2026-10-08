import Foundation
import Vapor

public enum Ingress {
    public static func install(on app: Application, database: Database, configuration: Configuration, secret: String) throws {
        try configuration.validate()
        guard !secret.isEmpty else { throw IndexaError("secret_unavailable") }
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = configuration.port
        app.routes.defaultMaxBodySize = "256kb"
        app.logger.logLevel = .critical
        app.get("health") { _ in ["status":"ok"] }
        app.on(.POST,"pebble","v1","ingest",body:.collect(maxSize:"256kb")) { request async throws -> Response in
            guard let buffer = request.body.data, buffer.readableBytes <= 262144 else { throw Abort(.payloadTooLarge) }
            var headers = [String:String]()
            for (name,value) in request.headers {
                let name = name.lowercased()
                if name == "authorization" || name.hasPrefix("x-index-") {
                    guard headers[name] == nil, value.utf8.count <= 1024 else { throw Abort(.badRequest) }
                    headers[name] = value
                }
            }
            let data = Data(buffer.readableBytesView)
            do { try PebbleAuthentication.verify(body:data,headers:headers,secret:secret,signed:configuration.signedWebhooks) }
            catch { throw Abort(.unauthorized,reason:"unauthorized") }
            guard request.headers.contentType?.type == "multipart", request.headers.contentType?.subType == "form-data",
                  let boundary = request.headers.contentType?.parameters["boundary"], (1...70).contains(boundary.utf8.count) else { throw Abort(.unsupportedMediaType) }
            let fields = try decode(buffer,boundary:boundary)
            guard fields["client"] == "ring", let recorded = fields["recordedAt"], !recorded.isEmpty,
                  recorded.utf8.allSatisfy({(48...57).contains($0)}), let ms = Double(recorded), ms.isFinite, ms > 0,
                  ms/1000 <= Date().timeIntervalSince1970+300,
                  let text = fields["transcription"], !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 16384,
                  fields["test"] == nil || fields["test"] == "true" else { throw Abort(.unprocessableEntity,reason:"invalid_fields") }
            if let version = headers["x-index-webhook-version"], version != "1" { throw Abort(.badRequest,reason:"unsupported_version") }
            let isTest = fields["test"] == "true" || headers["x-index-test"] == "true" || headers["x-index-trigger"] == "test-event"
            if configuration.signedWebhooks {
                guard (fields["test"] == "true") == (headers["x-index-test"] == "true") else { throw Abort(.badRequest,reason:"inconsistent_test") }
            }
            let trigger = headers["x-index-trigger"] ?? (isTest ? "test-event" : "double-click-hold")
            guard isTest ? trigger == "test-event" : ["single-click-hold","double-click-hold"].contains(trigger) else { throw Abort(.unprocessableEntity,reason:"unsupported_trigger") }
            let canonical = try JSONEncoder().encode([recorded,trigger,isTest ? "1":"0",text])
            let digest = PebbleAuthentication.digest(canonical)
            let sourceID = headers["x-index-delivery"] ?? "legacy:\(digest)"
            guard (1...128).contains(sourceID.utf8.count) else { throw Abort(.badRequest) }
            do {
                let result = try await database.accept(source:"pebble",sourceID:sourceID,text:text,recorded:ms/1000,digest:digest,isTest:isTest)
                return Response(status:.accepted,headers:["Content-Type":"application/json"],body:.init(string:"{\"id\":\"\(result.id)\",\"duplicate\":\(result.duplicate),\"test\":\(isTest)}"))
            } catch let error as IndexaError where error.code == "delivery_id_conflict" { throw Abort(.conflict,reason:error.code) }
            catch { throw Abort(.serviceUnavailable,reason:"durable_commit_failed") }
        }
    }

    private static func decode(_ buffer: ByteBuffer, boundary: String) throws -> [String:String] {
        // MultipartKit owns HTTP multipart parsing; callbacks only enforce our text-only contract.
        let parser = MultipartParser(boundary:boundary)
        var part = MultipartPart(body:""), parts = [MultipartPart]()
        parser.onHeader = { part.headers.add(name:$0,value:$1) }
        parser.onBody = { part.body.writeBuffer(&$0) }
        parser.onPartComplete = { parts.append(part); part = MultipartPart(body:"") }
        do { try parser.execute(buffer) } catch { throw Abort(.badRequest,reason:"malformed_multipart") }
        guard !parts.isEmpty, parts.count <= 16,
              Data(buffer.readableBytesView).range(of:Data("\r\n--\(boundary)--".utf8)) != nil else { throw Abort(.badRequest,reason:"malformed_multipart") }
        var fields = [String:String]()
        for p in parts {
            guard p.filename == nil, p.name != "audio" else { throw Abort(.unsupportedMediaType,reason:"select_transcription_only") }
            guard let name = p.name, fields[name] == nil,
                  let value = String(data:Data(p.body.readableBytesView),encoding:.utf8) else { throw Abort(.badRequest,reason:"invalid_field") }
            fields[name] = value
        }
        return fields
    }
}
