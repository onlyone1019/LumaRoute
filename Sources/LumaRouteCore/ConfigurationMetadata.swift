import Foundation

/// Small, transferable UI metadata derived before the composed document is serialized.
public struct ConfigurationMetadata: Sendable {
    public let nodeCount: Int
    public let groupOrder: [String]
    private let groups: [GroupSelection]

    init(nodeCount: Int,configuration: [String:Any]) {
        self.nodeCount = nodeCount
        let definitions = configuration["proxy-groups"] as? [[String:Any]] ?? []
        groupOrder = definitions.compactMap { $0["name"] as? String }
        let kinds = ["select":"Selector","url-test":"URLTest","fallback":"Fallback"]
        groups = definitions.compactMap { group in
            guard let name = group["name"] as? String,let type = group["type"] as? String,let kind = kinds[type] else { return nil }
            return GroupSelection(group:name,kind:kind,node:nil)
        }
    }

    public func selections(savedChoices: [String:String]) -> [GroupSelection] {
        groups.map { GroupSelection(group:$0.group,kind:$0.kind,node:savedChoices[$0.group]) }
    }
}
