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
        /// Reports the credential the caller presented.
        ///
        /// It sits under `/admin` because that first segment is already reserved server-side, and
        /// that placement is the trap worth naming: everything else under `/admin` is behind the
        /// `admin` scope, so whoami has to be *deliberately excluded* from that group on the
        /// server. It is open to any valid credential in spite of its path, not because of it.
        /// `stele auth status` is the first thing an agent runs and it holds a publish-only
        /// credential — the day this route falls back into the admin group, `auth login` starts
        /// failing with a `403` for every agent.
        public static let whoami = "/admin/whoami"
        public static let clients = "/admin/clients"

        /// Starts a GitHub device sign-in. Unauthenticated, like the route below it: the caller
        /// is here precisely because it holds no credential yet.
        public static let authDevice = "/auth/github/device"
        /// Redeems the device code the route above issued. The same path the server used to
        /// take a raw GitHub access token on — that body is gone, and this client never sends
        /// one: a token pasted at a prompt is a token this machine has held.
        public static let authExchange = "/auth/github/exchange"

        /// Where an attachment's bytes are served, with nothing rendered around them.
        ///
        /// The one path here that this client never sends a request to. It is a URL this tool
        /// *prints* — the value that goes in an `<img src>` — and it lives with the others
        /// because it is the same kind of fact: a segment agreed with another repository, whose
        /// misspelling is a 404 in somebody's page rather than in a response we would see.
        public static let staticFiles = "/static"

        public static func page(slug: String) -> String { "\(pages)/\(segment(slug))" }

        /// One attachment's bytes, addressed by slug.
        public static func bytes(slug: String) -> String { "\(staticFiles)/\(segment(slug))" }
        /// One credential, addressed by name — the handle every admin route uses. `GET` is not
        /// offered; `DELETE` here is what revokes.
        public static func client(named name: String) -> String { "\(clients)/\(segment(name))" }

        /// Percent-encodes one path segment, so that a name the caller typed stays one segment.
        ///
        /// Interpolating it raw is route confusion waiting to happen: `/` and `.` are ordinary
        /// path characters, and RFC 3986 resolves dot segments before the request goes out, so
        /// `stele update ../admin/clients page.html` asks for `PUT /admin/clients` and
        /// `stele admin clients revoke ../../pages/x` asks for `DELETE /pages/x`. The credential
        /// still only travels to its own host, so nothing leaks — but the resource acted on is
        /// not the one named, which is its own kind of bad afternoon.
        ///
        /// This is encoding, not validation: which slugs are legal remains the server's `Slug`
        /// type's business, and an illegal one still comes back as a `400` naming the rule it
        /// broke. A slug that needed encoding was never going to be a real slug anyway.
        static func segment(_ raw: String) -> String {
            let encoded = raw.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? ""
            // The other half of dot-segment removal, which needs no `/` to bite: `/pages/..`
            // resolves to `/` on its own, and `/pages/.` to `/pages`.
            guard !encoded.isEmpty, encoded.allSatisfy({ $0 == "." }) else { return encoded }
            return String(repeating: "%2E", count: encoded.count)
        }

        /// Everything `URLComponents` would leave alone in a path, less `/` — a separator is
        /// exactly what a segment must not be able to introduce.
        private static let segmentAllowed: CharacterSet = {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove("/")
            return allowed
        }()
    }

    /// Query parameters this client sends, named once for `Path`'s reason and a sharper version
    /// of its failure. A misspelled path is a `404` and says so; a misspelled query parameter is
    /// *silence* — the server looks the name up, does not find it, and does whatever it would
    /// have done had the caller passed nothing. `?slgu=` on a publish is a generated slug instead
    /// of the one asked for, and on an amendment it is a page retimed but never renamed. Both
    /// answer `200`.
    ///
    /// `?ttl=` is spelled by `PageTTL.queryParameter`, which sits with the type that owns the
    /// value and its `never` keyword.
    public enum Query {
        /// The name a page is asked to have — the one on `POST /pages`, and the *new* one on
        /// `PATCH /pages/:slug`. One word on the wire in both places, and a literal at each call
        /// site would be two strings that have to agree with each other and with the server.
        public static let slug = "slug"

        /// What a browser should save an attachment as.
        ///
        /// Attachments only, and the server says so: `?filename=` on a text page is a `400`
        /// rather than a silent no-op, which makes this the one parameter in here whose
        /// misspelling is *louder* than its absence — a typo lands in the general-purpose
        /// silence this enum exists to prevent, but sending it where it does not belong is
        /// caught. The failure to actually avoid is the ordinary one: `?flename=` on an
        /// attachment is a download named after its slug, and a `201` either way.
        public static let filename = "filename"
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
    ///
    /// `ttl` is nil for "no opinion", which is not the same as `.never`: an absent parameter
    /// takes the server's own default lifetime, and only `.never` asks for a page that is kept
    /// until it is deleted. The returned `PageLocation` carries the deadline the server settled
    /// on either way, which is the only place the answer exists.
    ///
    /// An attachment is published through this same method, and that is not an omission: on the
    /// server an attachment is a page whose body is bytes, stored by the same route under the
    /// same namespace, and a second method here would invent a distinction the wire does not
    /// have. What decides which one you get is `contentType` — a type on the server's
    /// attachment allowlist stores bytes, anything else is validated as text — and `filename`,
    /// which only an attachment may carry. A text page sent with one earns a `400` naming the
    /// parameter, rather than having it quietly dropped.
    ///
    /// The returned `PageLocation.url` is the *viewer* in both cases. For an attachment that is
    /// a page about the file rather than the file, so a caller embedding the result in an
    /// `<img src>` wants `bytesURL(for:)` instead — see the note there about which URL is which.
    public func publish(
        page: Data,
        contentType: String = SteleClient.defaultContentType,
        slug: String? = nil,
        ttl: PageTTL? = nil,
        filename: String? = nil,
        using credential: Credential
    ) async throws -> PageLocation {
        var query = slug.map { [URLQueryItem(name: Query.slug, value: $0)] } ?? []
        if let ttl {
            query.append(URLQueryItem(name: PageTTL.queryParameter, value: ttl.queryValue))
        }
        if let filename {
            query.append(URLQueryItem(name: Query.filename, value: filename))
        }
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

    /// Where an attachment's bytes are, given what publishing it answered.
    ///
    /// Every attachment has two URLs and they are not interchangeable. `location.url` is the
    /// *viewer* — an HTML page about the file, with its name, size and deadline, which is what
    /// you send a person. This is the file itself, which is what goes in an `<img src>`, a
    /// `<video src>` or a download link. Getting them the wrong way round fails silently: an
    /// `<img>` pointed at the viewer renders nothing, and both URLs answer `200`.
    ///
    /// Derived from the response rather than composed from `credential.host`, which is the same
    /// rule `amend` states about never rebuilding an address from the arguments, for a sharper
    /// reason here. The server builds its URLs from its own configured base, and the address
    /// this client happens to reach it on need not be that base — a deployment behind a proxy,
    /// or reached over a tailnet name, answers with the public one. Composing from the host we
    /// dialled would hand back a URL that works from this machine and from nowhere else, pasted
    /// into a page that outlives the machine. So scheme, host and port come from the server's
    /// own answer, and only the path is ours.
    ///
    /// Nil when the server's `url` is not an absolute URL, which is a server answering strangely
    /// rather than anything a caller did — `SteleError.malformedResponse` is the shape that
    /// fits. A scheme and a host are required rather than assumed, and that guard is the whole
    /// of the check worth making: `URLComponents` parses `""` and a bare path quite happily, so
    /// a viewer URL missing its front would come back here as `/static/quiet-cedar-otter` — a
    /// string that looks enough like an answer to be printed, pasted into a page, and to
    /// resolve against whatever host that page is served from.
    public static func bytesURL(for location: PageLocation) -> String? {
        guard var components = URLComponents(string: location.url),
              components.scheme != nil, components.host != nil
        else { return nil }
        components.percentEncodedPath = Path.bytes(slug: location.slug)
        // The viewer carries neither, but a base URL configured with one would, and neither
        // belongs on the bytes.
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    /// `PUT /pages/:slug`. Replaces a page that already exists; never creates one.
    ///
    /// Takes no `ttl`, and not by omission — the server answers `?ttl=` on this verb with a
    /// `400`. What is fixed is not the deadline itself but the deadline's relationship to *this*
    /// verb: a page's expiry belongs to the page rather than to its current body, so replacing
    /// the body cannot quietly buy the link another week. A deadline does move — under its own
    /// verb, with no bytes attached to it. See `amend`. The response still reports the deadline
    /// the page has.
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

    /// `PATCH /pages/:slug`. Renames a page, moves its deadline, or both — and writes no bytes.
    ///
    /// The trap worth reading before anything else: `ttl: nil` here means **leave the deadline
    /// exactly where it is**, where the same `nil` on `publish` means "take whatever lifetime
    /// the server defaults to". `PageTTL?` cannot express that difference on its own — it is one
    /// optional with one absent case, and the two verbs read that absence in opposite ways — so
    /// the distinction rests entirely on this method never inventing a value. A `ttl=7` sent
    /// because seven looked like a reasonable default would put a week's deadline on a page its
    /// author published to keep forever, and nothing about the response would look wrong
    /// afterwards. So `?ttl=` travels only when the caller passed one, and `?slug=` only when the
    /// caller passed one; neither ever carries a placeholder. Passing neither is the server's
    /// `400` ("Nothing to amend"), which this method does not second-guess — a caller holding a
    /// command line can refuse it before spending the round trip, and the CLI does.
    ///
    /// Read the resulting address off the returned `PageLocation`; never rebuild it from
    /// `newSlug`. The server is the only thing that knows what actually happened — renaming a
    /// page to the name it already has is a successful no-op — and it answers with the slug the
    /// store settled on rather than the one that was asked for. A second place computing that
    /// answer is a second place to get it wrong.
    ///
    /// A rename is a hard move. The old name is freed the instant it commits: no redirect, no
    /// tombstone, and it goes straight back into the pool for anybody's next page. Every link
    /// already in circulation therefore breaks — as an ordinary `404` at first, and then, if
    /// someone else claims the name, as a link that quietly points at their page instead. That
    /// is the real cost of this verb, and the reason a caller should know whether the old URL
    /// has been handed to anyone before spending it.
    ///
    /// `?ttl=` is measured from *now*, not from the page's creation, so `.days(30)` grants
    /// thirty fresh days rather than whatever is left of them. It cannot raise the dead: an
    /// expired page is gone as far as every verb on this server is concerned, so `.never` aimed
    /// at one is a `404` and not a resurrection.
    ///
    /// Attribution is deliberately left alone, which is the inversion of `update`: `client_id`
    /// records who wrote a page's bytes, and an amendment writes none. Contents, content type
    /// and creation time survive for the same reason.
    public func amend(
        slug: String,
        newSlug: String? = nil,
        ttl: PageTTL? = nil,
        using credential: Credential
    ) async throws -> PageLocation {
        var query: [URLQueryItem] = []
        if let newSlug {
            query.append(URLQueryItem(name: Query.slug, value: newSlug))
        }
        if let ttl {
            query.append(URLQueryItem(name: PageTTL.queryParameter, value: ttl.queryValue))
        }
        return try await send(
            method: "PATCH",
            path: Path.page(slug: slug),
            query: query,
            credential: credential,
            expectation: .amend,
            decoding: PageLocation.self
        )
    }

    /// `DELETE /pages/:slug`. Takes a page down, and answers with nothing at all.
    ///
    /// The one write here that does not go through `send`, and it cannot: success is a `204` with
    /// no body — the server strips even `Content-Length` — while `send` hands whatever came back
    /// to a `JSONDecoder` unconditionally. Routed through it, every *successful* delete would
    /// surface as a `malformedResponse` complaining about zero bytes, with the page genuinely
    /// gone by then and the caller told the server had answered strangely. So this calls
    /// `perform` directly, the way `fetchSkill` does, and discards the response. There is nothing
    /// in it to read.
    ///
    /// Deletion is permanent and immediate: no tombstone, no redirect, and the slug goes straight
    /// back into the pool for anybody's next page. That is the same hard move a rename makes, and
    /// it costs the same — links already in circulation break as a plain `404` at first, and then,
    /// once someone else is allocated the name, as links that quietly point at their page instead.
    ///
    /// A `404` means the page was already gone, and an expired-but-unreclaimed page counts as gone
    /// here exactly as it does for `update` and `amend`. It is reported rather than swallowed: the
    /// server declines to claim a deletion it did not perform, and this method does not soften
    /// that into success on its behalf.
    public func delete(slug: String, using credential: Credential) async throws {
        // `credential.host`, deliberately — see the type's documentation. Every other
        // authenticated call inherits that rule from `send`; this one, bypassing it, has to keep
        // the rule itself.
        let target = credential.host
        _ = try await perform(
            SteleRequest(
                method: "DELETE",
                url: try url(path: Path.page(slug: slug), on: target),
                credential: credential,
                timeout: timeout
            ),
            host: target,
            expectation: .delete
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

    // MARK: - Signing in

    /// `POST /auth/github/device` — begin a GitHub sign-in, and get back what to show a human.
    ///
    /// The whole flow is proxied. This client never learns the OAuth app's client ID and never
    /// touches the GitHub access token the flow eventually produces: the server holds the one
    /// and consumes the other inside a single request, and what comes back here is a stele
    /// credential or nothing. That is the same custody argument the credential file rests on,
    /// moved one step earlier — a login that pasted a GitHub token would have put a *GitHub*
    /// secret on the machine to avoid putting a stele one there.
    ///
    /// A `401` here is the deployment declining rather than refusing the caller: it is the
    /// byte-identical answer an unconfigured `STELE_GITHUB_CLIENT_ID` gives, and it is
    /// indistinguishable — deliberately, on the server's side — from an empty owner allowlist.
    /// So it surfaces as `SteleError.unauthorized` and the caller decides what to do about a
    /// deployment that does not offer this. `auth login` falls back to a pasted token.
    public func startDeviceSignIn() async throws -> DeviceCodeBundle {
        let response = try await perform(
            SteleRequest(
                method: "POST",
                // No body and no `Content-Type`. The route reads neither, and an empty JSON
                // object would be this client inventing a shape for the server to ignore.
                url: try url(path: Path.authDevice, on: host),
                credential: nil,
                timeout: timeout
            ),
            host: host,
            expectation: .any
        )
        return try Self.decode(DeviceCodeBundle.self, from: response.body)
    }

    /// `POST /auth/github/exchange` — one poll of a device sign-in.
    ///
    /// The one method here whose *status* is the answer rather than a pass-or-fail, which is why
    /// it calls `perform` directly the way `delete` and `fetchSkill` do. A `202` means nobody has
    /// approved the code yet and is a perfectly good outcome; routed through `send` it would be
    /// handed to a decoder expecting a minted credential and reported as the server answering
    /// strangely.
    ///
    /// A `401` becomes `.refused` rather than an error, and that is the shape of the server's
    /// promise rather than a swallowed failure: expired, cancelled, not an owner and no
    /// allowlist are one byte-identical refusal, so there is nothing to describe and nothing to
    /// branch on. Everything else — a `500` because the server could not reach GitHub, a
    /// transport failure, a body this client cannot read — throws, so a poll loop can never
    /// mistake an outage for a person saying no.
    public func redeemDeviceCode(_ deviceCode: String) async throws -> DevicePoll {
        let response: SteleResponse
        do {
            response = try await perform(
                SteleRequest(
                    method: "POST",
                    url: try url(path: Path.authExchange, on: host),
                    contentType: "application/json",
                    body: try JSONEncoder().encode(RedeemDeviceCodeRequest(deviceCode: deviceCode)),
                    credential: nil,
                    timeout: timeout
                ),
                host: host,
                expectation: .any
            )
        } catch let error as SteleError {
            guard case .unauthorized = error else { throw error }
            return .refused
        }

        guard response.status != 202 else {
            return .pending(interval: Self.pendingInterval(from: response.body))
        }
        return .minted(try Self.decode(MintedClient.self, from: response.body))
    }

    /// The interval a `202` asked for, or nil when it named none.
    ///
    /// Read leniently and on purpose. The interval is advice — the flow already has one from the
    /// start response, and `DeviceSignIn` only ever raises it — so a `202` whose body this
    /// client cannot read is not worth failing a sign-in over that is otherwise going fine. Nil
    /// means "keep polling as before", which is what an older or newer server that spells this
    /// differently should get.
    static func pendingInterval(from body: Data) -> Int? {
        try? JSONDecoder.stele.decode(PendingResponse.self, from: body).interval
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
            expiresIn: expiresIn.map(Self.wholeSeconds)
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

    /// A lifetime as the whole seconds the request body carries, without trapping.
    ///
    /// `Int(someDouble)` outside `Int`'s range is a runtime trap, not an error, and this value
    /// arrives from a public parameter: `ExpiryDuration` bounds what the CLI can hand in, but
    /// nothing bounds what another caller of this library can. Clamping keeps an absurd argument
    /// a rejection from the server — which is the authority on lifetimes anyway — instead of a
    /// crash on the client.
    static func wholeSeconds(_ interval: TimeInterval) -> Int {
        let rounded = interval.rounded()
        // NaN first and on its own: it compares false against every bound, so a comparison
        // written to catch it would let it through to the conversion, which traps on NaN too.
        guard !rounded.isNaN else { return .max }
        guard rounded > Double(Int.min) else { return .min }
        guard rounded < Double(Int.max) else { return .max }
        return Int(rounded)
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
            decoding: ClientListResponse.self
        ).clients
    }

    /// `DELETE /admin/clients/:name` — stop a credential working, keeping its row.
    ///
    /// A `DELETE` even though nothing is deleted: revocation is the only kind of removal this
    /// collection has, and what it removes is the credential's ability to authenticate. The row
    /// survives with `revoked_at` set, which is what lets the list answer "this one was retired
    /// in March" instead of forgetting the credential existed. The server answers with the
    /// revoked record, and revoking twice returns the same `revokedAt` rather than moving it.
    public func revokeClient(
        name: String,
        using credential: Credential
    ) async throws -> ClientSummary {
        try await send(
            method: "DELETE",
            path: Path.client(named: name),
            credential: credential,
            expectation: .administration,
            decoding: ClientSummary.self
        )
    }

    // MARK: - Plumbing

    /// The JSON body `createClient` sends. A duration rather than an absolute expiry: the two
    /// clocks involved are the agent's and the server's, and only one of them has to be right
    /// if the client says "90 days from now" and the server does the arithmetic.
    ///
    /// The field names are the server's, spelled its way. `expiresIn` — seconds from now — is
    /// the one that has to be exact rather than merely reasonable: the server ignores keys it
    /// does not know, so `expiresInSeconds` earned a cheerful `201` and a credential that never
    /// expired. A wire mismatch that fails silently is why `SteleClientRequestTests` reads the
    /// encoded body back rather than trusting the call to have travelled.
    private struct CreateClientRequest: Encodable {
        let name: String
        let scopes: [String]
        let expiresIn: Int?
    }

    /// The JSON body a poll sends. One field, spelled the server's way — and spelled in *its*
    /// vocabulary rather than GitHub's `device_code`, for the reason the server gives about its
    /// own body: this is stele's contract with its client, and borrowing the upstream spelling
    /// is the start of a wire format that pretends to be a proxy for somebody else's.
    private struct RedeemDeviceCodeRequest: Encodable {
        let deviceCode: String
    }

    /// What a `202` carries. Optional even here: see `pendingInterval`.
    private struct PendingResponse: Decodable {
        let interval: Int?
    }

    /// `GET /admin/clients` answers with an object, not a bare array: a JSON array cannot grow a
    /// sibling field, so the envelope is what lets a cursor or a total appear later without
    /// breaking every parser. Unwrapped here so callers see the list.
    private struct ClientListResponse: Decodable {
        let clients: [ClientSummary]
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
        return try Self.decode(T.self, from: response.body)
    }

    /// Decodes a response body, or reports that the server answered in a shape this client does
    /// not know.
    ///
    /// The decoding error itself, not the body: a body that failed to decode is a body this
    /// client did not understand, and echoing an unknown server's bytes into an error message is
    /// how something unexpected ends up in a transcript.
    static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do {
            return try JSONDecoder.stele.decode(T.self, from: body)
        } catch {
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
        } catch let error as RedirectRefused {
            // Scrubbed for the same reason a server's message is: the destination is a string
            // the *server* chose, and it lands in an error a human reads on the machine the
            // credential lives on.
            throw SteleError.redirected(
                host: host, destination: Redaction.scrub(error.destination)
            )
        } catch let error as TransportError {
            // Scrubbed like a server's message, and for a stronger reason: `SteleTransport` is a
            // public protocol, so this string can come from a conformer written outside this
            // library — a logging decorator, someone's fake — and "no error carries a token" has
            // to hold for a transport this library did not write.
            throw SteleError.transportFailure(host: host, reason: Redaction.scrub(error.reason))
        } catch {
            throw SteleError.transportFailure(
                host: host, reason: Redaction.scrub(URLSessionTransport.reason(for: error))
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
