import Foundation
import AVFoundation
import CryptoKit

public enum LocalWhisper {
    private static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
    private static let modelHash = "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
    private static var persistentModel: URL { Configuration.directory.appendingPathComponent("Whisper/ggml-small.bin") }

    public static func migrateBundledModel() {
        guard !FileManager.default.fileExists(atPath: persistentModel.path),
              let source = Bundle.main.resourceURL?.appendingPathComponent("Whisper/ggml-small.bin"),
              FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.createDirectory(at: persistentModel.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staged = persistentModel.appendingPathExtension(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: source, to: staged)
            try FileManager.default.moveItem(at: staged, to: persistentModel)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistentModel.path)
        } catch { NSLog("Indexa: could not preserve Whisper model before update: %@", String(describing: error)) }
    }

    public static func transcribe(_ data: Data) async throws -> String {
        try await Task.detached {
            let resources = Bundle.main.resourceURL?.appendingPathComponent("Whisper")
            guard let resources else { throw IndexaError("whisper_resources_missing") }
            let executable = resources.appendingPathComponent("whisper-cli")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw IndexaError("whisper_cli_missing") }
            let model = try await ensureModel()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("indexa-whisper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let input = temporary.appendingPathComponent("recording.m4a")
            let wave = temporary.appendingPathComponent("recording.wav")
            let output = temporary.appendingPathComponent("transcript")
            let log = temporary.appendingPathComponent("process.log")
            try data.write(to: input, options: .atomic)
            try run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, wave.path], log)
            let recording = try AVAudioFile(forReading: wave)
            guard recording.length > 0, Double(recording.length) / recording.fileFormat.sampleRate <= 15 * 60 else {
                throw IndexaError("whisper_audio_duration_invalid")
            }
            try run(executable, ["-m", model.path, "-f", wave.path, "-l", "pl", "-t", "6", "-otxt", "-of", output.path, "-np", "-nt"], log)
            let text = try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw IndexaError("whisper_no_speech") }
            return text
        }.value
    }

    private static func ensureModel() async throws -> URL {
        if FileManager.default.fileExists(atPath: persistentModel.path) { return persistentModel }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Whisper/ggml-small.bin"), FileManager.default.fileExists(atPath: bundled.path) {
            migrateBundledModel()
            if FileManager.default.fileExists(atPath: persistentModel.path) { return persistentModel }
        }
        try FileManager.default.createDirectory(at: persistentModel.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (download, response) = try await URLSession.shared.download(from: modelURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, try sha256(download) == modelHash else { throw IndexaError("whisper_model_download_invalid") }
        try FileManager.default.moveItem(at: download, to: persistentModel)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistentModel.path)
        return persistentModel
    }

    private static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: URL, _ arguments: [String], _ log: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if FileManager.default.fileExists(atPath: log.path) { try Data().write(to: log) }
        else if !FileManager.default.createFile(atPath: log.path, contents: nil) { throw IndexaError("whisper_log_create") }
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output
        process.standardError = output
        defer { try? output.close() }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IndexaError("whisper_failed") }
    }
}
