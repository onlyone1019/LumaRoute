import Foundation

/// A scoped direct retry using macOS' TLS-validating transport. Foundation on some
/// macOS versions still consults system proxies despite per-session proxy disables.
enum DirectSubscriptionDownload {
    static func fetch(_ url: URL, userAgent: String) async throws -> (Data, URLResponse) {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaRoute-download-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:directory) }
            let body = directory.appendingPathComponent("body")
            let headers = directory.appendingPathComponent("headers")
            for file in [body,headers] { try Data().write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path) }
            let task = Process(); let input = Pipe()
            task.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
            task.arguments = ["--disable","--config","-","--noproxy","*","--silent","--location","--max-redirs","10","--proto","=http,https","--proto-redir","=https","--connect-timeout","10","--max-time","25","--max-filesize","8388608","--dump-header",headers.path,"--output",body.path]
            task.standardInput = input
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            // The bearer URL is sent through stdin, never process arguments or a config file.
            let escaped = url.absoluteString.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r")
            let escapedAgent = userAgent.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
            try task.run()
            defer { if task.isRunning { task.terminate() } }
            try input.fileHandleForWriting.write(contentsOf:Data(("url = \""+escaped+"\"\nuser-agent = \""+escapedAgent+"\"\n").utf8))
            try input.fileHandleForWriting.close()
            while task.isRunning { try Task.checkCancellation(); try await Task.sleep(nanoseconds:50_000_000) }
            switch task.terminationStatus {
            case 0: break
            case 6: throw SubscriptionError.download("无法解析服务商域名，请检查链接及 DNS 设置。")
            case 28: throw SubscriptionError.download("连接超时，请检查网络或稍后重试。")
            case 35,51,60: throw SubscriptionError.download("无法验证服务商的 HTTPS 连接，请检查系统时间或联系服务商。")
            case 63: throw SubscriptionError.tooLarge
            default: throw SubscriptionError.download("无法连接订阅服务器（传输错误 \(task.terminationStatus)），请检查网络及服务商状态。")
            }
            let data = try Data(contentsOf:body)
            guard data.count <= 8*1024*1024 else { throw SubscriptionError.tooLarge }
            let headerText = try String(contentsOf:headers,encoding:.utf8).replacingOccurrences(of:"\r\n",with:"\n")
            guard let final = headerText.components(separatedBy:"\n\n").last(where:{$0.hasPrefix("HTTP/")}) else { throw LumaError.message("订阅服务器未返回有效 HTTP 响应") }
            let lines = final.components(separatedBy:"\n")
            guard let statusText = lines.first?.split(separator:" ").dropFirst().first, let status = Int(statusText) else { throw SubscriptionError.download("服务器没有返回有效的 HTTP 状态。") }
            var fields:[String:String] = [:]
            for line in lines.dropFirst() {
                guard let separator = line.firstIndex(of:":") else { continue }
                fields[String(line[..<separator])] = String(line[line.index(after:separator)...]).trimmingCharacters(in:.whitespaces)
            }
            guard let response = HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:fields) else { throw LumaError.message("订阅响应无法解析") }
            return (data,response as URLResponse)
        }.value
    }
}
