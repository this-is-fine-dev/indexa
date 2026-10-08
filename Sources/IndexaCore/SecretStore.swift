import Foundation
import CryptoKit
import CommonCrypto
import Darwin

public enum SecretName:String,CaseIterable {
    case mcpAccess = "mcp-access-token"
    case pebbleSigning = "pebble-signing-secret"
    case hermesAPI = "hermes-api-key"
    case matrixTransport = "matrix-transport-key"
    case matrixOwnerPassword = "matrix-owner-password"
    case matrixBotPassword = "matrix-indexa-password"
    case matrixBotToken = "matrix-bot-token"
    case matrixPickle = "matrix-pickle-key"
    case matrixOwnerToken = "matrix-owner-token"
    case matrixOwnerPickle = "matrix-owner-pickle"
    case matrixBotCrossSigning = "matrix-bot-cross-signing"
}

/// Encrypted local storage with a locally saved random unlock key.
/// File permissions are the boundary; this does not isolate same-user processes.
/// No Keychain API or automatic migration of existing password-protected vaults.
public final class SecretStore {
    private struct Envelope:Codable { let version:Int;let salt:Data;let box:Data }
    private let url:URL
    private var key:SymmetricKey?
    private var salt=Data()
    private var values=[String:String]()
    private var lockFD:Int32 = -1
    public var isUnlocked:Bool { key != nil }
    public var exists:Bool { FileManager.default.fileExists(atPath:url.path) }
    public init(url:URL=Configuration.directory.appendingPathComponent("secrets.vault")) { self.url=url }
    deinit { if lockFD >= 0 { close(lockFD) } }

