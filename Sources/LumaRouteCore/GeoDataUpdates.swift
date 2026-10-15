import Foundation

public struct GeoAsset {
    public let name: String
    public let url: URL
    public let sha256: String
    public let size: Int
    public static func parse(_ data: Data) throws -> [GeoAsset] {
        let names = ["geoip.metadb":"geoip.metadb","geoip.dat":"GeoIP.dat","geosite.dat":"GeoSite.dat"]
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let assets = object["assets"] as? [[String:Any]] else { throw LumaError.message("规则数据库发布信息无效") }
        var selected: [GeoAsset] = []
        for asset in assets {
            guard let original = asset["name"] as? String,let name = names[original] else { continue }
            guard let address = asset["browser_download_url"] as? String,
                  address == "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/"+original,
                  let url = URL(string:address),let size = asset["size"] as? Int,size > 0,size <= 64*1024*1024,
                  let digest = asset["digest"] as? String,digest.range(of:"^sha256:[a-f0-9]{64}$",options:.regularExpression) != nil else { throw LumaError.message("官方规则数据库缺少有效文件和 SHA256") }
            selected.append(GeoAsset(name:name,url:url,sha256:String(digest.dropFirst(7)),size:size))
        }
        guard selected.count == 3,Set(selected.map(\.name)).count == 3,selected.reduce(0,{$0+$1.size}) <= 96*1024*1024 else { throw LumaError.message("官方规则数据库文件不完整或过大") }
        return selected
    }
    public static func download(policy: GeoSitePolicy,session: URLSession = .shared) async throws -> [String:Data] {
        let url = URL(string:"https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/tags/latest")!
        var request = URLRequest(url:url,timeoutInterval:25); request.setValue("LumaRoute/0.1",forHTTPHeaderField:"User-Agent")
        let (manifest,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,manifest.count <= 4*1024*1024 else { throw LumaError.message("无法查询官方规则数据库") }
        let assets = try parse(manifest)
        return try await verified(assets,policy:policy) { asset in
            let (file,response) = try await session.download(for:URLRequest(url:asset.url,timeoutInterval:120))
            defer { try? FileManager.default.removeItem(at:file) }
            let size = (try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue
            guard (response as? HTTPURLResponse)?.statusCode == 200,size == asset.size else { throw LumaError.message("规则数据库下载失败或大小不匹配") }
            let data = try Data(contentsOf:file)
            return data
        }
    }
    static func verified(_ assets: [GeoAsset],policy: GeoSitePolicy,fetch: (GeoAsset) async throws -> Data) async throws -> [String:Data] {
        var payloads: [String:Data] = [:]
        for asset in assets {
            let data = try await fetch(asset)
            guard data.count == asset.size,CoreUpdates.digest(data) == asset.sha256 else { throw LumaError.message("规则数据库大小或 SHA256 校验失败，当前版本未改变") }
            payloads[asset.name] = data
        }
        return try policy.protect(payloads)
    }
}

/// Journals file replacement before touching any live GEO file.
public final class GeoDataUpdates {
    public static let names = ["geoip.metadb","GeoIP.dat","GeoSite.dat"]
    private struct FileRecord: Codable { var name: String; var digest: String? }
    private struct State: Codable { var previous: UUID? }
    private struct Pending: Codable { var before: UUID; var state: State }
    public let home: URL
    private let root: URL
    private var journal: URL { root.appendingPathComponent("pending.json") }
    public init(home: URL) throws {
        self.home = home.standardizedFileURL; root = home.standardizedFileURL.appendingPathComponent("geo-history")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if FileManager.default.fileExists(atPath:journal.path) { try cancel() }
    }
    public var canRollback: Bool { (try? state().previous) != nil }
    public func fingerprints() throws -> [String:String?] {
        var result: [String:String?] = [:]
        for name in Self.names {
            let file = home.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath() == file else { throw LumaError.message("规则数据库路径无效") }
            if FileManager.default.fileExists(atPath:file.path) { result[name] = .some(CoreUpdates.digest(try Data(contentsOf:file))) }
            else { result[name] = .some(nil) }
        }
        return result
    }
    private func state() throws -> State {
        let file = root.appendingPathComponent("state.json")
        return FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode(State.self,from:Data(contentsOf:file)) : State(previous:nil)
    }
    public func beginUpdate(_ payloads: [String:Data]) throws {
        guard Set(payloads.keys) == Set(Self.names),payloads.values.allSatisfy({!$0.isEmpty && $0.count <= 64*1024*1024}) else { throw LumaError.message("规则数据库更新文件不完整") }
        try begin()
        do { try replace(payloads.mapValues(Optional.some)) }
        catch { try? cancel(); throw error }
    }
    public func beginRollback(policy: GeoSitePolicy? = nil) throws {
        guard let previous = try state().previous else { throw LumaError.message("没有可回退的规则数据库") }
        var files = try readSnapshot(previous)
        if let policy {
            guard let site = files["GeoSite.dat"] ?? nil else { throw LumaError.message("旧快照缺少 GeoSite 数据，无法安全回退") }
            files["GeoSite.dat"] = .some(try policy.applying(to:site))
        }
        try begin()
        do { try replace(files) } catch { try? cancel(); throw error }
    }
    private func begin() throws {
        guard !FileManager.default.fileExists(atPath:journal.path) else { throw LumaError.message("有待恢复的规则数据库更新") }
        let before = try snapshot()
        try write(JSONEncoder().encode(Pending(before:before,state:state())),to:journal)
    }
    public func finish() throws {
        let pending = try JSONDecoder().decode(Pending.self,from:Data(contentsOf:journal))
        try write(JSONEncoder().encode(State(previous:pending.before)),to:root.appendingPathComponent("state.json"))
        try FileManager.default.removeItem(at:journal)
    }
    public func cancel() throws {
        guard FileManager.default.fileExists(atPath:journal.path) else { return }
        let pending = try JSONDecoder().decode(Pending.self,from:Data(contentsOf:journal))
        try replace(readSnapshot(pending.before))
        try write(JSONEncoder().encode(pending.state),to:root.appendingPathComponent("state.json"))
        try FileManager.default.removeItem(at:journal)
    }
    private func snapshot() throws -> UUID {
        let id = UUID(); let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var records: [FileRecord] = []
        for name in Self.names {
            let file = home.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath() == file else { throw LumaError.message("规则数据库路径不能是符号链接") }
            let data = FileManager.default.fileExists(atPath:file.path) ? try Data(contentsOf:file) : nil
            if let data { try write(data,to:directory.appendingPathComponent(name)) }
            records.append(FileRecord(name:name,digest:data.map(CoreUpdates.digest)))
        }
        try write(JSONEncoder().encode(records),to:directory.appendingPathComponent("manifest.json"))
        return id
    }
    private func readSnapshot(_ id: UUID) throws -> [String:Data?] {
        let directory = root.appendingPathComponent(id.uuidString)
        guard directory.resolvingSymlinksInPath() == directory else { throw LumaError.message("规则数据库备份路径无效") }
        let records = try JSONDecoder().decode([FileRecord].self,from:Data(contentsOf:directory.appendingPathComponent("manifest.json")))
        guard records.count == Self.names.count,Set(records.map(\.name)) == Set(Self.names) else { throw LumaError.message("规则数据库备份记录不完整") }
        var files: [String:Data?] = [:]
        for record in records {
            if let digest = record.digest {
                let file = directory.appendingPathComponent(record.name)
                guard file.resolvingSymlinksInPath() == file else { throw LumaError.message("规则数据库备份路径无效") }
                let data = try Data(contentsOf:file)
                guard CoreUpdates.digest(data) == digest else { throw LumaError.message("规则数据库备份已改变") }
                files[record.name] = .some(data)
            } else { files[record.name] = .some(nil) }
        }
        return files
    }
    private func replace(_ files: [String:Data?]) throws {
        for name in Self.names {
            let file = home.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath() == file else { throw LumaError.message("规则数据库路径无效") }
            if let data = files[name] ?? nil { try write(data,to:file) }
            else if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
        }
    }
    private func write(_ data: Data,to file: URL) throws {
        if (try? Data(contentsOf:file)) == data { return }
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
