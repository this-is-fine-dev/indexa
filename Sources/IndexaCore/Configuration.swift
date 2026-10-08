import Foundation

public struct Configuration: Codable, Equatable {
    public var port = 18761
    public var hermesURL = "http://127.0.0.1:18762"
    public var signedWebhooks = true
    public var contentRetentionDays = 7
    public var metadataRetentionDays = 30
    public init() {}

    public func validate() throws {
        guard (1024...65535).contains(port),
              let url = URLComponents(string: hermesURL), url.scheme == "http",
              url.host == "127.0.0.1", let apiPort = url.port,
              (1024...65535).contains(apiPort), apiPort != port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty, contentRetentionDays >= 1,
              metadataRetentionDays >= contentRetentionDays, metadataRetentionDays <= 3650 else {
            throw IndexaError("invalid_configuration")
        }
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Indexa")
    }

    public static func load(from directory: URL = directory) throws -> Configuration {
        let url = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    public func save(to directory: URL = directory) throws {
        try validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct IndexaError: Error, LocalizedError, Equatable {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var errorDescription: String? { code }
}
