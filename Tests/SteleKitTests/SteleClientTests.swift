import Foundation
import Testing

@testable import SteleKit

/// Records what it was asked to send and replies with whatever the test set up.
///
/// This is the whole reason `SteleTransport` exists: the request-construction rules — which
/// verb, which path, which headers, which query — are decisions worth pinning, and pinning them
/// against a real server would need a server.
///
/// An actor rather than a lock-guarded class: `send` is `async`, and `NSLock.lock()` is
/// unavailable from an async context precisely because holding one across a suspension is the
/// bug it looks like.
private actor FakeTransport: SteleTransport {
    private(set) var requests: [SteleRequest] = []
    private let reply: @Sendable (SteleRequest) -> SteleResponse

    init(reply: @escaping @Sendable (SteleRequest) -> SteleResponse) {
        self.reply = reply
    }

    init(status: Int, body: String) {
        self.reply = { _ in SteleResponse(status: status, body: Data(body.utf8)) }
    }

    func send(_ request: SteleRequest) async throws -> SteleResponse {
        requests.append(request)
        return reply(request)
    }

    var last: SteleRequest? { requests.last }
}

private func testCredential(
    host: String = "https://stele.example.com",
    token: String = "stele_pat_test"
) throws -> Credential {
    Credential(host: try SteleHost(host), clientName: "claude-code", token: try Token(token))
}

