import Foundation
import Darwin

/// Fills missing kernel metadata by matching the current user's live socket endpoints.
/// Multiple process paths owning the same endpoint remain unknown.
public enum ConnectionProcesses {
    private struct Endpoint: Hashable { var network: String; var address: String; var port: Int; var destinationPort: Int }
    public static func enrich(_ connections: [LiveConnection],mixedPort: Int) async -> [LiveConnection] {
        await Task.detached(priority:.utility) { resolve(connections,mixedPort:mixedPort) }.value
    }
    private static func resolve(_ connections: [LiveConnection],mixedPort: Int) -> [LiveConnection] {
        func endpoint(_ connection: LiveConnection) -> Endpoint? {
            guard connection.metadata.processPath?.isEmpty != false,
                  let network = connection.metadata.network?.lowercased(),["tcp","udp"].contains(network),
                  let address = connection.metadata.sourceIP,let text = connection.metadata.sourcePort,let port = Int(text) else { return nil }
            let direct = connection.metadata.type?.lowercased() == "tun"
            return Endpoint(network:network,address:address,port:port,destinationPort:direct ? Int(connection.metadata.destinationPort ?? "") ?? 0:mixedPort)
        }
        let requested = Set(connections.compactMap(endpoint))
        guard !requested.isEmpty else { return connections }
        let count = proc_listallpids(nil,0)
        guard count > 0,count < 100_000 else { return connections }
        var pids = [pid_t](repeating:0,count:Int(count)+128)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress,Int32($0.count)) }
        guard found > 0 else { return connections }
        var owners: [Endpoint:Set<String>] = [:]
        let deadline = Date().addingTimeInterval(1)
        for pid in pids.prefix(min(Int(found),pids.count)) where pid > 0 {
            if Date() > deadline { return connections }
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&bsd,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  bsd.pbi_uid == getuid() else { continue }
            let size = proc_pidinfo(pid,PROC_PIDLISTFDS,0,nil,0)
            guard size > 0,size < 8*1024*1024 else { continue }
            var descriptors = [proc_fdinfo](repeating:proc_fdinfo(),count:Int(size)/MemoryLayout<proc_fdinfo>.size+16)
            let bytes = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid,PROC_PIDLISTFDS,0,$0.baseAddress,Int32($0.count)) }
            guard bytes > 0 else { continue }
            var matches: Set<Endpoint> = []
            for fd in descriptors.prefix(Int(bytes)/MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var socket = socket_fdinfo()
                guard proc_pidfdinfo(pid,fd.proc_fd,PROC_PIDFDSOCKETINFO,&socket,Int32(MemoryLayout<socket_fdinfo>.size)) == MemoryLayout<socket_fdinfo>.size else { continue }
                let network: String; let info: in_sockinfo
                if socket.psi.soi_kind == SOCKINFO_TCP { network = "tcp"; info = socket.psi.soi_proto.pri_tcp.tcpsi_ini }
                else if socket.psi.soi_kind == SOCKINFO_IN,socket.psi.soi_protocol == IPPROTO_UDP { network = "udp"; info = socket.psi.soi_proto.pri_in }
                else { continue }
                let port = Int(UInt16(truncatingIfNeeded:info.insi_lport).bigEndian)
                let foreign = Int(UInt16(truncatingIfNeeded:info.insi_fport).bigEndian)
                guard requested.contains(where:{$0.network == network && $0.port == port}) else { continue }
                var buffer = [CChar](repeating:0,count:Int(INET6_ADDRSTRLEN))
                var v4 = info.insi_laddr.ina_46.i46a_addr4
                var v6 = info.insi_laddr.ina_6
                let address: String
                if info.insi_vflag & UInt8(INI_IPV4) != 0 {
                    guard inet_ntop(AF_INET,&v4,&buffer,socklen_t(buffer.count)) != nil else { continue }
                    address = String(cString:buffer)
                } else {
                    guard inet_ntop(AF_INET6,&v6,&buffer,socklen_t(buffer.count)) != nil else { continue }
                    address = String(cString:buffer)
                }
                for target in requested where target.network == network && target.port == port && (target.destinationPort == foreign || network == "udp" && foreign == 0) && (target.address == address || network == "udp" && ["0.0.0.0","::"].contains(address)) { matches.insert(target) }
            }
            guard !matches.isEmpty else { continue }
            var path = [CChar](repeating:0,count:4*Int(MAXPATHLEN))
            guard proc_pidpath(pid,&path,UInt32(path.count)) > 0 else { continue }
            var after = proc_bsdinfo()
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  after.pbi_start_tvsec == bsd.pbi_start_tvsec,after.pbi_start_tvusec == bsd.pbi_start_tvusec else { continue }
            for match in matches { owners[match,default:[]].insert(String(cString:path)) }
        }
        return connections.map { original in
            var connection = original
            if let key = endpoint(original),let paths = owners[key],paths.count == 1,let path = paths.first {
                connection.metadata.processPath = path
                connection.metadata.process = URL(fileURLWithPath:path).lastPathComponent
                connection.metadata.processSource = "macOS 本机查询"
            }
            return connection
        }
    }
}
