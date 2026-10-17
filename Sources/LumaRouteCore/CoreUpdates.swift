import Foundation
import CryptoKit

public struct CoreRelease: Codable, Equatable, Sendable {
    public let version: String
    public let assetName: String
    public let downloadURL: URL
    public let sha256: String
    public let size: Int
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64-compatible"
        #endif
    }
    public static func parse(_ data: Data) throws -> CoreRelease {
        guard let release = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              release["draft"] as? Bool == false,release["prerelease"] as? Bool == false,
              let version = release["tag_name"] as? String,version.count <= 80,
              version.range(of:"^v[0-9]+\\.[0-9]+\\.[0-9]+$",options:.regularExpression) != nil,
              let assets = release["assets"] as? [[String:Any]],
              let asset = assets.first(where:{$0["name"] as? String == "mihomo-darwin-\(architecture)-\(version).gz"}),
              let name = asset["name"] as? String,
              let address = asset["browser_download_url"] as? String,
              address == "https://github.com/MetaCubeX/mihomo/releases/download/\(version)/\(name)",
              let url = URL(string:address),let size = asset["size"] as? Int,size > 0,size <= 64*1024*1024,
              let digest = asset["digest"] as? String,digest.range(of:"^sha256:[a-f0-9]{64}$",options:.regularExpression) != nil
        else { throw LumaError.message("官方发布信息缺少有效的稳定版、当前架构文件或 SHA256") }
        return CoreRelease(version:version,assetName:name,downloadURL:url,sha256:String(digest.dropFirst(7)),size:size)
    }
    public static func latest(session: URLSession = .shared) async throws -> CoreRelease {
        try await fetch(endpoint:"latest",session:session)
    }
    public static func version(_ version: String,session: URLSession = .shared) async throws -> CoreRelease {
        guard version.count <= 80,version.range(of:"^v[0-9]+\\.[0-9]+\\.[0-9]+$",options:.regularExpression) != nil else { throw LumaError.message("内核版本参数无效") }
        let release = try await fetch(endpoint:"tags/"+version,session:session)
        guard release.version == version else { throw LumaError.message("官方发布版本与请求不一致") }
        return release
    }
    private static func fetch(endpoint: String,session: URLSession) async throws -> CoreRelease {
        var request = URLRequest(url:URL(string:"https://api.github.com/repos/MetaCubeX/mihomo/releases/"+endpoint)!,timeoutInterval:25)
        request.setValue(VersionInfo.current.userAgent,forHTTPHeaderField:"User-Agent")
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse,http.statusCode == 200,data.count < 4*1024*1024 else {
            throw LumaError.message("无法读取官方发布信息；请检查网络或稍后重试")
        }
        return try parse(data)
    }
}

public struct CoreArtifact: Codable, Equatable, Sendable {
    public let id: UUID
    public let release: CoreRelease
    public let binarySHA256: String
}

