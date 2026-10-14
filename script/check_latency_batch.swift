import Foundation
import LumaRouteCore

@main struct LatencyBatchCheck {
    @MainActor static func main() async throws {
        let store = AppStore()
        store.database.settings.controllerPort = Int(CommandLine.arguments[1])!
        store.database.settings.testConcurrency = 8
        let nodes = try (0..<64).map { i in
            try JSONDecoder().decode(ProxyNode.self, from: Data("{\"name\":\"node-\(i)\",\"type\":\"Shadowsocks\"}".utf8))
        }
        store.proxies = Dictionary(uniqueKeysWithValues:nodes.map { ($0.name,$0) })
        for iteration in 0..<10 {
            store.testNodes(nodes)
            await store.testTask?.value
            precondition(store.testProgress == nodes.count && !store.testRunning)
            precondition(store.nodeErrors.count == 7)
            precondition(store.proxies["node-1"]?.history?.last?.delay == 101)
            print("PASS batch \(iteration + 1): 64 results, including 7 failures")
        }
        store.testNodes(nodes)
        let cancelled = store.testTask
        try await Task.sleep(nanoseconds:5_000_000)
        store.cancelTests()
        let progress = store.testProgress
        await cancelled?.value
        precondition(!store.testRunning && store.testProgress == progress)
        print("PASS cancellation does not publish stale results")
        store.testNodes(nodes)
        let previous = store.testTask
        try await Task.sleep(nanoseconds:5_000_000)
        store.testNodes([nodes[1]])
        let latest = store.testTask
        await previous?.value
        await latest?.value
        precondition(store.testTotal == 1 && store.testProgress == 1 && store.nodeErrors.isEmpty && !store.testRunning)
        print("PASS immediate restart keeps only latest batch results")
        store.testNodes([])
        await store.testTask?.value
        precondition(store.testTotal == 0 && store.testProgress == 0 && !store.testRunning)
        print("PASS empty batch")
    }
}
