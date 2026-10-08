#!/usr/bin/env swift
import Foundation
import CryptoKit

// Sparkle 2.9 accepts the base64-encoded 32-byte Ed25519 seed; no Keychain access.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let privateDirectory = root.appendingPathComponent(".sparkle", isDirectory: true)
let privateFile = privateDirectory.appendingPathComponent("private-key")
let publicFile = root.appendingPathComponent("release/sparkle-public-key.txt")
try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
guard !FileManager.default.fileExists(atPath: privateFile.path), !FileManager.default.fileExists(atPath: publicFile.path) else {
    fatalError("Signing key already exists; refusing to rotate it.")
}
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: privateFile, options: .withoutOverwriting)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateFile.path)
try key.publicKey.rawRepresentation.base64EncodedData().write(to: publicFile, options: .withoutOverwriting)
print("Signing key saved locally; public key saved in release/sparkle-public-key.txt. No Keychain used.")
