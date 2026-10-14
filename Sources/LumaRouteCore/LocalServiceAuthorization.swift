import Foundation

public enum NetworkServiceSetup: Equatable {
    case ready, install, update, enableNetwork
    public static func resolve(installed: Bool,accepted: Bool,healthOnly: Bool) -> Self {
        guard installed else { return .install }
        guard accepted else { return .update }
        return healthOnly ? .enableNetwork:.ready
    }
}

public enum LocalServiceAuthorization {
    public static func script(app: URL,ownerUID: UInt32,networkReady: Bool) throws -> String {
        guard ownerUID > 0,app.pathExtension == "app" else { throw LumaError.message("应用或用户身份无效") }
        let installer = app.appendingPathComponent("Contents/Resources/install_local_service.sh")
        let option = networkReady ? " --network-ready":""
        return """
        set installerPath to \(literal(installer.path))
        set appPath to \(literal(app.path))
        try
            do shell script ("/usr/bin/env SUDO_UID=\(ownerUID) /bin/bash " & quoted form of installerPath & " --install " & quoted form of appPath & "\(option)") with administrator privileges
        on error errorMessage number errorNumber
            if errorNumber is -128 then return "LUMAROUTE_AUTH_CANCELLED"
            error errorMessage number errorNumber
        end try
        """
    }
    private static func literal(_ text: String) -> String {
        "\""+text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r")+"\""
    }
    public static func install(app: URL,ownerUID: UInt32,networkReady: Bool) async throws {
        let source = try script(app:app,ownerUID:ownerUID,networkReady:networkReady)
        try await Task.detached {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("lumaroute-service-"+UUID().uuidString+".log")
            FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600])
            let output = try FileHandle(forWritingTo:file)
            defer { try? output.close(); try? FileManager.default.removeItem(at:file) }
            let task = Process()
            task.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
            task.arguments = ["-e",source]
            task.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":NSHomeDirectory(),"LANG":"en_US.UTF-8"]
            task.standardOutput = output; task.standardError = output
            try task.run()
            let deadline = Date().addingTimeInterval(600)
            while task.isRunning,Date() < deadline { try await Task.sleep(nanoseconds:100_000_000) }
            guard !task.isRunning else { task.terminate(); throw LumaError.message("授权等待超时，请稍后重试") }
            let reader = try FileHandle(forReadingFrom:file); defer { try? reader.close() }
            let message = String(data:try reader.read(upToCount:16*1024) ?? Data(),encoding:.utf8) ?? ""
            if message.trimmingCharacters(in:.whitespacesAndNewlines) == "LUMAROUTE_AUTH_CANCELLED" { throw CancellationError() }
            guard task.terminationStatus == 0 else { throw LumaError.message("网络服务同步失败："+Redactor.clean(String(message.suffix(1200)))) }
        }.value
    }
}
