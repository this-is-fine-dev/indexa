import Foundation
import Testing
import VaporTesting
@testable import IndexaCore

func fixture(_ fields: [(String,String)], boundary: String = "indexa-fixture") -> ByteBuffer {
    ByteBuffer(string: fields.map { "--\(boundary)\r\nContent-Disposition: form-data; name=\"\($0.0)\"\r\n\r\n\($0.1)\r\n" }.joined() + "--\(boundary)--\r\n")
}

struct IngressTests {
    @Test func rejectsUnauthorizedAndPersistsBefore202() async throws {
        let db = try Database(url:nil)
        let app = try await Application.make(.testing)
        var config = Configuration(); config.signedWebhooks = false
        try Ingress.install(on:app, database:db, configuration:config, secret:"fixture-token")
        let body = fixture([("client","ring"),("recordedAt","1700000000000"),("transcription","Zapisz żółtą notatkę")])
        var headers: HTTPHeaders = ["Content-Type":"multipart/form-data; boundary=indexa-fixture"]
        try await app.test(.POST,"/pebble/v1/ingest",headers:headers,body:body) { #expect($0.status == .unauthorized) }
        #expect(try await db.tasks().isEmpty)
        headers.add(name:"Authorization",value:"Bearer fixture-token")
        try await app.test(.POST,"/pebble/v1/ingest",headers:headers,body:body) { response async throws in
            #expect(response.status == .accepted)
            #expect(try await db.tasks().count == 1)
        }
        try await app.test(.POST,"/pebble/v1/ingest",headers:headers,body:body) { #expect($0.status == .accepted) }
        #expect(try await db.tasks().count == 1)
        try await app.test(.GET,"/v1/runs") { #expect($0.status == .notFound) }
        try await app.asyncShutdown()
    }
    @Test func testEventAudioDuplicateFieldsAndOversize() async throws {
        let db = try Database(url:nil), app = try await Application.make(.testing)
        var config = Configuration(); config.signedWebhooks = false
        try Ingress.install(on:app,database:db,configuration:config,secret:"fixture-token")
        let headers: HTTPHeaders = ["Content-Type":"multipart/form-data; boundary=indexa-fixture","Authorization":"Bearer fixture-token"]
        let base = [("client","ring"),("recordedAt","1700000000000"),("transcription","test")]
        try await app.test(.POST,"/pebble/v1/ingest",headers:headers,body:fixture(base+[("test","true")])) { #expect($0.status == .accepted) }
        #expect(try await db.tasks().isEmpty)
        for fields in [base+[("audio","bytes")],base+[("client","ring")],base+[("extra",String(repeating:"x",count:300000))]] {
            try await app.test(.POST,"/pebble/v1/ingest",headers:headers,body:fixture(fields)) { #expect($0.status.code >= 400) }
        }
        try await app.asyncShutdown()
    }
}
