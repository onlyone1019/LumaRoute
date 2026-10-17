import Foundation

public struct AppVersion: Equatable, Comparable, Sendable {
    public let version: String
    public let build: Int
    private let components: [Int]
    public var label: String { "\(version) · Build \(build)" }

    public init?(version: String,build: Int) {
        let parts = version.split(separator:".",omittingEmptySubsequences:false)
        guard build >= 0,parts.count == 3,
              parts.allSatisfy({ $0.range(of:"^(0|[1-9][0-9]*)$",options:.regularExpression) != nil }),
              parts.compactMap({ Int($0) }).count == 3 else { return nil }
        self.version = version; self.build = build; components = parts.compactMap { Int($0) }
    }
    public init?(bundle: Bundle) {
        guard let version = bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,
              let value = bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String,let build = Int(value)
        else { return nil }
        self.init(version:version,build:build)
    }
    public static func < (lhs: Self,rhs: Self) -> Bool {
        if lhs.components != rhs.components { return lhs.components.lexicographicallyPrecedes(rhs.components) }
        return lhs.build < rhs.build
    }
}

public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    public let releaseURL: URL
    public let downloadURL: URL
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    public static func parse(_ data: Data,architecture: String = Self.architecture) throws -> Self {
        guard ["arm64","x86_64"].contains(architecture),
              let release = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              release["draft"] as? Bool == false,release["prerelease"] as? Bool == false,
              let tag = release["tag_name"] as? String,tag.count <= 80,tag.hasPrefix("v"),
              let address = release["html_url"] as? String,
              address == "https://github.com/onlyone1019/LumaRoute/releases/tag/\(tag)",
              let releaseURL = URL(string:address),let assets = release["assets"] as? [[String:Any]]
        else { throw LumaError.message("应用发布信息无效，请稍后重试") }
        let parts = String(tag.dropFirst()).components(separatedBy:"-build.")
        guard parts.count <= 2,let base = AppVersion(version:parts[0],build:0) else {
            throw LumaError.message("应用发布版本格式无效")
        }
        let prefix = "LumaRoute-\(base.version)-build.",suffix = "-macos-\(architecture).dmg"
        let candidates = assets.filter {
            guard let name = $0["name"] as? String else { return false }
            return name.hasPrefix(prefix) && name.hasSuffix(suffix)
        }
        guard candidates.count == 1,let asset = candidates.first,let name = asset["name"] as? String,
              let build = Int(name.dropFirst(prefix.count).dropLast(suffix.count)),
              name == "\(prefix)\(build)\(suffix)",let version = AppVersion(version:base.version,build:build),
              parts.count == 1 || parts[1] == String(build),
              let size = asset["size"] as? Int,size > 0,size <= 512*1024*1024,
              let download = asset["browser_download_url"] as? String,
              download == "https://github.com/onlyone1019/LumaRoute/releases/download/\(tag)/\(name)",
              let downloadURL = URL(string:download)
        else { throw LumaError.message("正式版本缺少适用于本机的安装包") }
        return Self(version:version,releaseURL:releaseURL,downloadURL:downloadURL)
    }
    public static func latest(session: URLSession = .shared) async throws -> Self {
        var request = URLRequest(url:URL(string:"https://api.github.com/repos/onlyone1019/LumaRoute/releases/latest")!,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:25)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue(VersionInfo.current.userAgent,forHTTPHeaderField:"User-Agent")
        request.setValue("2022-11-28",forHTTPHeaderField:"X-GitHub-Api-Version")
        let data: Data,response: URLResponse
        do { (data,response) = try await session.data(for:request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LumaError.message("无法检查应用更新，请检查网络后重试") }
        guard let http = response as? HTTPURLResponse else { throw LumaError.message("无法读取应用发布信息") }
        if [403,429].contains(http.statusCode) { throw LumaError.message("检查更新受到限制，请稍后重试") }
        if http.statusCode == 404 { throw LumaError.message("暂时没有可用的正式版本") }
        guard http.statusCode == 200,data.count < 2*1024*1024 else { throw LumaError.message("无法读取应用发布信息，请稍后重试") }
        return try parse(data)
    }
}
