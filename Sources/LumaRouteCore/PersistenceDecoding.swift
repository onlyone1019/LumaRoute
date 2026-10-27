import Foundation

// Defaults follow model initialization. decodeIfPresent tolerates absent/null
// options while preserving errors for malformed values and required identities.
extension NetworkSettings {
    enum CodingKeys: String, CodingKey {
        case mixedPort, controllerPort, mode, tun, stack, autoRoute, autoDetectInterface, excludeLAN, allowLAN, lanUsername, lanPassword, mtu
        case dnsHijack, fakeIP, ipv6, systemProxy, bypass, autoLaunch, connectOnLaunch
        case testURL, testTimeout, testConcurrency, appearance, updateIntervalHours
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy:CodingKeys.self)
        mixedPort = try values.decodeIfPresent(Int.self,forKey:.mixedPort) ?? mixedPort
        controllerPort = try values.decodeIfPresent(Int.self,forKey:.controllerPort) ?? controllerPort
        mode = try values.decodeIfPresent(RouteMode.self,forKey:.mode) ?? mode
        tun = try values.decodeIfPresent(Bool.self,forKey:.tun) ?? tun
        stack = try values.decodeIfPresent(String.self,forKey:.stack) ?? stack
        autoRoute = try values.decodeIfPresent(Bool.self,forKey:.autoRoute) ?? autoRoute
        autoDetectInterface = try values.decodeIfPresent(Bool.self,forKey:.autoDetectInterface) ?? autoDetectInterface
        excludeLAN = try values.decodeIfPresent(Bool.self,forKey:.excludeLAN) ?? excludeLAN
        allowLAN = try values.decodeIfPresent(Bool.self,forKey:.allowLAN) ?? allowLAN
        lanUsername = try values.decodeIfPresent(String.self,forKey:.lanUsername) ?? lanUsername
        lanPassword = try values.decodeIfPresent(String.self,forKey:.lanPassword) ?? lanPassword
        mtu = try values.decodeIfPresent(Int.self,forKey:.mtu) ?? mtu
        dnsHijack = try values.decodeIfPresent(Bool.self,forKey:.dnsHijack) ?? dnsHijack
        fakeIP = try values.decodeIfPresent(Bool.self,forKey:.fakeIP) ?? fakeIP
        ipv6 = try values.decodeIfPresent(Bool.self,forKey:.ipv6) ?? ipv6
        systemProxy = try values.decodeIfPresent(Bool.self,forKey:.systemProxy) ?? systemProxy
        bypass = try values.decodeIfPresent([String].self,forKey:.bypass) ?? bypass
        autoLaunch = try values.decodeIfPresent(Bool.self,forKey:.autoLaunch) ?? autoLaunch
        connectOnLaunch = try values.decodeIfPresent(Bool.self,forKey:.connectOnLaunch) ?? connectOnLaunch
        testURL = try values.decodeIfPresent(String.self,forKey:.testURL) ?? testURL
        testTimeout = try values.decodeIfPresent(Int.self,forKey:.testTimeout) ?? testTimeout
        testConcurrency = try values.decodeIfPresent(Int.self,forKey:.testConcurrency) ?? testConcurrency
        appearance = try values.decodeIfPresent(String.self,forKey:.appearance) ?? appearance
        updateIntervalHours = try values.decodeIfPresent(Double.self,forKey:.updateIntervalHours) ?? updateIntervalHours
    }
}

extension SubscriptionUsage {
    enum CodingKeys: String, CodingKey { case upload, download, total, expire }
    public init(from decoder: Decoder) throws {
        self.init(header:"")
        let values = try decoder.container(keyedBy:CodingKeys.self)
        upload = try values.decodeIfPresent(Int64.self,forKey:.upload) ?? upload
        download = try values.decodeIfPresent(Int64.self,forKey:.download) ?? download
        total = try values.decodeIfPresent(Int64.self,forKey:.total)
        expire = try values.decodeIfPresent(Date.self,forKey:.expire)
    }
}

