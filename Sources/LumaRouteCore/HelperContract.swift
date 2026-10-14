import Foundation

public enum HelperConstants {
    public static let appID = "app.lumaroute.desktop"
    public static let serviceID = "app.lumaroute.helper"
    public static let plistName = "app.lumaroute.helper.plist"
}
@objc public protocol LumaRouteHelperProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}
public struct HelperRequest: Codable {
    public var action: String
    public var source: String?
    public var rules: [CustomRule]?
    public var settings: NetworkSettings?
    public var secret: String?
    public var strategies: [GroupStrategy]?
    public var coreVersion: String?
    public var selections:[GroupSelection]?
    public var ruleSubscriptions: [RuleSubscriptionSnapshot]?
    public init(action: String, source: String? = nil, rules: [CustomRule]? = nil, settings: NetworkSettings? = nil, secret: String? = nil, strategies: [GroupStrategy]? = nil,coreVersion: String? = nil,selections:[GroupSelection]? = nil,ruleSubscriptions:[RuleSubscriptionSnapshot]? = nil) {
        self.action = action; self.source = source; self.rules = rules; self.settings = settings; self.secret = secret; self.strategies = strategies
        self.coreVersion = coreVersion
        self.selections = selections
        self.ruleSubscriptions = ruleSubscriptions
    }
}
public struct HelperResponse: Codable {
    public var success: Bool
    public var message: String
    public var running: Bool
    public var canRollbackGeo: Bool?
    public var serviceUID:UInt32?
    public var protocolVersion:Int?
    public init(success: Bool, message: String = "", running: Bool = false,canRollbackGeo: Bool? = nil,serviceUID:UInt32? = nil,protocolVersion:Int? = nil) {
        self.success = success; self.message = message; self.running = running
        self.canRollbackGeo = canRollbackGeo
        self.serviceUID = serviceUID; self.protocolVersion = protocolVersion
    }
}

