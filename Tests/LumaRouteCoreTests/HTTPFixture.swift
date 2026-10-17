import Foundation
import os

/// Each session owns its response handler; URLProtocol callbacks may use any thread.
final class HTTPFixture: Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int,Data)
    private static let handlers = OSAllocatedUnfairLock(initialState:[String:Handler]())
    private static let header = "X-LumaRoute-Test-Fixture"
    private let identifier = UUID().uuidString
    let session: URLSession

    init(handler: @escaping Handler) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header:identifier]
        session = URLSession(configuration:configuration)
        setHandler(handler)
    }

    func setHandler(_ handler: @escaping Handler) {
        Self.handlers.withLock { $0[identifier] = handler }
    }

    func close() {
        session.invalidateAndCancel()
        _ = Self.handlers.withLock { $0.removeValue(forKey:identifier) }
    }

    fileprivate static func response(for request: URLRequest) throws -> (Int,Data) {
        guard let identifier = request.value(forHTTPHeaderField:header),
              let handler = handlers.withLock({ $0[identifier] }) else {
            throw URLError(.badServerResponse)
        }
        // Invoke outside the lock, allowing independent sessions to make progress.
        return try handler(request)
    }
}

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status,data) = try HTTPFixture.response(for:request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