extension Profile {
    enum CodingKeys: String, CodingKey {
        case id, name, isRemote, displaySource, created, lastUpdated, lastAttempt, lastError, usage
        case updateHours, nodeCount, userAgent, downloadRoute, composition, proxyChains, lastChange
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        self.init(name:try values.decode(String.self,forKey:.name),isRemote:try values.decode(Bool.self,forKey:.isRemote))
        id = try values.decode(UUID.self,forKey:.id)
        displaySource = try values.decodeIfPresent(String.self,forKey:.displaySource) ?? displaySource
        // Unknown creation times must not change on each load or delay auto-updates.
        created = try values.decodeIfPresent(Date.self,forKey:.created) ?? Date(timeIntervalSince1970:0)
        lastUpdated = try values.decodeIfPresent(Date.self,forKey:.lastUpdated)
        lastAttempt = try values.decodeIfPresent(Date.self,forKey:.lastAttempt)
        lastError = try values.decodeIfPresent(String.self,forKey:.lastError)
        usage = try values.decodeIfPresent(SubscriptionUsage.self,forKey:.usage)
        updateHours = try values.decodeIfPresent(Double.self,forKey:.updateHours) ?? updateHours
        nodeCount = try values.decodeIfPresent(Int.self,forKey:.nodeCount) ?? nodeCount
        userAgent = try values.decodeIfPresent(String.self,forKey:.userAgent)
        downloadRoute = try values.decodeIfPresent(SubscriptionDownloadRoute.self,forKey:.downloadRoute) ?? .direct
        composition = try values.decodeIfPresent(SubscriptionComposition.self,forKey:.composition)
        proxyChains = try values.decodeIfPresent([ProxyChain].self,forKey:.proxyChains)
        lastChange = try values.decodeIfPresent(SubscriptionChange.self,forKey:.lastChange)
    }
}

extension CustomRule {
    enum CodingKeys: String, CodingKey { case id, enabled, type, payload, target }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        self.init(payload:try values.decode(String.self,forKey:.payload),target:try values.decode(String.self,forKey:.target))
        id = try values.decode(UUID.self,forKey:.id)
        enabled = try values.decodeIfPresent(Bool.self,forKey:.enabled) ?? enabled
        type = try values.decodeIfPresent(String.self,forKey:.type) ?? type
    }
}

extension AppDatabase {
    enum CodingKeys: String, CodingKey { case profiles, activeProfileID, settings, customRules, savedChoices, groupStrategies, ruleSubscriptions }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy:CodingKeys.self)
        profiles = try values.decodeIfPresent([Profile].self,forKey:.profiles) ?? profiles
        activeProfileID = try values.decodeIfPresent(UUID.self,forKey:.activeProfileID)
        settings = try values.decodeIfPresent(NetworkSettings.self,forKey:.settings) ?? settings
        customRules = try values.decodeIfPresent([CustomRule].self,forKey:.customRules) ?? customRules
        savedChoices = try values.decodeIfPresent([String:String].self,forKey:.savedChoices) ?? savedChoices
        groupStrategies = try values.decodeIfPresent([GroupStrategy].self,forKey:.groupStrategies)
        ruleSubscriptions = try values.decodeIfPresent([RuleSubscription].self,forKey:.ruleSubscriptions)
    }
}

extension GroupStrategy {
    enum CodingKeys: String, CodingKey { case profileID, group, mode, candidateFilter, interval, tolerance }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        self.init(profileID:try values.decode(UUID.self,forKey:.profileID),group:try values.decode(String.self,forKey:.group))
        mode = try values.decodeIfPresent(GroupStrategyMode.self,forKey:.mode) ?? mode
        candidateFilter = try values.decodeIfPresent(String.self,forKey:.candidateFilter) ?? candidateFilter
        interval = try values.decodeIfPresent(Int.self,forKey:.interval) ?? interval
        tolerance = try values.decodeIfPresent(Int.self,forKey:.tolerance) ?? tolerance
    }
}

