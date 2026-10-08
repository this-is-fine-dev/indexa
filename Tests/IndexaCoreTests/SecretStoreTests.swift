import Foundation
import Testing
@testable import IndexaCore

struct SecretStoreTests {
    @Test func automaticUnlockPersistsKeyAndNeverReplacesExistingCredentials() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("secrets.vault"),keyURL=url.appendingPathExtension("key")
        let store=SecretStore(url:url)
        try store.openAutomatically()
        let secret=try store.getOrCreate(.hermesAPI)
        let savedKey=try Data(contentsOf:keyURL)
        #expect(savedKey.count == 64)
        #expect(try FileManager.default.attributesOfItem(atPath:keyURL.path)[.posixPermissions] as? Int == 0o600)
        store.lock()
        try store.openAutomatically()
        #expect(try store.read(.hermesAPI) == secret)
        #expect(try Data(contentsOf:keyURL) == savedKey)
        store.lock()
        let savedVault=try Data(contentsOf:url)
        try FileManager.default.removeItem(at:keyURL)
        #expect(throws:IndexaError("vault_existing_password_required")) { try store.openAutomatically() }
        #expect(!FileManager.default.fileExists(atPath:keyURL.path))
        #expect(try Data(contentsOf:url) == savedVault)
        // Interrupted setup: a durable key without a vault is safe to resume.
        try FileManager.default.removeItem(at:url)
        try savedKey.write(to:keyURL)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:keyURL.path)
        try store.openAutomatically()
        #expect(try Data(contentsOf:keyURL) == savedKey)
        store.lock()
        try Data("invalid-key".utf8).write(to:keyURL)
        #expect(throws:IndexaError("vault_invalid_local_key")) { try store.openAutomatically() }
    }
    @Test func encryptedVaultRoundTripAndDenialPaths() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("secrets.vault")
        let store=SecretStore(url:url)
        #expect(throws:IndexaError("vault_locked")) { try store.read(.matrixBotToken) }
        #expect(throws:IndexaError("vault_passphrase_too_short")) { try store.create(passphrase:"short") }
        try store.create(passphrase:"synthetic passphrase for tests")
        try store.write(.matrixBotToken,value:"synthetic-private-token")
        let generated=try store.getOrCreate(.hermesAPI)
        #expect(generated.count == 64)
        let disk=try Data(contentsOf:url)
        #expect(!String(decoding:disk,as:UTF8.self).contains("synthetic-private-token"))
        #expect(!String(decoding:disk,as:UTF8.self).contains("synthetic passphrase"))
        #expect(try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? Int == 0o600)
        let competing=SecretStore(url:url)
        #expect(throws:IndexaError("vault_in_use")) { try competing.unlock(passphrase:"synthetic passphrase for tests") }
        store.lock()
        #expect(throws:IndexaError("vault_locked")) { try store.getOrCreate(.pebbleSigning) }
        #expect(throws:IndexaError("vault_unlock_failed")) { try store.unlock(passphrase:"wrong passphrase also long") }
        #expect(try Data(contentsOf:url) == disk)
        try store.unlock(passphrase:"synthetic passphrase for tests")
        #expect(try store.read(.matrixBotToken) == "synthetic-private-token")
        #expect(try store.getOrCreate(.hermesAPI) == generated)
        #expect(throws:IndexaError("empty_secret")) { try store.write(.matrixBotToken,value:"") }
        store.lock()
        #expect(throws:IndexaError("vault_already_exists")) { try store.create(passphrase:"another synthetic passphrase") }
        var envelope=try JSONSerialization.jsonObject(with:disk) as! [String:Any]
        var box=Data(base64Encoded:envelope["box"] as! String)!
        box[box.count-1] ^= 1
        envelope["box"]=box.base64EncodedString()
        try JSONSerialization.data(withJSONObject:envelope).write(to:url)
        #expect(throws:IndexaError("vault_unlock_failed")) { try store.unlock(passphrase:"synthetic passphrase for tests") }
        #expect(!store.isUnlocked)
    }
}
