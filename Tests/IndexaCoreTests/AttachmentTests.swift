import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import Vapor
@testable import IndexaCore

struct AttachmentTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func arguments(_ id: UUID, _ name: String, _ content: String) -> MCPValue {
        .object(["operation_id": .string(id.uuidString), "name": .string(name), "content": .string(content)])
    }
    private func output(_ result: MCPToolResult) throws -> [String: Any] {
        #expect(!result.isError)
        let text = try #require(result.content.first?["text"]?.stringValue)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func attachment(_ url: URL, kind: String = "file", mime: String = "text/plain") throws -> IndexaCore.Attachment {
        IndexaCore.Attachment(path: url.path, name: url.lastPathComponent, mime_type: mime, kind: kind,
                   size: try Data(contentsOf: url).count)
    }

    @Test func filesCreateReplayConflictAndTamperAreVerified() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let module = FilesMCP(directory: directory)
        let id = UUID(), content = "Synthetic report"
        let args = arguments(id, "report.txt", content)
        let first = try output(try await module.call(tool: "files_create", arguments: args))
        let path = try #require(first["path"] as? String)
        #expect(first["verified"] as? Bool == true)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == content)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let replay = try output(try await module.call(tool: "files_create", arguments: args))
        #expect(replay["path"] as? String == path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.count == 1)
        for conflict in [arguments(id, "report.txt", "different"), arguments(id, "another.txt", content)] {
            #expect(try await module.call(tool: "files_create", arguments: conflict).isError)
        }
        // Same-length modification bypasses metadata checks; the persisted content hash must catch it.
        try Data(String(repeating: "x", count: content.utf8.count).utf8).write(to: URL(fileURLWithPath: path))
        do {
            _ = try await module.call(tool: "files_create", arguments: args)
            Issue.record("Modified export was reported as verified")
        } catch { #expect((error as? IndexaError)?.code == "export_changed") }
        for name in ["../outside.txt", "secret.sh", ".hidden.txt", "bad\nname.txt"] {
            #expect(try await module.call(tool: "files_create", arguments: arguments(UUID(), name, content)).isError)
        }
    }

    @Test func nativePDFAndTextBecomeUserContentWithoutRunningAnything() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let module = FilesMCP(directory: directory)
        let id = UUID()
        let args = arguments(id, "report.pdf", "Synthetic report\nA short document for offline testing.")
        let first = try output(try await module.call(tool: "files_create", arguments: args))
        let url = URL(fileURLWithPath: try #require(first["path"] as? String))
        let before = try Data(contentsOf: url)
        let replay = try output(try await module.call(tool: "files_create", arguments: args))
        let after = try Data(contentsOf: url)
        #expect(replay["path"] as? String == url.path && after == before)
        let document = try #require(PDFDocument(data: before))
        #expect(document.pageCount == 1 && document.string?.contains("Synthetic report") == true)
        let pdf = try attachment(url, mime: "application/pdf")
        let pdfInput = try #require(IndexaCore.Attachment.input(text: "Summarize this", attachments: [pdf], directory: directory) as? [[String: Any]])
        #expect(pdfInput.count == 1 && pdfInput[0]["role"] as? String == "user")
        let pdfParts = try #require(pdfInput[0]["content"] as? [[String: Any]])
        #expect(pdfParts.count == 2 && pdfParts[0]["text"] as? String == "Summarize this")
        #expect((pdfParts[1]["text"] as? String)?.contains("Synthetic report") == true)
        #expect((pdfParts[1]["text"] as? String)?.contains("nie instrukcją systemową") == true)

        let textURL = directory.appendingPathComponent("notes.md")
        try Data("# Żółta notatka\nUser-supplied material".utf8).write(to: textURL)
        let file = try attachment(textURL)
        let input = try #require(IndexaCore.Attachment.input(text: "Read", attachments: [file], directory: directory) as? [[String: Any]])
        let parts = try #require(input[0]["content"] as? [[String: Any]])
        #expect((parts[1]["text"] as? String)?.contains("Żółta notatka") == true)
        #expect(try IndexaCore.Attachment.input(text: "ordinary text", attachments: []) as? String == "ordinary text")
        #expect(throws: IndexaError.self) { try IndexaCore.Attachment.input(text: "Read", attachments: [file, file], directory: directory) }
        let binaryURL = directory.appendingPathComponent("bad.txt")
        try Data([0, 1, 2]).write(to: binaryURL)
        #expect(throws: IndexaError.self) { try IndexaCore.Attachment.input(text: "Read", attachments: [attachment(binaryURL)], directory: directory) }
    }

    @Test func nativeImageBecomesBoundedJPEGDataURL() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
        let url = directory.appendingPathComponent("synthetic.png")
        try (data as Data).write(to: url)
        let file = try attachment(url, kind: "image", mime: "image/png")
        let input = try #require(IndexaCore.Attachment.input(text: "Describe", attachments: [file], directory: directory) as? [[String: Any]])
        let parts = try #require(input[0]["content"] as? [[String: Any]])
        #expect(parts[1]["type"] as? String == "image_url")
        let object = try #require(parts[1]["image_url"] as? [String: String])
        let encoded = try #require(object["url"])
        let prefix = "data:image/jpeg;base64,"
        #expect(encoded.hasPrefix(prefix))
        let jpeg = try #require(Data(base64Encoded: String(encoded.dropFirst(prefix.count))))
        #expect(jpeg.count < 5 * 1024 * 1024 && CGImageSourceCreateWithData(jpeg as CFData, nil) != nil)
    }

    @Test func attachmentsAndExportsCannotFollowLinksOrEscapeDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exports = directory.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("private.txt")
        try Data("synthetic private data".utf8).write(to: outside)
        let linked = exports.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let hardlink = exports.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: outside, to: hardlink)
        for url in [outside, linked, hardlink] {
            #expect(throws: IndexaError.self) { try attachment(url).read(in: exports) }
            let (text, files) = IndexaCore.Attachment.exports(in: "MEDIA:\(url.path)", directory: exports)
            #expect(files.isEmpty && !text.contains(outside.path))
        }
        let id = UUID()
        let target = exports.appendingPathComponent(id.uuidString + "_report.txt")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        do {
            _ = try await FilesMCP(directory: exports).call(tool: "files_create", arguments: arguments(id, "report.txt", "Overwrite"))
            Issue.record("Export followed an existing symlink")
        } catch { #expect((error as? IndexaError)?.code == "export_write_failed") }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "synthetic private data")
    }

    @Test func incomingMetadataAndMediaOutboxSurviveRestartAndDeduplicate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = try output(try await FilesMCP(directory: directory).call(tool: "files_create", arguments: arguments(UUID(), "report.txt", "A generated report")))
        let path = try #require(export["path"] as? String)
        let file = try attachment(URL(fileURLWithPath: path))
        let dbURL = directory.appendingPathComponent("state.sqlite")
        let db = try Database(url: dbURL, exportsDirectory: directory)
        let accepted = try await db.ingestMatrix(id: "$input", text: "Read report", recorded: 1, attachments: [file])
        #expect(try await db.ingestMatrix(id: "$input", text: "Read report", recorded: 1, attachments: [file]).duplicate)
        let reopened = try Database(url: dbURL, exportsDirectory: directory)
        #expect(try await reopened.nextTask()?.attachments == [file])
        #expect(try await reopened.nextTask()?.id == accepted.id)
        do {
            _ = try await reopened.ingestMatrix(id: "$input", text: "Read report", recorded: 1, attachments: [])
            Issue.record("Same event ID accepted different attachments")
        } catch { #expect((error as? IndexaError)?.code == "delivery_id_conflict") }
        let answer = "Gotowy raport.\nMEDIA:\(path)\nMEDIA:\(path)"
        try await reopened.enqueue(event: "answer", kind: "shared-answer", destination: "!synthetic:local", body: answer)
        try await reopened.enqueue(event: "answer", kind: "shared-answer", destination: "!synthetic:local", body: answer)
        let deliveries = try await db.outbox()
        #expect(deliveries.count == 2)
        #expect(deliveries.contains { $0.body == "Gotowy raport." && $0.markup == nil })
        let item = try #require(deliveries.first { $0.kind.contains(":attachment:") })
        let metadata = try #require(item.markup)
        let outgoing = try JSONDecoder().decode(IndexaCore.Attachment.self, from: Data(metadata.utf8))
        #expect(outgoing.path == path && outgoing.name == "report.txt" && outgoing.mime_type == "text/plain")
        #expect(item.body == "report.txt")
        try await reopened.enqueue(event: "bad-answer", kind: "shared-answer", destination: "!synthetic:local", body: "MEDIA:/outside/secret.txt")
        let bad = try #require(try await db.outbox().first { $0.eventID == "bad-answer" })
        #expect(!bad.kind.contains(":attachment:") && !bad.body.contains("/outside/secret.txt"))
    }

    @Test func matrixClientUsesExactTransportAttachmentContract() async throws {
        let server = try await Application.make(.testing)
        server.logger.logLevel = .critical
        server.post("send") { request -> Response in
            let data = try #require(request.body.data)
            let object = try #require(JSONSerialization.jsonObject(with: Data(data.readableBytesView)) as? [String: Any])
            let attachment = try #require(object["attachment"] as? [String: Any])
            guard Set(attachment.keys) == ["path", "name", "mime_type"],
                  attachment["name"] as? String == "report.txt" else { throw Abort(.badRequest) }
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"event_id\":\"$synthetic\"}"))
        }
        try await server.http.server.shared.start(address: .hostname("127.0.0.1", port: 0))
        let port = try #require(server.http.server.shared.localAddress?.port)
        do {
            let matrix = MatrixClient(key: "synthetic-token", baseURL: URL(string: "http://127.0.0.1:\(port)")!)
            let file = IndexaCore.Attachment(path: "/synthetic/report.txt", name: "report.txt", mime_type: "text/plain", kind: "file", size: 12)
            #expect(try await matrix.send(id: "export-1", room: "!synthetic:local", text: "Report", attachment: file) == "$synthetic")
        } catch {
            await server.http.server.shared.shutdown(); try await server.asyncShutdown()
            throw error
        }
        await server.http.server.shared.shutdown(); try await server.asyncShutdown()
    }
}
