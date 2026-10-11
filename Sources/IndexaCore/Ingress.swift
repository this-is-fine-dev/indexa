import Foundation
import Vapor

public enum Ingress {
    private static let maximumRequestBytes = 32 * 1024 * 1024
    private struct RetranscriptionResponse: Encodable { let transcription: String }

    public static func install(on app: Application, database: Database, configuration: Configuration, secret: String,
                               chat: HermesChatRelay? = nil,
                               transcribe: @escaping @Sendable (Data) async throws -> String = { try await LocalWhisper.transcribe($0) }) throws {
        try configuration.validate()
        guard !secret.isEmpty else { throw IndexaError("secret_unavailable") }
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = configuration.port
        app.routes.defaultMaxBodySize = "32mb"
        app.logger.logLevel = .critical
        app.get("health") { _ in ["status":"ok"] }
        app.on(.POST,"pebble","v1","ingest",body:.collect(maxSize:"32mb")) { request async throws -> Response in
            guard let buffer = request.body.data, buffer.readableBytes <= maximumRequestBytes else { throw Abort(.payloadTooLarge) }
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
            let parts = try decode(buffer,boundary:boundary)
            let fields = parts.fields
            let suppliedText = fields["transcription"]
            guard fields["client"] == "ring", let recorded = fields["recordedAt"], !recorded.isEmpty,
                  recorded.utf8.allSatisfy({(48...57).contains($0)}), let ms = Double(recorded), ms.isFinite, ms > 0,
                  ms/1000 <= Date().timeIntervalSince1970+300,
                  parts.audio != nil || suppliedText?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false,
                  (suppliedText?.utf8.count ?? 0) <= 16384,
                  fields["test"] == nil || fields["test"] == "true",
                  fields["reprocess"] == nil || fields["reprocess"] == "true" else { throw Abort(.unprocessableEntity,reason:"invalid_fields") }
            guard fields["test"] != "true" || parts.audio == nil else { throw Abort(.unprocessableEntity,reason:"invalid_test_event") }
            let reprocess = fields["reprocess"] == "true"
            guard !reprocess || (parts.audio != nil && suppliedText == nil && fields["test"] != "true") else { throw Abort(.unprocessableEntity,reason:"invalid_reprocess") }
            if let version = headers["x-index-webhook-version"], version != "1" { throw Abort(.badRequest,reason:"unsupported_version") }
            let isTest = fields["test"] == "true" || headers["x-index-test"] == "true" || headers["x-index-trigger"] == "test-event"
            if configuration.signedWebhooks {
                guard (fields["test"] == "true") == (headers["x-index-test"] == "true") else { throw Abort(.badRequest,reason:"inconsistent_test") }
            }
            let trigger = headers["x-index-trigger"] ?? (isTest ? "test-event" : "double-click-hold")
            guard isTest ? trigger == "test-event" : ["single-click-hold","double-click-hold"].contains(trigger) else { throw Abort(.unprocessableEntity,reason:"unsupported_trigger") }
            let payloadDigest = parts.audio.map(PebbleAuthentication.digest) ?? PebbleAuthentication.digest(Data((fields["transcription"] ?? "").utf8))
            let canonical = try JSONEncoder().encode([recorded,trigger,isTest ? "1":"0",payloadDigest])
            let digest = PebbleAuthentication.digest(canonical)
            let sourceID = headers["x-index-delivery"] ?? "legacy:\(digest)"
            guard (1...128).contains(sourceID.utf8.count) else { throw Abort(.badRequest) }
            do {
                let text: String
                if let audio = parts.audio { text = try await transcribe(audio) }
                else { text = fields["transcription"]! }
                if reprocess {
                    return Response(
                        status:.accepted,
                        headers:["Content-Type":"application/json","Cache-Control":"no-store"],
                        body:.init(data:try JSONEncoder().encode(RetranscriptionResponse(transcription:text)))
                    )
                }
                let result = try await database.accept(source:"pebble",sourceID:sourceID,text:text,recorded:ms/1000,digest:digest,isTest:isTest)
                return Response(status:.accepted,headers:["Content-Type":"application/json"],body:.init(string:"{\"id\":\"\(result.id)\",\"duplicate\":\(result.duplicate),\"test\":\(isTest)}"))
            } catch let error as IndexaError where error.code == "delivery_id_conflict" { throw Abort(.conflict,reason:error.code) }
            catch { throw Abort(.serviceUnavailable,reason:parts.audio == nil ? "durable_commit_failed" : "transcription_failed") }
        }
        if let chat {
            app.on(.POST,"pebble","v1","chat","history",body:.collect(maxSize:"16kb")) { request async throws -> Response in
                let body = request.body.data.map { Data($0.readableBytesView) } ?? Data()
                try Self.verifyChatRequest(request, body: body, secret: secret, trigger: "ios-history")
                let messages = try await chat.history()
                return Response(status: .ok, headers: ["Content-Type":"application/json", "Cache-Control":"no-store"],
                                body: .init(data: try JSONEncoder().encode(messages)))
            }
            app.on(.POST,"pebble","v1","chat","stream",body:.collect(maxSize:"96kb")) { request async throws -> Response in
                let buffer = request.body.data
                guard let buffer, buffer.readableBytes <= 96 * 1024 else { throw Abort(.payloadTooLarge) }
                let body = Data(buffer.readableBytesView)
                try Self.verifyChatRequest(request, body: body, secret: secret, trigger: "ios-chat")
                guard let prompt = try? JSONDecoder().decode(HermesChatPrompt.self, from: body) else {
                    throw Abort(.badRequest, reason: "invalid_chat_request")
                }
                let text = prompt.input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.utf8.count <= 12_000 else { throw Abort(.unprocessableEntity, reason: "invalid_chat_text") }
                return Response(status: .ok,
                    headers: ["Content-Type":"text/event-stream", "Cache-Control":"no-store", "X-Accel-Buffering":"no"],
                    body: .init(managedAsyncStream: { writer in try await chat.stream(text, to: writer) }))
            }
        }
    }