/// Owns downloaded executables and selection state outside the signed app bundle.
public final class CoreUpdates: Sendable {
    public struct Selection: Codable, Equatable, Sendable {
        public var active: CoreArtifact?
        public var previous: CoreArtifact?
        public var canRollback: Bool = false
    }
    private struct Pending: Codable { var before: Selection; var candidate: CoreArtifact? }
    public let root: URL
    public let bundled: URL
    public init(root: URL,bundled: URL) throws {
        self.root = root.standardizedFileURL; self.bundled = bundled.standardizedFileURL
        try FileManager.default.createDirectory(at:root.appendingPathComponent("versions"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    public func selection() throws -> Selection {
        let file = root.appendingPathComponent("selection.json")
        return FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode(Selection.self,from:Data(contentsOf:file)) : Selection()
    }
    public func activationVersion() throws -> String? {
        if FileManager.default.fileExists(atPath:pending.path) {
            let change = try JSONDecoder().decode(Pending.self,from:Data(contentsOf:pending))
            return change.candidate?.release.version
        }
        return try selection().active?.release.version
    }
    public func binary(for artifact: CoreArtifact?) throws -> URL {
        guard let artifact else { return bundled }
        let file = root.appendingPathComponent("versions/\(artifact.id.uuidString)/mihomo")
        guard file.resolvingSymlinksInPath() == file,FileManager.default.isExecutableFile(atPath:file.path),
              Self.digest(try Data(contentsOf:file)) == artifact.binarySHA256 else { throw LumaError.message("保存的内核文件已改变，请回退到有效版本") }
        return file
    }
    public func currentBinary() throws -> URL { try binary(for:selection().active) }
    public func cachedArtifact(version: String) throws -> CoreArtifact? {
        let directories = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("versions"),includingPropertiesForKeys:nil)
        for directory in directories {
            guard let id = UUID(uuidString:directory.lastPathComponent),directory.resolvingSymlinksInPath() == directory,
                  let data = try? Data(contentsOf:directory.appendingPathComponent("manifest.json")),
                  let artifact = try? JSONDecoder().decode(CoreArtifact.self,from:data),artifact.id == id,artifact.release.version == version else { continue }
            if (try? binary(for:artifact)) != nil { return artifact }
        }
        return nil
    }
    public func stage(_ release: CoreRelease,session: URLSession = .shared) async throws -> CoreArtifact {
        let request = URLRequest(url:release.downloadURL,timeoutInterval:120)
        let (temporary,response) = try await session.download(for:request)
        defer { try? FileManager.default.removeItem(at:temporary) }
        guard let http = response as? HTTPURLResponse,http.statusCode == 200,
              let size = try FileManager.default.attributesOfItem(atPath:temporary.path)[.size] as? NSNumber,
              size.intValue == release.size else { throw LumaError.message("内核下载失败或文件大小不匹配，当前版本未改变") }
        return try await stageArchive(temporary,release:release)
    }
    /// Also used by the offline verifier with an official archive and manifest.
    public func stageArchive(_ archive: URL,release: CoreRelease) async throws -> CoreArtifact {
        let compressed = try Data(contentsOf:archive)
        guard compressed.count == release.size,compressed.count <= 64*1024*1024,Self.digest(compressed) == release.sha256 else {
            throw LumaError.message("内核文件 SHA256 校验失败，当前版本未改变")
        }
        // Reparse the public model too: callers must not supply another download origin.
        let manifest: [String:Any] = ["tag_name":release.version,"draft":false,"prerelease":false,"assets":[["name":release.assetName,"browser_download_url":release.downloadURL.absoluteString,"size":release.size,"digest":"sha256:"+release.sha256]]]
        _ = try CoreRelease.parse(JSONSerialization.data(withJSONObject:manifest))
        let id = UUID(); let directory = root.appendingPathComponent("versions/\(id.uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = directory.appendingPathComponent("mihomo")
        let ownedArchive = directory.appendingPathComponent("download.gz")
        do {
            try write(compressed,to:ownedArchive)
            defer { try? FileManager.default.removeItem(at:ownedArchive) }
            try await Task.detached {
                FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600])
                let output = try FileHandle(forWritingTo:file); defer { try? output.close() }
                let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/gunzip")
                process.arguments = ["-c",ownedArchive.path]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run(); let deadline = Date().addingTimeInterval(30)
                defer { if process.isRunning { kill(process.processIdentifier,SIGKILL) } }
                while process.isRunning && Date() < deadline {
                    let size = (try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? 0
                    guard size <= 128*1024*1024 else { throw LumaError.message("内核解压结果超过大小限制") }
                    try await Task.sleep(nanoseconds:50_000_000)
                }
                guard !process.isRunning,process.terminationStatus == 0 else { throw LumaError.message("内核压缩文件无效或解压超时") }
            }.value
            let payload = try Data(contentsOf:file)
            guard payload.count > 1024,payload.count <= 128*1024*1024,
                  Array(payload.prefix(4)) == [0xcf,0xfa,0xed,0xfe] else { throw LumaError.message("下载内容不是有效的 macOS 内核文件") }
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
            let artifact = CoreArtifact(id:id,release:release,binarySHA256:Self.digest(payload))
            try write(JSONEncoder().encode(artifact),to:directory.appendingPathComponent("manifest.json"))
            return artifact
        } catch { try? FileManager.default.removeItem(at:directory); throw error }
    }
    public func beginSwitch(to artifact: CoreArtifact?) throws {
        guard !FileManager.default.fileExists(atPath:pending.path) else { throw LumaError.message("有待恢复的内核切换，请重新启动应用") }
        _ = try binary(for:artifact)
        try write(JSONEncoder().encode(Pending(before:selection(),candidate:artifact)),to:pending)
    }
    public func finishSwitch() throws {
        let change = try JSONDecoder().decode(Pending.self,from:Data(contentsOf:pending))
        var next = change.before
        next.active = change.candidate; next.previous = change.before.active; next.canRollback = true
        try write(JSONEncoder().encode(next),to:root.appendingPathComponent("selection.json"))
        try FileManager.default.removeItem(at:pending)
    }
    public func cancelSwitch() throws {
        guard FileManager.default.fileExists(atPath:pending.path) else { return }
        let change = try JSONDecoder().decode(Pending.self,from:Data(contentsOf:pending))
        if try selection() != change.before { try write(JSONEncoder().encode(change.before),to:root.appendingPathComponent("selection.json")) }
        try FileManager.default.removeItem(at:pending)
    }
    public func recoverPendingSwitch(runtime: URL) async throws {
        guard FileManager.default.fileExists(atPath:pending.path) else { return }
        let change = try JSONDecoder().decode(Pending.self,from:Data(contentsOf:pending))
        let allowed = [try binary(for:change.candidate),try binary(for:change.before.active)]
        let lease = runtime.appendingPathComponent("core-process.json")
        if FileManager.default.fileExists(atPath:lease.path) {
            let object = try JSONSerialization.jsonObject(with:Data(contentsOf:lease)) as? [String:Any]
            guard let path = object?["executable"] as? String,let executable = allowed.first(where:{$0.resolvingSymlinksInPath().path == path}) else { throw LumaError.message("内核恢复记录与切换候选不匹配") }
            try await CoreRunner.recoverAbandonedProcess(binary:executable,home:runtime)
        }
        try cancelSwitch()
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private var pending: URL { root.appendingPathComponent("pending-switch.json") }
    private func write(_ data: Data,to file: URL) throws {
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
