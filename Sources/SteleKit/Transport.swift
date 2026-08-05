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

/// A server answered with a redirect to somewhere other than the origin that was addressed, and
/// the transport declined to follow it.
///
/// Its own type rather than a `TransportError`, because the two are opposite reports: a
/// `TransportError` means nothing was sent and the request can be retried once the host is
/// reachable, while this means the request *was* answered — by the right host — and the answer
/// was an instruction to hand the credential to a different one. The advice is not "check the
/// server is up", it is "do not go there".
public struct RedirectRefused: Error, Sendable, Equatable {
    /// Where the server pointed, as it wrote it. Scrubbed before it reaches a message.
    public let destination: String

    public init(destination: String) {
        self.destination = destination
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

    /// One session for the process, built here rather than accepted as a parameter.
    ///
    /// Both halves of that matter. `URLSession` follows 3xx by itself and copies the request's
    /// headers — `Authorization` among them — onto the redirected request, so a session without
    /// the policy below turns any server that can answer for the configured host into a way to
    /// collect this deployment's credential: it replies `302 Location: http://elsewhere/`, the
    /// token is delivered there, and the caller sees an ordinary success. That is precisely what
    /// `SteleClient` documents cannot happen, and until this delegate existed it was only true
    /// of how URLs were *built*, not of what went out on the wire. A `session:` parameter would
    /// have been a way to pass a session without the policy, which is why there is no longer one.
    ///
    /// Shared because `URLSession` retains its delegate until it is invalidated and a client is
    /// constructed per command; ephemeral because a response authenticated with a bearer token
    /// has no business in an on-disk URL cache.
    private static let shared = SessionBox(
        session: URLSession(
            configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil
        )
    )

    private let box: SessionBox

    public init() {
        self.box = Self.shared
    }

    /// Declines any redirect that leaves the origin the caller addressed.
    ///
    /// Same-origin redirects are still followed: the header travelling with those goes to the
    /// deployment it was filed under, which is the whole invariant. Everything else stops, and
    /// the task completes with the 3xx itself — `send` turns that into a `RedirectRefused`.
    /// Cancelling the task instead would arrive as a generic "cancelled" and read like the
    /// user's own doing.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let origin = task.originalRequest?.url, let destination = request.url,
                  sameOrigin(origin, destination)
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        /// Scheme, host and port, with the default port made explicit so `https://h` and
        /// `https://h:443` are one origin — the same rule `SteleHost` normalises by, applied
        /// here to a `URL` the server chose rather than to a string the user typed.
        private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
            func origin(_ url: URL) -> String? {
                guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
                else { return nil }
                let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
                return "\(scheme)://\(host):\(port)"
            }
            // A URL either side cannot be reduced to an origin is not one to carry a token to.
            guard let lhs = origin(lhs), let rhs = origin(rhs) else { return false }
            return lhs == rhs
        }
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
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(
                        throwing: TransportError(reason: "the reply carried no HTTP status")
                    )
                    return
                }
                // A 3xx can only get this far by having been refused above — the policy follows
                // same-origin redirects, and this client sends no conditional requests for a
                // `304` to answer. Reported as the refusal it is rather than handed to the
                // status table, which would call it "no advice for 302" and lose the one fact
                // worth telling the operator.
                guard !(300..<400).contains(http.statusCode) else {
                    continuation.resume(
                        throwing: RedirectRefused(
                            destination: Self.location(of: http) ?? "an unnamed host"
                        )
                    )
                    return
                }
                continuation.resume(
                    returning: SteleResponse(status: http.statusCode, body: data ?? Data())
                )
            }
            task.resume()
        }
    }

    /// The `Location` header, read out of the response *inside* the completion handler so a
    /// `String` and not an `HTTPURLResponse` crosses the continuation.
    ///
    /// Walks `allHeaderFields` rather than calling `value(forHTTPHeaderField:)`, which is a
    /// newer addition on swift-corelibs-foundation than this has to build against, and matches
    /// the name case-insensitively because a header name is.
    static func location(of response: HTTPURLResponse) -> String? {
        for (name, value) in response.allHeaderFields
        where (name as? String)?.lowercased() == "location" {
            return value as? String
        }
        return nil
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