    private static func verifyChatRequest(_ request: Request, body: Data, secret: String, trigger: String) throws {
        var headers = [String:String]()
        for (name, value) in request.headers {
            let key = name.lowercased()
            if key.hasPrefix("x-index-") {
                guard headers[key] == nil, value.utf8.count <= 1024 else { throw Abort(.badRequest) }
                headers[key] = value
            }
        }
        guard headers["x-index-trigger"] == trigger else { throw Abort(.unauthorized, reason: "unauthorized") }
        do { try PebbleAuthentication.verify(body: body, headers: headers, secret: secret, signed: true) }
        catch { throw Abort(.unauthorized, reason: "unauthorized") }
    }

    private struct Parts { var fields = [String:String](); var audio: Data? }
    private static func decode(_ buffer: ByteBuffer, boundary: String) throws -> Parts {
        let parser = MultipartParser(boundary:boundary)
        var part = MultipartPart(body:""), parts = [MultipartPart]()
        parser.onHeader = { part.headers.add(name:$0,value:$1) }
        parser.onBody = { part.body.writeBuffer(&$0) }
        parser.onPartComplete = { parts.append(part); part = MultipartPart(body:"") }
        do { try parser.execute(buffer) } catch { throw Abort(.badRequest,reason:"malformed_multipart") }
        guard !parts.isEmpty, parts.count <= 16,
              Data(buffer.readableBytesView).range(of:Data("\r\n--\(boundary)--".utf8)) != nil else { throw Abort(.badRequest,reason:"malformed_multipart") }
        var result = Parts()
        for p in parts {
            guard let name = p.name else { throw Abort(.badRequest,reason:"invalid_field") }
            if name == "audio" {
                let filename = p.filename?.lowercased() ?? ""
                let contentType = p.headers.first(name:"Content-Type")?.lowercased() ?? ""
                let audio = Data(p.body.readableBytesView)
                let isM4a = filename.hasSuffix(".m4a") && contentType.hasPrefix("audio/mp4")
                let isWav = filename.hasSuffix(".wav") && contentType == "audio/wav" &&
                    audio.count >= 44 && audio.starts(with:Data("RIFF".utf8)) && audio[8..<12] == Data("WAVE".utf8)
                guard result.audio == nil, audio.count > 0, isM4a || isWav else { throw Abort(.unsupportedMediaType,reason:"invalid_audio") }
                result.audio = audio
            } else {
                guard ["client","recordedAt","transcription","test","reprocess"].contains(name), p.filename == nil, result.fields[name] == nil,
                      let value = String(data:Data(p.body.readableBytesView),encoding:.utf8) else { throw Abort(.badRequest,reason:"invalid_field") }
                result.fields[name] = value
            }
        }
        return result
    }
}
