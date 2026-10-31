import Foundation

// In-memory SystemConfiguration double; the production SystemNetwork methods
// below never see live preferences or require real administrator privileges.
enum LumaError: Error { case message(String) }
public struct NetworkSettings { var systemProxy=false,tun=false,dnsHijack=true;var mixedPort=19790;var bypass:[String]=[] }
final class FixtureProtocol { var configuration:[String:Any]?;init(_ value:[String:Any]?) { configuration=value } }
final class SCNetworkService { let identifier:String;var protocols:[String:FixtureProtocol];init(_ id:String,_ protocols:[String:FixtureProtocol]) { identifier=id;self.protocols=protocols } }
final class FixturePreferences {}
nonisolated(unsafe) var fixtureServices:[SCNetworkService]=[]
nonisolated(unsafe) var fixtureCommit=true
nonisolated(unsafe) var fixtureWrites=0
nonisolated(unsafe) let kSCNetworkProtocolTypeProxies="Proxies" as CFString
nonisolated(unsafe) let kSCNetworkProtocolTypeDNS="DNS" as CFString
func geteuid()->uid_t { 0 }
func SCPreferencesCreate(_ allocator:CFAllocator?,_ name:CFString,_ id:CFString?)->FixturePreferences? { FixturePreferences() }
func SCPreferencesLock(_ prefs:FixturePreferences,_ wait:Bool)->Bool { true }
func SCPreferencesUnlock(_ prefs:FixturePreferences) {}
func SCNetworkServiceCopyAll(_ prefs:FixturePreferences)->NSArray? { fixtureServices as NSArray }
func SCNetworkServiceGetServiceID(_ service:SCNetworkService)->CFString? { service.identifier as CFString }
func SCNetworkServiceGetEnabled(_ service:SCNetworkService)->Bool { true }
func SCNetworkServiceCopyProtocol(_ service:SCNetworkService,_ type:CFString)->FixtureProtocol? { service.protocols[type as String] }
func SCNetworkProtocolGetConfiguration(_ proto:FixtureProtocol)->CFDictionary? { proto.configuration.map { $0 as CFDictionary } }
func SCNetworkProtocolSetConfiguration(_ proto:FixtureProtocol,_ value:CFDictionary?)->Bool { fixtureWrites+=1;proto.configuration=value as? [String:Any];return true }
func SCPreferencesCommitChanges(_ prefs:FixturePreferences)->Bool { fixtureCommit }
func SCPreferencesApplyChanges(_ prefs:FixturePreferences)->Bool { true }

// PRODUCTION_SYSTEM_NETWORK

@main struct RecoveryCheck {
    static func main() throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1])
        let original:[String:Any] = ["HTTPEnable":0]
        let applied:[String:Any] = ["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":19790]
        let foreign:[String:Any] = ["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":17890]
        let record:[String:Any] = ["original":original,"applied":applied]
        func journal(_ name:String,_ records:[String:[String:Any]]) throws -> URL {
            let file=folder.appendingPathComponent(name+".plist")
            try PropertyListSerialization.data(fromPropertyList:records,format:.binary,options:0).write(to:file)
            fixtureWrites=0;fixtureCommit=true
            return file
        }
        func saved(_ file:URL) throws -> [String:[String:Any]] {
            try PropertyListSerialization.propertyList(from:Data(contentsOf:file),format:nil) as! [String:[String:Any]]
        }
        let live=FixtureProtocol(foreign)
        fixtureServices=[SCNetworkService("live",["Proxies":live])]
        let missing=try journal("deleted-service",["deleted:Proxies":record])
        try SystemNetwork(journal:missing).restore()
        guard try saved(missing).isEmpty,fixtureWrites==0,NSDictionary(dictionary:live.configuration!).isEqual(to:foreign) else { throw LumaError.message("deleted service snapshot must clear without changing live proxy settings") }
        print("PASS deleted service journal clears without touching live preferences")

        fixtureServices=[SCNetworkService("live",[:])]
        let missingProtocol=try journal("deleted-protocol",["live:Proxies":record])
        try SystemNetwork(journal:missingProtocol).restore()
        guard try saved(missingProtocol).isEmpty,fixtureWrites==0 else { throw LumaError.message("removed protocol snapshot must clear") }
        print("PASS deleted protocol journal clears without creating a protocol")

        let owned=FixtureProtocol(applied)
        fixtureServices=[SCNetworkService("live",["Proxies":owned])]
        let matching=try journal("owned",["live:Proxies":record,"deleted:DNS":record])
        try SystemNetwork(journal:matching).restore()
        guard try saved(matching).isEmpty,fixtureWrites==1,NSDictionary(dictionary:owned.configuration!).isEqual(to:original) else { throw LumaError.message("owned configuration must restore its original value") }
        print("PASS still-owned settings restore before journal clears")

        fixtureServices=[SCNetworkService("live",["Proxies":live])]
        let overwritten=try journal("foreign",["live:Proxies":record,"deleted:DNS":record])
        try SystemNetwork(journal:overwritten).restore()
        guard try saved(overwritten).isEmpty,fixtureWrites==0,NSDictionary(dictionary:live.configuration!).isEqual(to:foreign) else { throw LumaError.message("another application's settings must remain intact") }
        print("PASS another application's proxy settings remain intact")

        let failed=try journal("failed-commit",["deleted:Proxies":record]);fixtureCommit=false
        var commitRejected=false
        do { try SystemNetwork(journal:failed).restore() } catch { commitRejected=true }
        guard try commitRejected && !saved(failed).isEmpty else { throw LumaError.message("failed restoration discarded its journal") }
        print("PASS commit failure preserves recovery records")

        let unknown=try journal("unknown",["unrecognized-key":record])
        try SystemNetwork(journal:unknown).restore()
        guard try !saved(unknown).isEmpty else { throw LumaError.message("unknown record keys must remain for inspection") }
        print("PASS unknown journal entries remain fail-closed")

        let corrupt=folder.appendingPathComponent("corrupt.plist")
        let corruptData=try PropertyListSerialization.data(fromPropertyList:["unexpected-array"],format:.binary,options:0)
        try corruptData.write(to:corrupt)
        var corruptRejected=false
        do { _ = try SystemNetwork(journal:corrupt) } catch { corruptRejected=true }
        guard try corruptRejected && Data(contentsOf:corrupt)==corruptData else { throw LumaError.message("malformed journal must be rejected without modification") }
        print("PASS malformed journal remains untouched")
    }
}
