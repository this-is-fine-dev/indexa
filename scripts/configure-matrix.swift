import Foundation

// Compile with Sources/IndexaCore/{Configuration,SecretStore}.swift. Quit Indexa first.
@main struct ConfigureMatrix {
    static func main() {
        do { try configure() }
        catch { fputs("Configuration failed: \((error as? IndexaError)?.code ?? String(describing:type(of:error)))\n",stderr);exit(1) }
    }
    static func configure() throws {
        let store=SecretStore()
        try store.openAutomatically()
        guard try store.read(.matrixBotToken) == nil else {
            print("Matrix credentials already configured; nothing changed.")
            return
        }
        let owner=try store.getOrCreate(.matrixOwnerPassword)
        let bot=try store.getOrCreate(.matrixBotPassword)
        _ = try store.getOrCreate(.matrixPickle)
        let process=Process(),input=Pipe(),output=Pipe()
        process.executableURL=Configuration.directory.appendingPathComponent("runtime/venv/bin/python")
        process.arguments=[URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("matrix/setup.py").path]
        process.standardInput=input;process.standardOutput=output
        try process.run()
        input.fileHandleForReading.closeFile();output.fileHandleForWriting.closeFile()
        try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:[
            SecretName.matrixOwnerPassword.rawValue:owner,SecretName.matrixBotPassword.rawValue:bot]))
        try input.fileHandleForWriting.close()
        let result=output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IndexaError("matrix_setup_failed") }
        guard result.count <= 8192,let values=try JSONSerialization.jsonObject(with:result) as? [String:String],
              values.count == 1,let token=values[SecretName.matrixBotToken.rawValue],token.count >= 16 else {
            throw IndexaError("matrix_setup_invalid_response")
        }
        try store.write(.matrixBotToken,value:token)
        print("Matrix configured; credentials saved locally. No Keychain access.")
    }
}
