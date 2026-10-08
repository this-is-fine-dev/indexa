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
        guard CommandLine.arguments.contains("--reset-authorized") else { throw IndexaError("explicit_reset_required") }
        let owner=try store.getOrCreate(.matrixOwnerPassword)
        let bot=try store.getOrCreate(.matrixBotPassword)
        _ = try store.getOrCreate(.matrixPickle)
        let ownerPickle=try store.getOrCreate(.matrixOwnerPickle)
        let process=Process(),input=Pipe(),output=Pipe()
        process.executableURL=Configuration.directory.appendingPathComponent("runtime/venv/bin/python")
        process.arguments=[URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("matrix/setup_qr.py").path]
        process.standardInput=input;process.standardOutput=output
        try process.run()
        input.fileHandleForReading.closeFile();output.fileHandleForWriting.closeFile()
        try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:[
            SecretName.matrixOwnerPassword.rawValue:owner,SecretName.matrixBotPassword.rawValue:bot,SecretName.matrixOwnerPickle.rawValue:ownerPickle]))
        try input.fileHandleForWriting.close()
        let result=output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IndexaError("matrix_setup_failed") }
        guard result.count <= 8192,let values=try JSONSerialization.jsonObject(with:result) as? [String:String],
              Set(values.keys) == Set([SecretName.matrixBotToken.rawValue,SecretName.matrixOwnerToken.rawValue]),values.values.allSatisfy({$0.count >= 16}) else {
            throw IndexaError("matrix_setup_invalid_response")
        }
        try store.write(Dictionary(uniqueKeysWithValues:values.map{(SecretName(rawValue:$0.key)!,$0.value)}))
        _ = try store.getOrCreate(.matrixBotCrossSigning)
        var identityCredentials=[String:String]()
        for name:SecretName in [.matrixTransport,.matrixBotToken,.matrixPickle,.matrixOwnerToken,.matrixOwnerPickle,.matrixBotCrossSigning] {
            guard let value=try store.read(name) else { throw IndexaError("missing_identity_credential") }
            identityCredentials[name.rawValue]=value
        }
        let repair=Process(),repairInput=Pipe()
        repair.executableURL=process.executableURL
        repair.arguments=["-B",FileManager.default.currentDirectoryPath+"/matrix/repair_bot_identity.py"]
        repair.standardInput=repairInput
        try repair.run();repairInput.fileHandleForReading.closeFile()
        try repairInput.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:identityCredentials))
        try repairInput.fileHandleForWriting.close()
        repair.waitUntilExit()
        guard repair.terminationStatus == 0 else { throw IndexaError("bot_identity_setup_failed") }
        print("Matrix QR configured; credentials saved locally. No Keychain access.")
    }
}
