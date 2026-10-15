import Foundation
import Yams

/// Persist only display names, never node credentials or raw configuration fragments.
public struct SubscriptionChange: Codable, Equatable {
    public var date: Date
    public var addedNodes: [String]
    public var removedNodes: [String]
    public var changedNodes: [String]
    public var addedGroups: [String]
    public var removedGroups: [String]
    public var changedProviders: [String]
    public var selectedNodesRemoved: [String]
    public var containsProviders: Bool
    public var uriNamesOnly: Bool
    public var summary: String {
        if addedNodes.isEmpty && removedNodes.isEmpty && changedNodes.isEmpty { return "配置有变化 · 节点名单未变" }
        return "节点新增 \(addedNodes.count) · 移除 \(removedNodes.count) · 修改 \(changedNodes.count)"
    }
    public static func compare(old: String,new: String,selectedNodes: [String] = []) throws -> Self {
        func inventory(_ text: String) throws -> (nodes:[String:String],groups:Set<String>,providers:[String:String],uri:Bool) {
            let parsed = try ConfigComposer.parse(text)
            var nodes: [String:String] = [:]
            if let raw = parsed["_lumaroute_raw_provider"] as? String {
                for (index,line) in raw.split(whereSeparator:\.isNewline).enumerated() {
                    let fragment = URLComponents(string:String(line))?.fragment
                    let name = fragment.flatMap { $0.isEmpty ? nil:$0 } ?? "未命名节点 \(index+1)"
                    nodes[name] = CoreUpdates.digest(Data(line.utf8))
                }
            } else {
                for node in parsed["proxies"] as? [[String:Any]] ?? [] {
                    if let name = node["name"] as? String { nodes[name] = CoreUpdates.digest(Data(try Yams.dump(object:node,sortKeys:true).utf8)) }
                }
            }
            var providers: [String:String] = [:]
            for (name,value) in parsed["proxy-providers"] as? [String:Any] ?? [:] {
                providers[name] = CoreUpdates.digest(Data(try Yams.dump(object:value,sortKeys:true).utf8))
            }
            return (nodes,Set((parsed["proxy-groups"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }),providers,parsed["_lumaroute_raw_provider"] != nil)
        }
        let a = try inventory(old), b = try inventory(new)
        let oldNames = Set(a.nodes.keys),newNames = Set(b.nodes.keys)
        let removed = oldNames.subtracting(newNames).sorted()
        return Self(date:Date(),addedNodes:newNames.subtracting(oldNames).sorted(),removedNodes:removed,changedNodes:oldNames.intersection(newNames).filter { a.nodes[$0] != b.nodes[$0] }.sorted(),addedGroups:b.groups.subtracting(a.groups).sorted(),removedGroups:a.groups.subtracting(b.groups).sorted(),changedProviders:Set(a.providers.keys).union(b.providers.keys).filter { a.providers[$0] != b.providers[$0] }.sorted(),selectedNodesRemoved:removed.filter { selectedNodes.contains($0) },containsProviders:(!a.providers.isEmpty || !b.providers.isEmpty) && !a.uri && !b.uri,uriNamesOnly:a.uri || b.uri)
    }
}
