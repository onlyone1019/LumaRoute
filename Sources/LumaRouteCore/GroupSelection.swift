import Foundation

public struct GroupSelection:Codable {
    public var group:String
    public var kind:String
    public var node:String?
    public init(group: String,kind: String,node: String?) { self.group = group; self.kind = kind; self.node = node }
    public static func capture(_ proxies:[String:ProxyNode])->[Self] {
        proxies.values.compactMap { group in
            if group.type == "Selector",let node = group.now { return Self(group:group.name,kind:group.type,node:node) }
            if ["URLTest","Fallback"].contains(group.type) { return Self(group:group.name,kind:group.type,node:group.fixed?.isEmpty == false ? group.fixed:nil) }
            return nil
        }.sorted { $0.group < $1.group }
    }
    public static func restore(_ selections:[Self],api:MihomoAPI) async throws {
        guard !selections.isEmpty else { return }
        let available = try await api.proxies()
        for selection in selections {
            guard let group = available[selection.group],group.type == selection.kind else { continue }
            if let node = selection.node,group.all?.contains(node) == true { try await api.select(group:selection.group,node:node) }
            else if selection.node == nil,["URLTest","Fallback"].contains(group.type),group.fixed?.isEmpty == false { try await api.clearFixed(group:selection.group) }
        }
    }
}
