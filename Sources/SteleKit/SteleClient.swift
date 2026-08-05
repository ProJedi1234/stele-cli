import Foundation

/// The stele HTTP API, as plain data in and plain data out.
///
/// Every method returns a model or throws; none of them prints, formats, colours or decides an
/// exit code. That is the layering rule the executable depends on — it is what makes `--json`
/// a rendering choice rather than a second code path through the API, and it is what lets the
/// tests drive the whole surface through a fake `SteleTransport` with no network and no server.
///
/// One structural detail worth stating: the authenticated methods address
/// `credential.host` and *not* this client's `host`. A token is therefore only ever sent to the
/// deployment it was filed under, and a mismatched `--host` cannot be turned into a way to
/// forward a credential to a server of someone else's choosing. `host` is used by the calls
/// that carry no credential.
public struct SteleClient: Sendable {
    /// Where the unauthenticated calls go.
    public let host: SteleHost
    public let timeout: TimeInterval

    private let transport: any SteleTransport

    /// - Parameters:
    ///   - transport: defaulted rather than read from anywhere global, so a test substitutes
    ///     one by passing it. The same reason `CredentialStore` takes `home`.
    ///   - timeout: a publish is one small request; a minute of waiting on a wedged connection
    ///     is a minute an agent spends stuck, so this is deliberately shorter than
    ///     `URLSession`'s own 60-second default.
    public init(
        host: SteleHost,
        transport: any SteleTransport = URLSessionTransport(),
        timeout: TimeInterval = 30
    ) {
        self.host = host
        self.transport = transport
        self.timeout = timeout
    }

    /// Convenience for the common case: talk to the deployment this credential belongs to.
    public init(
        credential: Credential,
        transport: any SteleTransport = URLSessionTransport(),
        timeout: TimeInterval = 30
    ) {
        self.init(host: credential.host, transport: transport, timeout: timeout)
    }

    /// Paths this client knows, in one place because they are a contract with another
    /// repository and a typo in one of them is a 404 that reads like a missing page.
    public enum Path {
        public static let pages = "/pages"
        public static let skill = "/skill"
        /// Reports the credential the caller presented. Under `/admin` because that segment is
        /// already reserved server-side, but open to *any* valid credential rather than to the
        /// `admin` scope — `stele auth status` is the first thing an agent runs, and it holds
        /// a publish-only credential.
        public static let whoami = "/admin/whoami"
        public static let clients = "/admin/clients"

        public static func page(slug: String) -> String { "\(pages)/\(slug)" }
        public static func revoke(client name: String) -> String { "\(clients)/\(name)/revoke" }
    }

    /// The type a page body is sent as when the caller expresses no opinion.
    ///
    /// The CLI owning this decision is the point of the tool: the `curl` recipe the skill used
    /// to teach needed an explicit `Content-Type` or a wrapper would helpfully send
    /// `application/json` and earn a `415`. There is nothing for the agent to get wrong here.
    public static let defaultContentType = "text/html"

    // MARK: - Pages

    /// `POST /pages`. Returns the slug the page was published at and its URL.
    ///
    /// `slug` is passed through untouched rather than validated here. The slug rules live in
    /// the server's `Slug` type — the single chokepoint every slug reaches the database
    /// through — and a copy of them in this repository would be a second source of truth that
    /// drifts silently the first time the server relaxes one. A bad slug comes back as a `400`
    /// whose message says which rule it broke.
    public func publish(
        page: Data,
        contentType: String = SteleClient.defaultContentType,
        slug: String? = nil,
        using credential: Credential
    ) async throws -> PageLocation {
        let query = slug.map { [URLQueryItem(name: "slug", value: $0)] } ?? []
        return try await send(
            method: "POST",
            path: Path.pages,
            query: query,
            contentType: contentType,
            body: page,
            credential: credential,
            expectation: .write,
            decoding: PageLocation.self
        )
    }

    /// `PUT /pages/:slug`. Replaces a page that already exists; never creates one.
    public func update(
        slug: String,
        page: Data,
        contentType: String = SteleClient.defaultContentType,
        using credential: Credential
    ) async throws -> PageLocation {
        try await send(
            method: "PUT",
            path: Path.page(slug: slug),
            contentType: contentType,
            body: page,
            credential: credential,
            expectation: .write,
            decoding: PageLocation.self
        )
    }

    /// `GET /skill` — the server's own instructions for publishing to it, as Markdown.
    ///
    /// Unauthenticated, like every other read on this server, and returned as text rather than
    /// printed: the caller decides whether it goes to stdout or into a file. Proxying it keeps
    /// zero copies of the contract in this binary, so the document an agent reads is always the
    /// one the running server generates.
    public func fetchSkill() async throws -> String {
        let response = try await perform(
            SteleRequest(
                method: "GET",
                url: try url(path: Path.skill, on: host),
                credential: nil,
                timeout: timeout
            ),
            host: host,
            expectation: .any
        )
        guard let markdown = String(data: response.body, encoding: .utf8) else {
            throw SteleError.malformedResponse("the skill document was not valid UTF-8")
        }
        return markdown
    }

    // MARK: - The credential itself

    /// `GET /admin/whoami` — who this credential says we are, according to the server.
    ///
    /// What `auth login` verifies with before writing anything to disk, and what `auth status`
    /// reports. Asking the server rather than trusting the file is the whole value: a
    /// credential that was revoked yesterday still sits in the file looking perfectly healthy,
    /// and the answer an agent needs is whether it works *now*.
    ///
    /// A `401` from here is the honest "this credential is no longer good", and its message
    /// still says nothing about which credential was presented.
    public func verifyCredential(_ credential: Credential) async throws -> ClientSummary {
        try await send(
            method: "GET",
            path: Path.whoami,
            credential: credential,
            expectation: .any,
            decoding: ClientSummary.self
        )
    }