extension SubscriptionDomainRoute {
    enum CodingKeys: String, CodingKey { case id, enabled, type, domain, profileID, target }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        self.init(profileID:try values.decodeIfPresent(UUID.self,forKey:.profileID))
        id = try values.decode(UUID.self,forKey:.id)
        enabled = try values.decodeIfPresent(Bool.self,forKey:.enabled) ?? enabled
        type = try values.decodeIfPresent(String.self,forKey:.type) ?? type
        domain = try values.decodeIfPresent(String.self,forKey:.domain) ?? domain
        target = try values.decodeIfPresent(String.self,forKey:.target)
    }
}

extension SubscriptionComposition {
    enum CodingKeys: String, CodingKey { case profileIDs, baseProfileID, fallbackProfileID, domainRoutes, customRules }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy:CodingKeys.self)
        profileIDs = try values.decodeIfPresent([UUID].self,forKey:.profileIDs) ?? profileIDs
        baseProfileID = try values.decodeIfPresent(UUID.self,forKey:.baseProfileID)
        fallbackProfileID = try values.decodeIfPresent(UUID.self,forKey:.fallbackProfileID)
        domainRoutes = try values.decodeIfPresent([SubscriptionDomainRoute].self,forKey:.domainRoutes) ?? domainRoutes
        customRules = try values.decodeIfPresent([CustomRule].self,forKey:.customRules) ?? customRules
    }
}

extension RuleSubscription {
    enum CodingKeys: String, CodingKey {
        case id, profileID, catalogID, target, enabled, autoUpdate, intervalHours, priority
        case revision, ruleCount, lastUpdated, lastAttempt, lastError
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        self.init(profileID:try values.decode(UUID.self,forKey:.profileID),catalogID:try values.decode(String.self,forKey:.catalogID),target:try values.decode(String.self,forKey:.target))
        id = try values.decode(UUID.self,forKey:.id)
        enabled = try values.decodeIfPresent(Bool.self,forKey:.enabled) ?? enabled
        autoUpdate = try values.decodeIfPresent(Bool.self,forKey:.autoUpdate) ?? autoUpdate
        intervalHours = try values.decodeIfPresent(Int.self,forKey:.intervalHours) ?? intervalHours
        priority = try values.decodeIfPresent(RuleSubscriptionPriority.self,forKey:.priority) ?? priority
        revision = try values.decodeIfPresent(UUID.self,forKey:.revision)
        ruleCount = try values.decodeIfPresent(Int.self,forKey:.ruleCount) ?? ruleCount
        lastUpdated = try values.decodeIfPresent(Date.self,forKey:.lastUpdated)
        lastAttempt = try values.decodeIfPresent(Date.self,forKey:.lastAttempt)
        lastError = try values.decodeIfPresent(String.self,forKey:.lastError)
    }
}

extension SubscriptionChange {
    enum CodingKeys: String, CodingKey {
        case date, addedNodes, removedNodes, changedNodes, addedGroups, removedGroups, changedProviders
        case selectedNodesRemoved, containsProviders, uriNamesOnly
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        self.init(date:try values.decodeIfPresent(Date.self,forKey:.date) ?? Date(timeIntervalSince1970:0),
                  addedNodes:try values.decodeIfPresent([String].self,forKey:.addedNodes) ?? [],
                  removedNodes:try values.decodeIfPresent([String].self,forKey:.removedNodes) ?? [],
                  changedNodes:try values.decodeIfPresent([String].self,forKey:.changedNodes) ?? [],
                  addedGroups:try values.decodeIfPresent([String].self,forKey:.addedGroups) ?? [],
                  removedGroups:try values.decodeIfPresent([String].self,forKey:.removedGroups) ?? [],
                  changedProviders:try values.decodeIfPresent([String].self,forKey:.changedProviders) ?? [],
                  selectedNodesRemoved:try values.decodeIfPresent([String].self,forKey:.selectedNodesRemoved) ?? [],
                  containsProviders:try values.decodeIfPresent(Bool.self,forKey:.containsProviders) ?? false,
                  uriNamesOnly:try values.decodeIfPresent(Bool.self,forKey:.uriNamesOnly) ?? false)
    }
}
