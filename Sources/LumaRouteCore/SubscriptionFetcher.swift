import Foundation

public struct SubscriptionDownload: Sendable {
    public var content: String
    public var usage: SubscriptionUsage?
    public var interval: Double?
}
public enum SubscriptionFetcher {
    // Providers negotiate Clash Meta YAML from this recognized capability prefix.
    // Keep the direct and caller-supplied transports consistent.
    public static var defaultUserAgent: String { VersionInfo.current.subscriptionUserAgent }
    public static func normalizedUserAgent(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= 512, value.utf8.allSatisfy({ (32...126).contains($0) }) else { throw SubscriptionError.invalidUserAgent }
        let trimmed = value.trimmingCharacters(in:.whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
    public static func displayURL(_ url: URL) -> String { "\(url.scheme ?? "https")://\(url.host ?? "未知来源")/••••" }
    public static func fetch(_ source: String, userAgent: String? = nil, session: URLSession? = nil,versionInfo: VersionInfo = .current) async throws -> SubscriptionDownload {
        guard let url = URL(string:source), ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw SubscriptionError.invalidAddress }
        let agent = try normalizedUserAgent(userAgent) ?? versionInfo.subscriptionUserAgent
        var request = URLRequest(url:url,timeoutInterval:25)
        request.setValue(agent,forHTTPHeaderField:"User-Agent")
        let data: Data
        let response: URLResponse
        // Subscription retrieval defaults to direct transport, like Clash Verge Rev.
        // The caller can explicitly supply a configured session for proxy downloads.
        do {
            if let session { (data,response) = try await session.data(for:request) }
            else { (data,response) = try await DirectSubscriptionDownload.fetch(url,userAgent:agent) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as SubscriptionError { throw error }
        catch { throw SubscriptionError.transport(error) }
        guard let http = response as? HTTPURLResponse else { throw SubscriptionError.download("服务器没有返回有效的 HTTP 响应。") }
        guard (200...299).contains(http.statusCode) else { throw SubscriptionError.httpStatus(http.statusCode) }
        guard data.count <= 8*1024*1024 else { throw SubscriptionError.tooLarge }
        guard let decoded = String(data:data,encoding:.utf8) else { throw SubscriptionError.invalidEncoding }
        let content = decoded.hasPrefix("\u{feff}") ? String(decoded.dropFirst()) : decoded
        let leading = content.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !leading.isEmpty else { throw SubscriptionError.emptyResponse }
        if ["<!doctype html","<html","<head","<body"].contains(where:leading.lowercased().hasPrefix) { throw SubscriptionError.htmlResponse }
        do { _ = try ConfigComposer.parse(content) }
        catch { throw SubscriptionError.invalidFormat(error.localizedDescription) }
        return SubscriptionDownload(content:content,usage:http.value(forHTTPHeaderField:"subscription-userinfo").map { SubscriptionUsage(header:$0) }, interval:http.value(forHTTPHeaderField:"profile-update-interval").flatMap(Double.init))
    }
}

