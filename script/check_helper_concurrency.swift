import Foundation
import LumaRouteCore

actor HelperController {
    private(set) var calls = 0
    func execute(_ request: HelperRequest,uid: uid_t) async throws -> HelperResponse {
        calls += 1
        await Task.yield()
        if request.action == "fail" { throw LumaError.message("fixture password=private") }
        return HelperResponse(success:true,message:"\(uid):\(request.action)",running:true)
    }
}

@main struct HelperConcurrencyCheck {
    struct Case: Sendable {
        let handler: ClientHandler
        let data: Data
        let success: Bool
        let message: String
    }
    static func sendable<T: Sendable>(_ type: T.Type) {}
    static func require(_ condition: Bool,_ message: String) {
        if !condition { FileHandle.standardError.write(Data(("FAIL "+message+"\n").utf8)); exit(1) }
    }
    static func main() async throws {
        // This file builds in Swift 6: removing a boundary conformance is an error.
        sendable(AppDatabase.self); sendable(Profile.self); sendable(NetworkSettings.self)
        sendable(SubscriptionComposition.self); sendable(SubscriptionChange.self)
        sendable(GroupStrategy.self); sendable(GroupSelection.self)
        sendable(HelperRequest.self); sendable(HelperResponse.self); sendable(ClientHandler.self)
        sendable(MihomoAPI.self); sendable(ConnectionsResponse.self); sendable(LogEntry.self)
        sendable(DiagnosticCheck.self); sendable(SubscriptionDownload.self)
        sendable(CoreUpdates.self); sendable(LocalStore.self); sendable(SQLiteSecrets.self)
        print("PASS Swift 6 compiler verifies boundary Sendable contracts")

        let controller = HelperController()
        let normal = ClientHandler(uid:501,controller:controller,healthOnly:false)
        let health = ClientHandler(uid:502,controller:controller,healthOnly:true)
        func wire(_ action: String) throws -> Data { try JSONEncoder().encode(HelperRequest(action:action)) }
        let cases = [
            Case(handler:normal,data:try wire("status"),success:true,message:"501:status"),
            Case(handler:normal,data:try wire("fail"),success:false,message:"[已隐藏]"),
            Case(handler:health,data:try wire("apply"),success:false,message:"启动验证"),
            Case(handler:health,data:try wire("status"),success:true,message:"502:status"),
            Case(handler:normal,data:Data("{".utf8),success:false,message:""),
            Case(handler:normal,data:Data(repeating:0,count:10*1024*1024+1),success:false,message:"请求过大")
        ]
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<16 {
                for item in cases {
                    group.addTask {
                        // Checked continuations catch duplicate callbacks; a missing
                        // callback is bounded by the runner's process timeout.
                        let data: Data = await withCheckedContinuation { continuation in
                            item.handler.perform(item.data) { response in continuation.resume(returning:response) }
                        }
                        let response = try JSONDecoder().decode(HelperResponse.self,from:data)
                        require(response.success == item.success,"response belongs to its concurrent request")
                        require(item.message.isEmpty ? !response.message.isEmpty:response.message.contains(item.message),"reply preserves the expected error/status")
                        require(!response.message.contains("private"),"reply errors remain redacted")
                    }
                }
            }
            try await group.waitForAll()
        }
        let calls = await controller.calls
        require(calls == 48,"health-only, malformed and oversized requests never reach the controller")
        print("PASS 96 concurrent requests each reply once across success/error/health-only/invalid/oversized paths")
        print("helper concurrency suite passed: 2 scenarios")
    }
}