    public func openAutomatically() throws {
        if isUnlocked { return }
        try acquireLock()
        defer { if !isUnlocked { lock() } }
        let keyURL=url.appendingPathExtension("key")
        var info=stat()
        if lstat(keyURL.path,&info) != 0 {
            guard errno == ENOENT else { throw IndexaError("vault_invalid_local_key") }
            guard !exists else { throw IndexaError("vault_existing_password_required") }
            let passphrase=Self.randomData().map{String(format:"%02x",$0)}.joined()
            let fd=open(keyURL.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard fd >= 0 else { throw IndexaError("vault_local_key_write_failed") }
            let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            // Persist the key first. A crash here can resume without replacing it.
            try file.write(contentsOf:Data(passphrase.utf8))
            try file.synchronize()
            try file.close()
        }
        let fd=open(keyURL.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw IndexaError("vault_invalid_local_key") }
        defer { close(fd) }
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),info.st_mode & 0o077 == 0,info.st_size == 64 else {
            throw IndexaError("vault_invalid_local_key")
        }
        let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:65) ?? Data()
        guard data.count == 64,data.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),
              let passphrase=String(data:data,encoding:.utf8) else { throw IndexaError("vault_invalid_local_key") }
        if exists { try unlock(passphrase:passphrase) } else { try create(passphrase:passphrase) }
    }
    public func create(passphrase:String) throws {
        guard !isUnlocked else { throw IndexaError("vault_already_unlocked") }
        guard passphrase.count >= 16 else { throw IndexaError("vault_passphrase_too_short") }
        try acquireLock()
        defer { if !isUnlocked { lock() } }
        guard !exists else { throw IndexaError("vault_already_exists") }
        let salt=Self.randomData().prefix(16)
        let key=try Self.derive(passphrase,salt:Data(salt))
        try persist([:],key:key,salt:Data(salt))
        self.salt=Data(salt);self.key=key
    }
    public func unlock(passphrase:String) throws {
        guard !isUnlocked else { throw IndexaError("vault_already_unlocked") }
        try acquireLock()
        defer { if !isUnlocked { lock() } }
        var info=stat()
        guard lstat(url.path,&info) == 0,info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),info.st_size <= 65536 else { throw IndexaError("vault_invalid_file") }
        let envelope:Envelope
        do { envelope=try JSONDecoder().decode(Envelope.self,from:Data(contentsOf:url)) }
        catch { throw IndexaError("vault_invalid_file") }
        guard envelope.version == 1,envelope.salt.count == 16 else { throw IndexaError("vault_invalid_file") }
        let key=try Self.derive(passphrase,salt:envelope.salt)
        let loaded:[String:String]
        do {
            let box=try AES.GCM.SealedBox(combined:envelope.box)
            let data=try AES.GCM.open(box,using:key,authenticating:Self.header(envelope.salt))
            loaded=try JSONDecoder().decode([String:String].self,from:data)
        } catch { throw IndexaError("vault_unlock_failed") }
        guard loaded.allSatisfy({ SecretName(rawValue:$0.key) != nil && !$0.value.isEmpty && $0.value.utf8.count <= 4096 }) else {
            throw IndexaError("vault_invalid_file")
        }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        self.salt=envelope.salt;self.values=loaded;self.key=key
    }
    public func lock() {
        key=nil;salt.removeAll();values.removeAll()
        if lockFD >= 0 { close(lockFD);lockFD = -1 }
        // Swift/CryptoKit do not guarantee zeroisation of all temporary copies.
    }
    public func read(_ name:SecretName) throws -> String? {
        guard isUnlocked else { throw IndexaError("vault_locked") }
        return values[name.rawValue]
    }
    public func write(_ name:SecretName,value:String) throws {
        try write([name:value])
    }
    public func write(_ items:[SecretName:String]) throws {
        guard let key else { throw IndexaError("vault_locked") }
        var updated=values
        for (name,value) in items {
            guard !value.isEmpty else { throw IndexaError("empty_secret") }
            guard value.utf8.count <= 4096 else { throw IndexaError("secret_too_large") }
            updated[name.rawValue]=value
        }
        try persist(updated,key:key,salt:salt)
        values=updated
    }
    public func getOrCreate(_ name:SecretName) throws -> String {
        if let value=try read(name) { return value }
        let value=Self.randomData().map{String(format:"%02x",$0)}.joined()
        try write(name,value:value)
        return value
    }
    private func persist(_ values:[String:String],key:SymmetricKey,salt:Data) throws {
        let plaintext=try JSONEncoder().encode(values)
        let box=try AES.GCM.seal(plaintext,using:key,authenticating:Self.header(salt))
        guard let combined=box.combined else { throw IndexaError("vault_encryption_failed") }
        let data=try JSONEncoder().encode(Envelope(version:1,salt:salt,box:combined))
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func acquireLock() throws {
        if lockFD >= 0 { return }
        let directory=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var info=stat()
        guard lstat(directory.path,&info) == 0,info.st_mode & S_IFMT == S_IFDIR,info.st_uid == getuid() else {
            throw IndexaError("vault_invalid_directory")
        }
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let fd=open(url.appendingPathExtension("lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw IndexaError("vault_lock_failed") }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { close(fd);throw IndexaError("vault_in_use") }
        lockFD=fd
    }
    private static func randomData() -> Data { SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) } }
    private static func header(_ salt:Data) -> Data { Data("Indexa vault v1 PBKDF2-SHA256 600000 AES-256-GCM".utf8)+salt }
    private static func derive(_ passphrase:String,salt:Data) throws -> SymmetricKey {
        guard !passphrase.isEmpty,passphrase.utf8.count <= 4096 else { throw IndexaError("vault_invalid_passphrase") }
        var password=Array(passphrase.utf8),output=[UInt8](repeating:0,count:32)
        defer { _ = password.withUnsafeMutableBytes { $0.initializeMemory(as:UInt8.self,repeating:0) };_ = output.withUnsafeMutableBytes { $0.initializeMemory(as:UInt8.self,repeating:0) } }
        let status=password.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),p.baseAddress!.assumingMemoryBound(to:CChar.self),p.count,
                    s.baseAddress!.assumingMemoryBound(to:UInt8.self),s.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),600_000,&output,32)
            }
        }
        guard status == kCCSuccess else { throw IndexaError("vault_derivation_failed") }
        return SymmetricKey(data:output)
    }
}
