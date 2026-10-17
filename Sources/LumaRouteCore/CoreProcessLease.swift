import Foundation
import Darwin

/// Records an exact process incarnation, so a reused PID can never be killed.
final class CoreProcessLease {
    private struct Identity: Codable, Equatable {
        var pid: Int32
        var uid: UInt32
        var startedSeconds: UInt64
        var startedMicroseconds: UInt64
        var executable: String
    }
    private let file: URL
    private let binary: URL
    private var descriptor: Int32 = -1
    init(home: URL,binary: URL) {
        self.file = home.appendingPathComponent("core-process.json")
        self.binary = binary.resolvingSymlinksInPath()
    }
    deinit { release() }
    func acquire() throws {
        guard descriptor == -1 else { return }
        let lock = file.deletingLastPathComponent().appendingPathComponent("core-process.lock")
        let fd = open(lock.path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw LumaError.message("无法创建内核运行锁") }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else {
            close(fd); throw LumaError.message("此配置目录已有 LumaRoute 在运行")
        }
        descriptor = fd
    }
    // Recovery suspends, but never transfers the mutable lock descriptor out of
    // CoreRunner. The caller keeps its acquired lease alive until this returns.
    static func recoverOrphan(home: URL,binary: URL) async throws {
        let file = home.appendingPathComponent("core-process.json")
        let binary = binary.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath:file.path) else { return }
        let saved = try JSONDecoder().decode(Identity.self,from:Data(contentsOf:file))
        if let current = try identity(saved.pid), current == saved {
            guard current.uid == geteuid(),current.executable == binary.path else { throw LumaError.message("残留内核的所有者或路径不匹配，未终止进程") }
            guard let parent = parentPID(saved.pid),parent == 1 else { throw LumaError.message("该内核仍由其他运行中的应用管理") }
            // Recheck birth time immediately before each signal.
            if try identity(saved.pid) == saved { kill(saved.pid,SIGTERM) }
            for _ in 0..<40 {
                if try identity(saved.pid) != saved { break }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            if try identity(saved.pid) == saved { kill(saved.pid,SIGKILL) }
            for _ in 0..<20 {
                if try identity(saved.pid) != saved { break }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            guard try identity(saved.pid) != saved else { throw LumaError.message("残留内核尚未退出") }
        }
        try FileManager.default.removeItem(at:file)
    }
    func record(_ pid: Int32) throws {
        guard let value = try Self.identity(pid),value.uid == geteuid(),value.executable == binary.path else { throw LumaError.message("无法确认已启动内核的进程身份") }
        try JSONEncoder().encode(value).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func clear() {
        guard descriptor >= 0 else { return }
        try? FileManager.default.removeItem(at:file); release()
    }
    func release() {
        if descriptor >= 0 { flock(descriptor,LOCK_UN); close(descriptor); descriptor = -1 }
    }
    private static func parentPID(_ pid: Int32) -> UInt32? { info(pid)?.pbi_ppid }
    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        var value = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&value,Int32(size)) == size else { return nil }
        return value
    }
    private static func identity(_ pid: Int32) throws -> Identity? {
        guard let value = info(pid) else {
            if kill(pid,0) == -1 && errno == ESRCH { return nil }
            throw LumaError.message("无法读取内核进程身份，未终止进程")
        }
        // A zombie has exited and no longer owns sockets.
        if value.pbi_status == 5 { return nil }
        var buffer = [CChar](repeating:0,count:4*Int(MAXPATHLEN))
        guard proc_pidpath(pid,&buffer,UInt32(buffer.count)) > 0 else { throw LumaError.message("无法读取内核可执行文件路径") }
        return Identity(pid:pid,uid:value.pbi_uid,startedSeconds:value.pbi_start_tvsec,startedMicroseconds:value.pbi_start_tvusec,executable:CString.decodeUTF8(buffer))
    }
}
