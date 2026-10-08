import Foundation
import IndexaCore

/// Runs before any gateway/Matrix child starts, while holding Indexa's instance lock.
enum StackCompatibility {
    static func prepare() async throws {
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("stack.json").path) else {
            throw IndexaError("runtime_manifest_missing")
        }
        let directory = Configuration.directory
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = directory.appendingPathComponent("runtime/venv/bin/python")
            process.arguments = ["-B", resources.appendingPathComponent("prepare-runtime.py").path, resources.path, directory.path]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw IndexaError(detail.hasPrefix("runtime_") ? detail : "runtime_preflight_failed")
            }
        }.value
    }
}
