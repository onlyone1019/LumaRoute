import Foundation

public struct MihomoAPI {
    public let port: Int
    public let secret: String
    public let session: URLSession
    public init(port: Int, secret: String, session: URLSession = .shared) { self.port = port; self.secret = secret; self.session = session }
    public func url(_ segments: [String], query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "http"; components.host = "127.0.0.1"; components.port = port
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedPath = "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }
    public func request(_ segments: [String], method: String = "GET", query: [URLQueryItem] = [], body: Any? = nil, timeout: TimeInterval = 12) -> URLRequest {
        var request = URLRequest(url: url(segments, query: query), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    public func data(_ segments: [String], method: String = "GET", query: [URLQueryItem] = [], body: Any? = nil, timeout: TimeInterval = 12) async throws -> Data {
        let (data, response) = try await session.data(for: request(segments, method: method, query: query, body: body, timeout: timeout))
        guard let response = response as? HTTPURLResponse else { throw LumaError.message("内核返回了无效响应") }
        guard (200...299).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8).map(Redactor.clean) ?? ""
            throw LumaError.message("内核请求失败（\(response.statusCode)）：\(message)")
        }
        return data
    }
    public func decode<T: Decodable>(_ type: T.Type, _ segments: [String]) async throws -> T { try JSONDecoder().decode(type, from: await data(segments)) }
    public func proxies() async throws -> [String: ProxyNode] {
        try await decode(ProxiesResponse.self, ["proxies"]).proxies.mapValues { value in
            var node = value
            if node.providerName?.isEmpty == true { node.providerName = nil }
            return node
        }
    }
    public func providers() async throws -> [String: Provider] { try await decode(ProvidersResponse.self, ["providers","proxies"]).providers }
    public func connections() async throws -> ConnectionsResponse { try await decode(ConnectionsResponse.self, ["connections"]) }
    public func rules() async throws -> [LiveRule] { try await decode(RulesResponse.self, ["rules"]).rules }
    public func version() async throws -> String {
        let object = try JSONSerialization.jsonObject(with: await data(["version"])) as? [String: Any]
        return object?["version"] as? String ?? "未知"
    }
    public func select(group: String, node: String) async throws { _ = try await data(["proxies",group], method: "PUT", body: ["name":node]) }
    public func clearFixed(group: String) async throws { _ = try await data(["proxies",group], method: "DELETE") }
    public func patch(_ fields: [String: Any]) async throws { _ = try await data(["configs"], method:"PATCH", body: fields) }
    public func reload(yaml: String) async throws {
        _ = try await data(["configs"], method: "PUT", query: [URLQueryItem(name:"force",value:"true")], body: ["payload":yaml], timeout:30)
    }
    public func closeConnection(_ id: String?) async throws {
        _ = try await data(id.map { ["connections",$0] } ?? ["connections"], method:"DELETE")
    }
    public func latency(node: ProxyNode, testURL: String, timeout: Int) async throws -> Int {
        let provider = node.providerName.flatMap { $0.isEmpty ? nil : $0 }
        let path = provider.map { ["providers","proxies",$0,node.name,"healthcheck"] } ?? ["proxies",node.name,"delay"]
        let result = try await data(path, query:[URLQueryItem(name:"url",value:testURL), URLQueryItem(name:"timeout",value:String(timeout))], timeout:TimeInterval(timeout)/1000+3)
        let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        guard let delay = object?["delay"] as? Int, delay > 0 else { throw LumaError.message("节点测试超时或不可用") }
        return delay
    }
    public func stream(_ endpoint: String, query: [URLQueryItem] = [], receive: @escaping (Data) async -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request([endpoint], query:query, timeout:3600))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw LumaError.message("内核状态流连接失败") }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty, let data = line.data(using:.utf8) else { continue }
            await receive(data)
        }
    }
}

