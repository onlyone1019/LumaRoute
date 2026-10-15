import Foundation

/// Reads and parses on this actor, never on the UI actor. Read the current
/// SQLite contents even for a hit so restore/import cannot reuse stale targets.
public actor CompositionPolicyCache {
    private struct Input: Equatable {
        let composition: SubscriptionComposition
        let profiles: [Profile]
        let settings: NetworkSettings
        let contents: [UUID:String]
    }
    private var cached: (input:Input,targets:[String])?
    public init() {}
    public func targets(_ composition: SubscriptionComposition,profiles: [Profile],settings: NetworkSettings,store: LocalStore) throws -> [String] {
        try Task.checkCancellation()
        var candidate = composition
        candidate.domainRoutes = []; candidate.customRules = []
        let members = profiles.filter { candidate.profileIDs.contains($0.id) }
        var contents: [UUID:String] = [:]
        for id in candidate.profileIDs { contents[id] = try store.profileContent(id) }
        let input = Input(composition:candidate,profiles:members,settings:settings,contents:contents)
        if let cached,cached.input == input { return cached.targets }
        let source = try CompositionComposer.compose(candidate,profiles:members,contents:contents,settings:settings)
        let targets = (try ConfigComposer.parse(source)["proxy-groups"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }.filter { !$0.hasPrefix("订阅 · ") }
        try Task.checkCancellation()
        cached = (input,targets)
        return targets
    }
}