    // MARK: - Administration

    /// `POST /admin/clients` — mint a credential.
    ///
    /// The returned `MintedToken` is the only time the plaintext exists on this machine: the
    /// server stores a SHA-256 and cannot reissue it. A caller that drops this value has lost
    /// the credential and has to mint another.
    public func createClient(
        name: String,
        scopes: [Scope] = [.publish],
        expiresIn: TimeInterval? = nil,
        using credential: Credential
    ) async throws -> MintedClient {
        let payload = CreateClientRequest(
            name: name,
            scopes: scopes.map(\.rawValue),
            expiresInSeconds: expiresIn.map { Int($0.rounded()) }
        )
        return try await send(
            method: "POST",
            path: Path.clients,
            contentType: "application/json",
            body: try JSONEncoder().encode(payload),
            credential: credential,
            expectation: .administration,
            decoding: MintedClient.self
        )
    }

    /// `GET /admin/clients` — every credential the server holds, revoked ones included.
    ///
    /// Revoked rows are listed rather than filtered: "was this revoked, and when?" is the
    /// question an operator opens this list to answer.
    public func listClients(using credential: Credential) async throws -> [ClientSummary] {
        try await send(
            method: "GET",
            path: Path.clients,
            credential: credential,
            expectation: .administration,
            decoding: [ClientSummary].self
        )
    }

    /// `POST /admin/clients/:name/revoke` — stop a credential working, keeping its row.
    ///
    /// A `POST` to a sub-resource rather than a `DELETE` on the client, because revocation is
    /// not deletion: the row survives with `revoked_at` set, which is what lets the list
    /// answer "this one was retired in March" instead of forgetting the credential existed.
    public func revokeClient(
        name: String,
        using credential: Credential
    ) async throws -> ClientSummary {
        try await send(
            method: "POST",
            path: Path.revoke(client: name),
            credential: credential,
            expectation: .administration,
            decoding: ClientSummary.self
        )
    }

    // MARK: - Plumbing

    /// The JSON body `createClient` sends. A duration rather than an absolute expiry: the two
    /// clocks involved are the agent's and the server's, and only one of them has to be right
    /// if the client says "90 days from now" and the server does the arithmetic.
    private struct CreateClientRequest: Encodable {
        let name: String
        let scopes: [String]
        let expiresInSeconds: Int?
    }

    private func send<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        contentType: String? = nil,
        body: Data? = nil,
        credential: Credential,
        expectation: SteleError.Expectation,
        decoding: T.Type
    ) async throws -> T {
        // `credential.host`, deliberately — see the type's documentation.
        let target = credential.host
        let response = try await perform(
            SteleRequest(
                method: method,
                url: try url(path: path, query: query, on: target),
                contentType: contentType,
                body: body,
                credential: credential,
                timeout: timeout
            ),
            host: target,
            expectation: expectation
        )
        do {
            return try JSONDecoder.stele.decode(T.self, from: response.body)
        } catch {
            // The decoding error itself, not the body: a body that failed to decode is a body
            // this client did not understand, and echoing an unknown server's bytes into an
            // error message is how something unexpected ends up in a transcript.
            throw SteleError.malformedResponse("\(error)")
        }
    }

    /// Sends a request and turns anything other than a 2xx into a `SteleError`.
    private func perform(
        _ request: SteleRequest,
        host: SteleHost,
        expectation: SteleError.Expectation
    ) async throws -> SteleResponse {
        let response: SteleResponse
        do {
            response = try await transport.send(request)
        } catch let error as TransportError {
            throw SteleError.transportFailure(host: host, reason: error.reason)
        } catch {
            throw SteleError.transportFailure(
                host: host, reason: URLSessionTransport.reason(for: error)
            )
        }

        if let error = SteleError.from(
            status: response.status,
            detail: Self.detail(from: response.body),
            expectation: expectation
        ) {
            throw error
        }
        return response
    }

    private func url(
        path: String,
        query: [URLQueryItem] = [],
        on host: SteleHost
    ) throws -> URL {
        guard let url = host.url(path: path, query: query) else {
            throw SteleError.transportFailure(
                host: host, reason: "could not build a URL for \(path)"
            )
        }
        return url
    }

    /// The server's own explanation of a failure, or nil when it did not offer one this client
    /// should repeat.
    ///
    /// Hummingbird renders `HTTPError` as `{"error": {"message": "…"}}`, which is the shape
    /// worth reading. Anything else is treated as absent rather than passed along: an HTML
    /// error page from a proxy in front of the server would otherwise arrive as a screenful of
    /// markup in the middle of a one-line message.
    ///
    /// Whatever survives goes through `Redaction.scrub` first. The server does not put tokens
    /// in error messages — but "no token reaches an error description" is this library's
    /// promise to keep, and it should not rest on another repository's behaviour.
    static func detail(from body: Data) -> String? {
        guard !body.isEmpty else { return nil }

        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return Redaction.scrub(message).trimmed(to: 500)
        }

        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("{") else { return nil }
        return Redaction.scrub(trimmed).trimmed(to: 500)
    }
}

extension String {
    /// Collapses to a single line and caps the length, so a server message can be dropped into
    /// a sentence without reflowing the terminal.
    func trimmed(to limit: Int) -> String {
        let single = split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        guard single.count > limit else { return single }
        return single.prefix(limit) + "…"
    }
}
