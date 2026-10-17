import XCTest
import Darwin
@testable import LumaRouteCore

final class ApplyRecoveryTests: XCTestCase {
    private func availablePort() throws -> Int {
        let fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw LumaError.message("fixture socket failed") }
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw LumaError.message("fixture bind failed") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }
        guard status == 0 else { throw LumaError.message("fixture getsockname failed") }
        return Int(UInt16(bigEndian:address.sin_port))
    }
    private func fixture(_ operation: (CoreRunner,MihomoAPI,URL,NetworkSettings,String) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/apply_core.py")
        try FileManager.default.copyItem(at:source,to:root.appendingPathComponent("__main__.py"))
        let lookup = Process(),output = Pipe()
        lookup.executableURL = URL(fileURLWithPath:"/usr/bin/xcrun"); lookup.arguments = ["--find","python3"]; lookup.standardOutput = output
        try lookup.run(); lookup.waitUntilExit()
        guard lookup.terminationStatus == 0 else { throw LumaError.message("fixture Python unavailable") }
        let path = String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let binary = URL(fileURLWithPath:path).resolvingSymlinksInPath()
        var settings = NetworkSettings(); settings.controllerPort = try availablePort()
        repeat { settings.mixedPort = try availablePort() } while settings.mixedPort == settings.controllerPort
        let runner = CoreRunner(binary:binary,home:root,secret:"fixture-secret")
        let yaml = try ConfigComposer.compose(source:nil,settings:settings,rules:[],secret:"fixture-secret")
        let api = MihomoAPI(port:settings.controllerPort,secret:"fixture-secret")
        do {
            try await runner.start(yaml:yaml,settings:settings)
            try await operation(runner,api,root,settings,yaml)
        } catch { await runner.stop(); throw error }
        await runner.stop()
    }
    private func candidate(_ settings: NetworkSettings) throws -> (NetworkSettings,String) {
        var next = settings; next.mode = .global
        return (next,try ConfigComposer.compose(source:nil,settings:next,rules:[],secret:"fixture-secret"))
    }
    private func state(_ api: MihomoAPI) async throws -> [String:Any] {
        let data = try await api.data(["configs"])
        return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    }
    func testRejectedReloadRestoresOldRuntimeAndFileWithoutRestart() async throws {
        try await fixture { runner,api,root,settings,yaml in
            let before = try await self.state(api)
            let (next,value) = try self.candidate(settings)
            do { try await runner.apply(yaml:value,settings:next); XCTFail("candidate must fail") }
            catch let failure as CoreApplyError {
                XCTAssertEqual(failure.recovery,.rolledBack); XCTAssertNil(failure.rollback)
            }
            let after = try await self.state(api)
            XCTAssertEqual(after["mode"] as? String,"rule")
            XCTAssertEqual(after["pid"] as? Int,before["pid"] as? Int)
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("active.yaml")),yaml)
            let running = await runner.running; XCTAssertTrue(running)
        }
    }
    func testCandidateProviderFailureCanRollBackToHealthyOldConfiguration() async throws {
        try await fixture { runner,api,root,settings,_ in
            try "candidate-providers-fail".write(to:root.appendingPathComponent("scenario"),atomically:true,encoding:.utf8)
            let (next,value) = try self.candidate(settings)
            do { try await runner.apply(yaml:value,settings:next); XCTFail("provider failure must surface") }
            catch let failure as CoreApplyError { XCTAssertEqual(failure.recovery,.rolledBack) }
            let after = try await self.state(api); XCTAssertEqual(after["mode"] as? String,"rule")
        }
    }
    func testRollbackRequiresReloadHealthProvidersAndPersistence() async throws {
        for fault in ["rollback-reload-fails","rollback-version-fails","rollback-providers-fail","rollback-persist-fails"] {
            try await fixture { runner,_,root,settings,_ in
                try fault.write(to:root.appendingPathComponent("scenario"),atomically:true,encoding:.utf8)
                let (next,value) = try self.candidate(settings)
                do { try await runner.apply(yaml:value,settings:next); XCTFail(fault) }
                catch let failure as CoreApplyError {
                    XCTAssertEqual(failure.recovery,.stateUnknown,fault)
                    XCTAssertNotNil(failure.rollback,fault)
                    XCTAssertFalse(failure.localizedDescription.contains("已恢复并确认"),fault)
                }
            }
        }
    }
    func testPortChangeReportsWhetherOldCoreRestartWasConfirmed() async throws {
        for (fault,expected) in [("restart-fails",CoreApplyError.Recovery.rolledBack),("rollback-restart-fails",.stateUnknown)] {
            try await fixture { runner,api,root,settings,yaml in
                try fault.write(to:root.appendingPathComponent("scenario"),atomically:true,encoding:.utf8)
                var next = settings
                repeat { next.controllerPort = try self.availablePort() } while next.controllerPort == settings.controllerPort || next.controllerPort == settings.mixedPort
                next.mode = .global
                let value = try ConfigComposer.compose(source:nil,settings:next,rules:[],secret:"fixture-secret")
                do { try await runner.apply(yaml:value,settings:next); XCTFail(fault) }
                catch let failure as CoreApplyError { XCTAssertEqual(failure.recovery,expected,fault) }
                if expected == .rolledBack {
                    let after = try await self.state(api); XCTAssertEqual(after["mode"] as? String,"rule")
                    XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("active.yaml")),yaml)
                }
            }
        }
    }
    func testSuccessfulApplyStillCommitsCandidate() async throws {
        try await fixture { runner,api,root,settings,_ in
            try "success".write(to:root.appendingPathComponent("scenario"),atomically:true,encoding:.utf8)
            let (next,value) = try self.candidate(settings)
            try await runner.apply(yaml:value,settings:next)
            let after = try await self.state(api); XCTAssertEqual(after["mode"] as? String,"global")
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("active.yaml")),value)
        }
    }
    func testFailedFirstStartCannotReportRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var settings = NetworkSettings(); settings.controllerPort = try availablePort()
        repeat { settings.mixedPort = try availablePort() } while settings.mixedPort == settings.controllerPort
        let runner = CoreRunner(binary:root.appendingPathComponent("missing-core"),home:root,secret:"fixture-secret")
        let yaml = try ConfigComposer.compose(source:nil,settings:settings,rules:[],secret:"fixture-secret")
        do { try await runner.apply(yaml:yaml,settings:settings); XCTFail("missing core must fail") }
        catch let failure as CoreApplyError { XCTAssertEqual(failure.recovery,.stateUnknown) }
        await runner.stop()
    }
}
