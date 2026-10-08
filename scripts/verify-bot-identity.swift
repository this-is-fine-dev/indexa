import Foundation
@main struct VerifyBotIdentity {
    static func main() {
        do {
            let store=SecretStore();try store.openAutomatically()
            _ = try store.getOrCreate(.matrixBotCrossSigning)
            var values=[String:String]()
            for name:SecretName in [.matrixTransport,.matrixBotToken,.matrixPickle,.matrixOwnerToken,.matrixOwnerPickle,.matrixBotCrossSigning] {
                guard let value=try store.read(name) else { throw IndexaError("missing_identity_credential") }
                values[name.rawValue]=value
            }
            store.lock()
            let process=Process(),input=Pipe()
            process.executableURL=Configuration.directory.appendingPathComponent("runtime/venv/bin/python")
            process.arguments=["-B",FileManager.default.currentDirectoryPath+"/matrix/repair_bot_identity.py"]
            process.standardInput=input
            try process.run();input.fileHandleForReading.closeFile()
            try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:values))
            try input.fileHandleForWriting.close()
            process.waitUntilExit();exit(process.terminationStatus)
        } catch { fputs("Identity check failed: \((error as? IndexaError)?.code ?? String(describing:type(of:error)))\n",stderr);exit(1) }
    }
}
