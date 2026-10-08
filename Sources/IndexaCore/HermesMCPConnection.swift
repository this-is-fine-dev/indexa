import Foundation
import Darwin

public struct HermesMCPConnection: Decodable, Sendable {
    public let ok: Bool
    public let changed: Bool?
    public let tools: Int?
    public let error: String?

    public static func synchronize(token: String, modules: [String], script: URL) async throws -> Self {
        try await Task.detached {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let profile = home.appendingPathComponent(".hermes/profiles/indexa")
            let environment = ["HOME": home.path, "HERMES_HOME": profile.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "pl_PL.UTF-8",
                "HERMES_DISABLE_LAZY_INSTALLS": "1", "PYTHONDONTWRITEBYTECODE": "1"]
            // Ask the installed launcher; do not pin a Python dependency generation that GC can remove.
            let command = try run(home.appendingPathComponent(".local/bin/hermes"),
                arguments: ["--print-runtime-command"], input: Data(), environment: environment)
            guard let launch = try? JSONDecoder().decode([String].self, from: command),
                  let python = launch.first, python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python) else {
                throw IndexaError("hermes_mcp_runtime_unavailable")
            }
            let input = try JSONSerialization.data(withJSONObject: ["token": token, "modules": modules])
            let output = try run(URL(fileURLWithPath: python),
                arguments: ["-I", script.path, home.appendingPathComponent(".hermes/hermes-agent").path, profile.path],
                input: input, environment: environment)
            let result = try JSONDecoder().decode(Self.self, from: output)
            guard result.ok else { throw IndexaError(result.error == "hermes_mcp_connection_failed" ? "hermes_mcp_connection_failed" : "hermes_mcp_setup_failed") }
            return result
        }.value
    }

    private static func run(_ executable: URL, arguments: [String], input: Data, environment: [String: String]) throws -> Data {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            try? stdin.fileHandleForWriting.close(); try? stdout.fileHandleForReading.close()
        }
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        var output = Data()
        while let bytes = try stdout.fileHandleForReading.read(upToCount: 16384), !bytes.isEmpty {
            output.append(bytes)
            guard output.count <= 262144 else { throw IndexaError("hermes_mcp_invalid_response") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IndexaError("hermes_mcp_setup_failed") }
        return output
    }
}
