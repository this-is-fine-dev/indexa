import Foundation
import AVFoundation

public enum LocalWhisper {
    public static func transcribe(_ data: Data) async throws -> String {
        try await Task.detached {
            let resources = Bundle.main.resourceURL?.appendingPathComponent("Whisper")
            guard let resources else { throw IndexaError("whisper_resources_missing") }
            let executable = resources.appendingPathComponent("whisper-cli")
            let model = resources.appendingPathComponent("ggml-small.bin")
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  FileManager.default.fileExists(atPath: model.path) else { throw IndexaError("whisper_model_missing") }
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