@Suite("client requests")
struct SteleClientRequestTests {
    @Test("publish posts the body to /pages and returns the server's own URL")
    func publish() async throws {
        let transport = FakeTransport(
            status: 201,
            body: #"{"slug":"quiet-cedar-otter","url":"https://stele.example.com/quiet-cedar-otter"}"#
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        let location = try await client.publish(page: Data("<h1>hi</h1>".utf8), using: credential)

        #expect(location.slug == "quiet-cedar-otter")
        #expect(location.url == "https://stele.example.com/quiet-cedar-otter")
        let request = try #require(await transport.last)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://stele.example.com/pages")
        #expect(request.body == Data("<h1>hi</h1>".utf8))
    }

    /// The `--data-binary`-versus-`-d` and "remember the Content-Type" pitfalls the skill used
    /// to have to teach both stop existing here, because this is the only place that decides.
    @Test("every request carries the version, the token and the page's content type")
    func headers() async throws {
        let transport = FakeTransport(status: 201, body: #"{"slug":"a-b-c","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(page: Data("x".utf8), using: credential)

        let fields = try #require(await transport.last).headerFields()
        #expect(fields["User-Agent"] == "stele-cli/\(SteleVersion.current)")
        #expect(fields["Authorization"] == "Bearer stele_pat_test")
        #expect(fields["Content-Type"] == "text/html")
    }

    @Test("a requested slug travels as the ?slug= query parameter")
    func requestedSlug() async throws {
        let transport = FakeTransport(status: 201, body: #"{"slug":"my-page","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(page: Data("x".utf8), slug: "my-page", using: credential)

        #expect(try #require(await transport.last).url.query == "slug=my-page")
    }

    @Test("update puts to the slug's own path and sends no query")
    func update() async throws {
        let transport = FakeTransport(status: 200, body: #"{"slug":"my-page","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.update(slug: "my-page", page: Data("x".utf8), using: credential)

        let request = try #require(await transport.last)
        #expect(request.method == "PUT")
        #expect(request.url.absoluteString == "https://stele.example.com/pages/my-page")
    }

    /// The skill is a read, and reads on this server are unauthenticated — an agent
    /// bootstrapping from it does not have a credential yet.
    @Test("fetching the skill sends no credential")
    func skillIsUnauthenticated() async throws {
        let transport = FakeTransport(status: 200, body: "# stele\n")
        let client = SteleClient(host: try SteleHost("https://stele.example.com"), transport: transport)

        #expect(try await client.fetchSkill() == "# stele\n")
        #expect(try #require(await transport.last).headerFields()["Authorization"] == nil)
    }

    /// A token goes to the deployment it was filed under and to no other, whatever host the
    /// client was constructed with. Structural, so a `--host` mix-up cannot become a way to
    /// forward a credential somewhere it was never issued for.
    @Test("an authenticated call addresses the credential's host, not the client's")
    func credentialHostWins() async throws {
        let transport = FakeTransport(status: 201, body: #"{"slug":"a-b-c","url":"u"}"#)
        let credential = try testCredential(host: "https://filed.example.com")
        let client = SteleClient(host: try SteleHost("https://other.example.com"), transport: transport)

        _ = try await client.publish(page: Data("x".utf8), using: credential)

        #expect(try #require(await transport.last).url.absoluteString == "https://filed.example.com/pages")
    }

    @Test("minting a client returns the plaintext exactly once")
    func createClient() async throws {
        let transport = FakeTransport(
            status: 201,
            body: """
                {"client":{"name":"claude-code","scopes":["publish"],
                 "createdAt":"2026-08-04T10:00:00Z"},"token":"stele_pat_minted"}
                """
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        let minted = try await client.createClient(name: "claude-code", using: credential)

        #expect(minted.client.name == "claude-code")
        #expect(minted.client.has(.publish))
        #expect(minted.token.secret == "stele_pat_minted")
        #expect(try #require(await transport.last).url.absoluteString == "https://stele.example.com/admin/clients")
    }

    /// Fractional seconds are what a Postgres `timestamptz` renders as through most encoders,
    /// and `.iso8601` on its own rejects them — a mismatch that passes every hand-written
    /// fixture and fails against the real server.
    @Test("timestamps decode with and without fractional seconds")
    func timestamps() async throws {
        let transport = FakeTransport(
            status: 200,
            body: """
                {"clients":[{"name":"a","scopes":["publish"],"createdAt":"2026-08-04T10:00:00.123Z",
                  "lastUsedAt":"2026-08-04T11:00:00Z","revokedAt":"2026-08-04T12:00:00Z"}]}
                """
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        let clients = try await client.listClients(using: credential)

        #expect(clients.count == 1)
        #expect(clients[0].createdAt != nil)
        #expect(clients[0].lastUsedAt != nil)
        #expect(clients[0].isRevoked)
        #expect(!clients[0].isUsable())
    }

    /// The header an agent's request is identified by, and the one the server version-gates on.
    /// Sent on reads too, so a `426` cannot depend on which route was called.
    @Test("every request identifies the client and says what it will accept")
    func identityHeaders() async throws {
        let transport = FakeTransport(status: 200, body: "# stele\n")
        let client = SteleClient(host: try SteleHost("https://stele.example.com"), transport: transport)

        _ = try await client.fetchSkill()

        let request = try #require(await transport.last)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://stele.example.com/skill")
        #expect(request.headerFields()["User-Agent"] == SteleVersion.userAgent)
        #expect(request.headerFields()["Accept"] == "application/json, text/*")
        // A GET has no body, so a `Content-Type` on it would describe nothing.
        #expect(request.headerFields()["Content-Type"] == nil)
    }

    /// No `--slug` means no query at all rather than an empty one: `?slug=` is a *requested*
    /// slug the server would then have to reject, not an absent one.
    @Test("publishing without a slug sends no query")
    func noSlugMeansNoQuery() async throws {
        let transport = FakeTransport(status: 201, body: #"{"slug":"a-b-c","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(page: Data("x".utf8), using: credential)

        #expect(try #require(await transport.last).url.query == nil)
    }

    /// The route sits under `/admin` only because that first segment is reserved server-side; it
    /// is excluded from the admin-scope group on purpose, since `auth status` is the first thing
    /// an agent runs and an agent holds a publish-only credential.
    @Test("verifying a credential asks the server who it thinks we are")
    func whoami() async throws {
        let transport = FakeTransport(
            status: 200, body: #"{"name":"claude-code","scopes":["publish"]}"#
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        let summary = try await client.verifyCredential(credential)

        #expect(summary.name == "claude-code")
        let request = try #require(await transport.last)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://stele.example.com/admin/whoami")
        #expect(request.headerFields()["Authorization"] != nil)
    }

    /// The content type is a parameter with a default, not a constant: `stele publish notes.md`
    /// has to be able to say what it is publishing.
    @Test("an explicit content type is what gets sent")
    func explicitContentType() async throws {
        let transport = FakeTransport(status: 201, body: #"{"slug":"a-b-c","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(
            page: Data("# hi".utf8), contentType: "text/markdown", using: credential
        )

        #expect(try #require(await transport.last).headerFields()["Content-Type"] == "text/markdown")
    }

    /// The verb and the path are the server's, not a shape that reads well from here: the server
    /// serves `DELETE /admin/clients/:name` and has no `…/revoke` sub-resource at all. This
    /// suite asserted the invented one for a while and stayed green, which is the failure mode
    /// worth naming — a fake transport pinned to the client's own guesses tests nothing.
    @Test("revoking DELETEs the client's own resource")
    func revoke() async throws {
        let transport = FakeTransport(
            status: 200,
            body: #"{"name":"old agent","scopes":["publish"],"revokedAt":"2026-08-04T12:00:00Z"}"#
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        let summary = try await client.revokeClient(name: "old agent", using: credential)

        #expect(summary.isRevoked)
        let revokeRequest = try #require(await transport.last)
        #expect(revokeRequest.method == "DELETE")
        #expect(revokeRequest.url.path == "/admin/clients/old agent")
        // The name is percent-encoded into the path rather than pasted into it.
        #expect(revokeRequest.url.absoluteString == "https://stele.example.com/admin/clients/old%20agent")
    }

    /// `GET /admin/clients` answers `{"clients": […]}`, and the server pinned that envelope with
    /// a test of its own. Decoding a bare array here parsed nothing against a real deployment.
    @Test("listing decodes the server's envelope rather than a bare array")
    func listEnvelope() async throws {
        let transport = FakeTransport(
            status: 200,
            body: """
                {"clients":[{"name":"claude-code","scopes":["publish"],
                 "createdAt":"2026-08-04T10:00:00Z"}]}
                """
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        let clients = try await client.listClients(using: credential)

        #expect(clients.map(\.name) == ["claude-code"])
        let request = try #require(await transport.last)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://stele.example.com/admin/clients")
    }

    /// The silent one. The server decodes `expiresIn` and ignores keys it does not recognise, so
    /// the previous `expiresInSeconds` produced a `201`, a printed token and a credential that
    /// never expired — no error anywhere. Read off the encoded body, because nothing downstream
    /// of this line can tell the difference.
    @Test("--expires-in travels as the server's `expiresIn`, in seconds")
    func expiresInWireKey() async throws {
        let transport = FakeTransport(
            status: 201,
            body: """
                {"client":{"name":"temp","scopes":["publish"],
                 "createdAt":"2026-08-04T10:00:00Z","expiresAt":"2026-11-02T10:00:00Z"},
                 "token":"stele_pat_minted"}
                """
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.createClient(
            name: "temp", expiresIn: 90 * 24 * 60 * 60, using: credential
        )

        let request = try #require(await transport.last)
        let body = try #require(request.body)
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["expiresIn"] as? Int == 7_776_000)
        #expect(sent["name"] as? String == "temp")
        #expect(sent["scopes"] as? [String] == ["publish"])
        #expect(sent["expiresInSeconds"] == nil)
    }

    /// No expiry means the key is absent, not `null`: the server reads its absence as "does not
    /// expire", and an explicit null would be a second spelling of the same thing.
    @Test("no --expires-in sends no expiry key at all")
    func expiresInOmitted() async throws {
        let transport = FakeTransport(
            status: 201,
            body: """
                {"client":{"name":"temp","scopes":["publish"],
                 "createdAt":"2026-08-04T10:00:00Z"},"token":"stele_pat_minted"}
                """
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.createClient(name: "temp", using: credential)

        let request = try #require(await transport.last)
        let body = try #require(request.body)
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["expiresIn"] == nil)
    }
}

@Suite("status mapping")
struct SteleErrorMappingTests {
    private func failure(status: Int, body: String = "") async -> (any Error)? {
        do {
            let credential = try testCredential()
            let client = SteleClient(
                credential: credential, transport: FakeTransport(status: status, body: body)
            )
            _ = try await client.publish(page: Data("x".utf8), using: credential)
            return nil
        } catch {
            return error
        }
    }

    /// One case per outcome the caller reacts to differently, and every description ends in an
    /// instruction — the reader is an agent deciding whether to retry, fix the input, or stop.
    @Test(
        "each status maps to advice the caller can act on",
        arguments: [
            (400, "Fix the input"),
            (401, "stele auth login"),
            (403, "publish"),
            (404, "stele publish"),
            (409, "--slug"),
            (413, "link them instead"),
            (415, "content type"),
            (426, "make -C ~/repos/stele-cli install"),
            (503, "Retry once"),
            (500, "no advice for"),
        ]
    )
    func advice(_ status: Int, _ expected: String) async throws {
        let error = try #require(await failure(status: status) as? SteleError)
        #expect(error.description.contains(expected))
    }

    /// The table asserted as identity rather than as prose. A status mapped to a *plausible but
    /// wrong* case — `413` to `unsupportedContentType`, say — still produces a description full
    /// of confident advice, and the advice is for the wrong problem. The exit code the executable
    /// picks comes off the case too, so this is the assertion the `$?` contract rests on.
    @Test(
        "each status maps to its own case",
        arguments: [
            (400, SteleError.badRequest("m")),
            (401, .unauthorized),
            (403, .forbidden(missing: .publish, detail: "m")),
            (404, .notFound(detail: "m", advice: SteleError.Expectation.write.notFoundAdvice)),
            (409, .slugTaken("m")),
            (413, .pageTooLarge("m")),
            (415, .unsupportedContentType("m")),
            (426, .upgradeRequired("m")),
            (503, .slugAllocationFailed("m")),
            (418, .unexpectedStatus(code: 418, detail: "m")),
            (500, .unexpectedStatus(code: 500, detail: "m")),
        ]
    )
    func statusIdentity(_ status: Int, _ expected: SteleError) {
        #expect(SteleError.from(status: status, detail: "m", expectation: .write) == expected)
    }

    /// The mapping is what decides whether a call succeeded, so the 2xx range has to be a
    /// non-answer rather than an `unexpectedStatus` for the codes nobody thought to list.
    @Test("no 2xx is an error", arguments: [200, 201, 202, 204, 299])
    func successIsNotAnError(_ status: Int) {
        #expect(SteleError.from(status: status, detail: nil, expectation: .write) == nil)
    }

    /// The two statuses whose meaning depends on what was asked. A `404` from `stele update`
    /// means the page was never published; a `404` from an admin call means the client name is
    /// wrong, and "publish it first" would be nonsense advice for it.
    @Test("403 and 404 say different things depending on what was being attempted")
    func adviceFollowsTheOperation() throws {
        let write = try #require(SteleError.from(status: 404, detail: nil, expectation: .write))
        let admin = try #require(
            SteleError.from(status: 404, detail: nil, expectation: .administration)
        )
        #expect(write.description.contains("stele publish"))
        #expect(admin.description.contains("stele admin clients list"))

        let forbiddenWrite = try #require(
            SteleError.from(status: 403, detail: nil, expectation: .write)
        )
        let forbiddenAdmin = try #require(
            SteleError.from(status: 403, detail: nil, expectation: .administration)
        )
        #expect(forbiddenWrite.description.contains("`publish` scope"))
        #expect(forbiddenAdmin.description.contains("`admin` scope"))
    }

    /// The reader is an agent choosing between retrying, changing the input and stopping to ask
    /// a human, and a message that describes the failure without naming one of those has told it
    /// nothing it can act on. The list is that vocabulary, not a style rule.
    @Test("every case's description names a next step")
    func everyDescriptionIsActionable() throws {
        let imperatives = ["retry", "check", "fix", "choose", "drop", "publish", "ask the user", "reinstall"]
        var seen: [SteleError] = []
        for status in [400, 401, 403, 404, 409, 413, 415, 426, 503, 500] {
            seen.append(try #require(SteleError.from(status: status, detail: nil, expectation: .write)))
        }
        seen.append(.transportFailure(host: try SteleHost("https://stele.example.com"), reason: "refused"))
        seen.append(.malformedResponse("not JSON"))

        for error in seen {
            let description = error.description.lowercased()
            #expect(
                imperatives.contains(where: description.contains),
                "no next step in: \(error.description)"
            )
        }
    }

    /// A 401 says the credential was rejected and never which credential — and the case has no
    /// payload to say it with even if a future edit wanted to.
    @Test("a 401 carries no detail from the server")
    func unauthorizedIsBare() async throws {
        let body = #"{"error":{"message":"token stele_pat_leaked is revoked"}}"#
        let error = try #require(await failure(status: 401, body: body) as? SteleError)
        #expect(error == .unauthorized)
        #expect(!error.description.contains("stele_pat"))
    }

    /// The server's message is the specific half of the sentence — losing it leaves the reader
    /// guessing which rule they broke.
    @Test("the server's own message is quoted alongside the advice")
    func serverMessageSurvives() async throws {
        let body = #"{"error":{"message":"Invalid slug: contains '_'"}}"#
        let error = try #require(await failure(status: 400, body: body) as? SteleError)
        #expect(error.description.contains("Invalid slug: contains '_'"))
    }

    /// An HTML error page from a proxy would otherwise arrive as a screenful of markup in the
    /// middle of a one-line message.
    @Test("an HTML error body is dropped rather than quoted")
    func htmlBodiesAreDropped() {
        #expect(SteleClient.detail(from: Data("<html><body>502</body></html>".utf8)) == nil)
    }

    @Test("a transport failure names the host and says the credential never left")
    func transportFailure() async throws {
        let error = SteleError.transportFailure(
            host: try SteleHost("https://stele.example.com"), reason: "connection refused"
        )
        #expect(error.description.contains("https://stele.example.com"))
        #expect(error.description.contains("never sent"))
    }

    /// A 2xx this client cannot parse is reported as the server not being what we expected,
    /// with the decoding failure rather than the bytes: echoing an unknown server's body into
    /// an error message is how something unexpected ends up in a transcript.
    @Test("an undecodable success is a malformed response")
    func malformedSuccess() async throws {
        let error = try #require(
            await failure(status: 201, body: "not json at all") as? SteleError
        )
        guard case .malformedResponse = error else {
            Issue.record("expected malformedResponse, got \(error)")
            return
        }
    }
}
