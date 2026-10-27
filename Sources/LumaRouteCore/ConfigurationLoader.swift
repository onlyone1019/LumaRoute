import Foundation

/// Resolve a frozen UI snapshot and compose subscriptions away from MainActor.
public actor ConfigurationLoader {
    public init() {}

    public func source(_ id: UUID? = nil,configuration: AppDatabase,store: LocalStore,overrides: [UUID:String] = [:]) throws -> String? {
        try Task.checkCancellation()
        guard let id = id ?? configuration.activeProfileID else { return nil }
        let profile = configuration.profiles.first { $0.id == id }
        let result: String
        if let composition = profile?.composition {
            var contents: [UUID:String] = [:]
            for member in composition.profileIDs {
                try Task.checkCancellation()
                contents[member] = try overrides[member] ?? store.profileContent(member)
            }
            result = try CompositionComposer.compose(composition,profiles:configuration.profiles,contents:contents,settings:configuration.settings,additionalTargets:(profile?.proxyChains ?? []).filter(\.enabled).map(\.groupName))
        } else { result = try overrides[id] ?? store.profileContent(id) }
        try Task.checkCancellation()
        return try ProxyChainComposer.compose(source:result,chains:profile?.proxyChains ?? [],settings:configuration.settings)
    }
}
