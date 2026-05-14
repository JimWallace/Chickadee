import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `URLProtocol` subclass that intercepts every request sent through a
/// `URLSession` configured with it. Tests register a `Handler` closure that
/// produces a `(HTTPURLResponse, Data)` pair or throws to simulate transport
/// failure. All intercepted requests are recorded on `capturedRequests`.
///
/// Usage:
///   MockURLProtocol.reset()
///   MockURLProtocol.enqueue(status: 200, body: someJSON)
///   let session = URLSession.mocked()
///   // ... pass session into the type under test
final class MockURLProtocol: URLProtocol {

    /// Single response, returned in order from a FIFO queue. `error` simulates
    /// a transport failure (e.g. `URLError(.notConnectedToInternet)`); when
    /// non-nil, `status`/`body` are ignored.
    struct StubResponse {
        let status: Int
        let body: Data
        let headers: [String: String]
        let error: Error?

        static func ok(_ body: Data = Data(), headers: [String: String] = [:]) -> StubResponse {
            StubResponse(status: 200, body: body, headers: headers, error: nil)
        }

        static func status(_ code: Int, body: Data = Data(), headers: [String: String] = [:]) -> StubResponse {
            StubResponse(status: code, body: body, headers: headers, error: nil)
        }

        static func failure(_ error: Error) -> StubResponse {
            StubResponse(status: 0, body: Data(), headers: [:], error: error)
        }
    }

    private static let stateQueue = DispatchQueue(label: "MockURLProtocol.state")
    nonisolated(unsafe) private static var _queue: [StubResponse] = []
    nonisolated(unsafe) private static var _captured: [URLRequest] = []
    nonisolated(unsafe) private static var _bodies: [Data] = []

    static func reset() {
        stateQueue.sync {
            _queue.removeAll()
            _captured.removeAll()
            _bodies.removeAll()
        }
    }

    static func enqueue(_ response: StubResponse) {
        stateQueue.sync { _queue.append(response) }
    }

    static var capturedRequests: [URLRequest] {
        stateQueue.sync { _captured }
    }

    /// Bodies captured separately because URLSession strips `httpBody` from
    /// the URLRequest passed to URLProtocol; it surfaces it via
    /// `httpBodyStream` instead.
    static var capturedBodies: [Data] {
        stateQueue.sync { _bodies }
    }

    private static func popResponse() -> StubResponse? {
        stateQueue.sync {
            guard !_queue.isEmpty else { return nil }
            return _queue.removeFirst()
        }
    }

    private static func record(request: URLRequest, body: Data) {
        stateQueue.sync {
            _captured.append(request)
            _bodies.append(body)
        }
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let body = MockURLProtocol.body(from: request)
        MockURLProtocol.record(request: request, body: body)

        guard let stub = MockURLProtocol.popResponse() else {
            let error = NSError(
                domain: "MockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No stub enqueued for \(request.url?.absoluteString ?? "<no url>")"]
            )
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLSession` swaps `httpBody` for `httpBodyStream` before handing the
    /// request to the protocol. Read it back so tests can assert on payload.
    private static func body(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

extension URLSession {
    /// Creates an ephemeral `URLSession` that routes all requests through
    /// `MockURLProtocol`. Each test should call `MockURLProtocol.reset()` in
    /// `setUp` to clear queued responses and captured state.
    static func mocked() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }
}
