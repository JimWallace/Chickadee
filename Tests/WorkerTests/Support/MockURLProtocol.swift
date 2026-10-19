import ChickadeeTestSupport
import Foundation
import Synchronization

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
        let error: any Error?

        static func ok(_ body: Data = Data(), headers: [String: String] = [:]) -> StubResponse {
            StubResponse(status: 200, body: body, headers: headers, error: nil)
        }

        static func status(_ code: Int, body: Data = Data(), headers: [String: String] = [:]) -> StubResponse {
            StubResponse(status: code, body: body, headers: headers, error: nil)
        }

        static func failure(_ error: any Error) -> StubResponse {
            StubResponse(status: 0, body: Data(), headers: [:], error: error)
        }
    }

    private struct State {
        var queue: [StubResponse] = []
        var captured: [URLRequest] = []
        var bodies: [Data] = []
    }

    private static let state = Mutex(State())

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func enqueue(_ response: StubResponse) {
        state.withLock { $0.queue.append(response) }
    }

    static var capturedRequests: [URLRequest] {
        state.withLock { $0.captured }
    }

    /// Bodies captured separately because URLSession strips `httpBody` from
    /// the URLRequest passed to URLProtocol; it surfaces it via
    /// `httpBodyStream` instead.
    static var capturedBodies: [Data] {
        state.withLock { $0.bodies }
    }

    private static func popResponse() -> StubResponse? {
        state.withLock { state in
            guard !state.queue.isEmpty else { return nil }
            return state.queue.removeFirst()
        }
    }

    private static func record(request: URLRequest, body: Data) {
        state.withLock { state in
            state.captured.append(request)
            state.bodies.append(body)
        }
    }

    // MARK: URLProtocol

    // Must remain `class func` (not `static`) to override URLProtocol's
    // base-class `class func` declarations.  `static` would not satisfy
    // the override contract.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let body = MockURLProtocol.body(from: request)
        MockURLProtocol.record(request: request, body: body)

        guard let stub = MockURLProtocol.popResponse() else {
            let error = NSError(
                domain: "MockURLProtocol",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "No stub enqueued for \(request.url?.absoluteString ?? "<no url>")"
                ]
            )
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard
            let response = HTTPURLResponse(
                url: request.url ?? testURL("https://example.invalid"),
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )
        else { return }
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
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            // `InputStream` reads only into a pointer; no safe API exists.
            let read = unsafe stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
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
        // Generous on purpose: every stub replies immediately (even the
        // "no stub enqueued" path fails fast), so this timeout never gates a
        // passing run — it can only fire when a loaded CI machine starves the
        // delivery, which would surface as a spurious URLError instead of the
        // stubbed response.
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }
}
