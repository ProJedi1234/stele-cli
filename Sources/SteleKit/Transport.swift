import Foundation

// URLSession lives in a separate module on Linux. Without this the file compiles on macOS and
// fails on the machine the agents actually run on.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One request, described rather than performed.
///
/// The credential is carried as a `Credential`, not as an assembled `Authorization` header
/// string, and the property is `internal`. So a transport written outside SteleKit — a fake in
/// someone's tests, a logging decorator — can read the method, the URL and the body, and has
/// no expression available to it that yields the token. Flattening the header at construction
/// time would have put the secret in a `[String: String]` that anything downstream could print.
public struct SteleRequest: Sendable {
    public let method: String
    public let url: URL
    public let contentType: String?
    public let body: Data?
    public let timeout: TimeInterval
    /// Sent on every request, not only writes: the server version-gates on it, and a client
    /// that identified itself inconsistently would make that gate depend on the route.
    public let userAgent: String

    let credential: Credential?

    init(
        method: String,
        url: URL,
        contentType: String? = nil,
        body: Data? = nil,
        credential: Credential?,
        timeout: TimeInterval,
        userAgent: String = SteleVersion.userAgent
    ) {
        self.method = method
        self.url = url
        self.contentType = contentType
        self.body = body
        self.credential = credential
        self.timeout = timeout
        self.userAgent = userAgent
    }

    /// The headers to put on the wire. `internal`, because this is the one dictionary in the
    /// library that contains a token.
    func headerFields() -> [String: String] {
        var fields = ["User-Agent": userAgent, "Accept": "application/json, text/*"]
        if let contentType { fields["Content-Type"] = contentType }
        if let credential { fields["Authorization"] = credential.token.authorizationHeaderValue }
        return fields
    }
}

/// A server's answer, reduced to the two things this client reads.
///
/// Not `HTTPURLResponse`: that type is not `Sendable` on Linux, so passing it across the
/// continuation that wraps `URLSession` would not compile under Swift 6's concurrency
/// checking. Reducing it to a status and a body at the boundary sidesteps the question and
/// also makes a fake transport trivial to write.
public struct SteleResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// A request that never reached a server. Distinct from every `SteleError` case that carries a
/// status, because "no answer" and "an answer you did not like" have different next steps.
public struct TransportError: Error, Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// How requests get sent. The seam that lets `SteleClient` be tested without a network, in the
/// same spirit as the server's `PageStoring`.
public protocol SteleTransport: Sendable {
    func send(_ request: SteleRequest) async throws -> SteleResponse
}

/// The real transport.
///
/// `URLSession` rather than AsyncHTTPClient: this makes a handful of requests per invocation
/// and the NIO dependency tree would dominate both the build time and the binary for no
/// behaviour the CLI needs.
public struct URLSessionTransport: SteleTransport {
    /// `URLSession` is declared `Sendable` in the Apple SDKs and carries no such annotation in
    /// swift-corelibs-foundation, so referring to it directly from a `Sendable` type fails to
    /// compile on Linux only — the platform this ships on. The box states the assumption in one
    /// place instead of scattering `@preconcurrency` around: a session is thread-safe by
    /// documented contract on both platforms.
    private struct SessionBox: @unchecked Sendable {
        let session: URLSession
    }

    private let box: SessionBox

    public init(session: URLSession = .shared) {
        self.box = SessionBox(session: session)
    }

    public func send(_ request: SteleRequest) async throws -> SteleResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = request.body
        for (name, value) in request.headerFields() {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        // The completion-handler API rather than `URLSession.data(for:)`. The async overloads
        // arrived late and unevenly on swift-corelibs-foundation, and this wrapper works
        // identically on every toolchain either platform ships. Status and bytes are extracted
        // *inside* the callback so nothing non-`Sendable` crosses the continuation.
        return try await withCheckedThrowingContinuation { continuation in
            let task = box.session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: TransportError(reason: Self.reason(for: error)))
                    return
                }
                guard let status = (response as? HTTPURLResponse)?.statusCode else {
                    continuation.resume(
                        throwing: TransportError(reason: "the reply carried no HTTP status")
                    )
                    return
                }
                continuation.resume(returning: SteleResponse(status: status, body: data ?? Data()))
            }
            task.resume()
        }
    }

    /// A failure reason a human can act on.
    ///
    /// `localizedDescription` alone is often "The operation could not be completed" on Linux,
    /// which names nothing. The `URLError` code is what distinguishes "wrong host" from "server
    /// down" from "TLS refused", so it goes in the message.
    static func reason(for error: any Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        let description = urlError.localizedDescription
        return description.isEmpty
            ? "URLError \(urlError.errorCode)"
            : "\(description) (URLError \(urlError.errorCode))"
    }
}
