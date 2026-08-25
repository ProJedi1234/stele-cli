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

    /// The silent failure this parameter is heir to. A `ttl` misspelled in the query is not a
    /// `400` — the server has no reason to look at a parameter it does not know, so the upload
    /// earns a cheerful `201` and the page the caller asked to keep quietly dies on the default
    /// schedule. Read off the URL, because nothing downstream would notice.
    @Test(
        "a lifetime travels as ?ttl=, spelled the server's way",
        arguments: [(PageTTL.days(30), "ttl=30"), (PageTTL.days(14), "ttl=14"), (.never, "ttl=never")]
    )
    func lifetimeQuery(_ ttl: PageTTL, _ expected: String) async throws {
        let transport = FakeTransport(status: 201, body: #"{"slug":"a-b-c","url":"u","expires":null}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(page: Data("x".utf8), ttl: ttl, using: credential)

        #expect(try #require(await transport.last).url.query == expected)
    }

    /// `?ttl=` and `?slug=` are independent, and a page that asks for both must send both — the
    /// query is built by appending, and an assignment where an append belonged would drop one.
    @Test("a slug and a lifetime both travel")
    func slugAndLifetime() async throws {
        let transport = FakeTransport(status: 201, body: #"{"slug":"my-page","url":"u","expires":null}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(
            page: Data("x".utf8), slug: "my-page", ttl: .never, using: credential
        )

        let query = try #require(await transport.last).url.query
        #expect(query == "slug=my-page&ttl=never")
    }

    /// No `--ttl` means no parameter at all, which is a third thing and not a synonym for
    /// either value: absence is what asks for the server's default lifetime. `?ttl=` with
    /// nothing after it is a `400`, and `?ttl=never` would keep a page nobody asked to keep.
    @Test("publishing without a lifetime sends no ttl at all")
    func noLifetime() async throws {
        let transport = FakeTransport(status: 201, body: #"{"slug":"a-b-c","url":"u","expires":null}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(page: Data("x".utf8), slug: "a-b-c", using: credential)

        #expect(try #require(await transport.last).url.query == "slug=a-b-c")
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

    @Test("amend patches the slug's own path")
    func amend() async throws {
        let transport = FakeTransport(
            status: 200,
            body: """
                {"slug":"loud-cedar-otter","url":"https://stele.example.com/loud-cedar-otter",
                 "expires":null}
                """
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        let location = try await client.amend(
            slug: "quiet-cedar-otter", newSlug: "loud-cedar-otter", using: credential
        )

        #expect(location.slug == "loud-cedar-otter")
        let request = try #require(await transport.last)
        #expect(request.method == "PATCH")
        // Addressed at the page as it is *now*: the old name is what identifies the row, and the
        // new one is what is being asked for, so they cannot swap places.
        #expect(
            request.url.absoluteString
                == "https://stele.example.com/pages/quiet-cedar-otter?slug=loud-cedar-otter"
        )
    }

    /// The load-bearing one. `ttl: nil` means opposite things on the two verbs — on `publish` it
    /// asks for the server's default lifetime, and here it means *leave the deadline alone* — and
    /// nothing in the type system carries that difference. It rests entirely on this request not
    /// inventing a value. A `ttl=7` appended because seven looked like a sensible default would
    /// put a week's deadline on a page its author published to keep forever, and the `200` that
    /// came back would look exactly like the one a correct request earns; the page would simply
    /// be gone the following week. So the assertion is absence rather than emptiness: `?ttl=`
    /// with nothing after it is a value too, and a value is the thing that must not be sent.
    @Test("a rename with no lifetime sends no ttl at all")
    func renameSendsNoLifetime() async throws {
        let transport = FakeTransport(status: 200, body: #"{"slug":"new-name","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.amend(slug: "old-name", newSlug: "new-name", using: credential)

        let request = try #require(await transport.last)
        #expect(request.url.query == "slug=new-name")
        // Not merely "no ttl parameter": no `ttl` anywhere in the request at all, which is the
        // form the assertion has to take because an empty or defaulted one would still parse.
        #expect(!request.url.absoluteString.contains("ttl"))
    }

    /// The mirror, and the reason the two parameters are appended independently rather than
    /// built as a pair: retiming a page must not rename it, and `?slug=` echoing the page's
    /// current name would be a rename that happens to be a no-op today and a collision the day
    /// the caller passes a stale slug.
    @Test("a lifetime with no rename sends no slug at all")
    func retimeSendsNoSlug() async throws {
        let transport = FakeTransport(status: 200, body: #"{"slug":"old-name","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.amend(slug: "old-name", ttl: .days(30), using: credential)

        let request = try #require(await transport.last)
        let query = try #require(request.url.query)
        #expect(query == "ttl=30")
        #expect(!query.contains("slug"))
    }

    /// The server takes both in one `PATCH`, so a caller that asked for both gets one round trip
    /// and one outcome. Split into two requests they could half-succeed — a page renamed and
    /// still dying on Thursday — with no verb left to say so.
    @Test("a rename and a lifetime travel together in one request")
    func renameAndLifetime() async throws {
        let transport = FakeTransport(status: 200, body: #"{"slug":"new-name","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.amend(
            slug: "old-name", newSlug: "new-name", ttl: .never, using: credential
        )

        let request = try #require(await transport.last)
        #expect(request.url.query == "slug=new-name&ttl=never")
        #expect(await transport.requests.count == 1)
    }

    /// Spelled the server's way, from the server's own constant. `ttl=forever` would be a `400`
    /// and a computed date would be a deadline rather than the absence of one — and `never` is
    /// the only word this route reads as "keep it".
    @Test("an amended lifetime of never travels as the server's own keyword")
    func amendNeverKeyword() async throws {
        let transport = FakeTransport(status: 200, body: #"{"slug":"old-name","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.amend(slug: "old-name", ttl: .never, using: credential)

        #expect(try #require(await transport.last).url.query == "ttl=\(PageTTL.neverKeyword)")
    }

    /// An amendment writes no bytes — that is the whole shape of the verb, and the reason the
    /// server leaves `client_id` alone where `PUT` overwrites it. A `Content-Type` on it would
    /// be a claim about content this request is not sending, and a body would be bytes the
    /// server has already promised not to read.
    @Test("amend sends no body and no content type")
    func amendSendsNothing() async throws {
        let transport = FakeTransport(status: 200, body: #"{"slug":"new-name","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.amend(slug: "old-name", newSlug: "new-name", using: credential)

        let request = try #require(await transport.last)
        #expect(request.body == nil)
        #expect(request.contentType == nil)
        #expect(request.headerFields()["Content-Type"] == nil)
        // Still authenticated, though: an amendment is a write and carries the publish scope.
        #expect(request.headerFields()["Authorization"] == "Bearer stele_pat_test")
    }

    /// The server has the last word on what the page is now called, and this side reads it off
    /// the response rather than assuming the request got what it asked for. Renaming a page to
    /// the name it already has is a successful no-op, so "what was asked for" and "what the store
    /// settled on" are genuinely different questions — and a URL rebuilt from `newSlug` would be
    /// right often enough to survive review and wrong the day it mattered.
    @Test("the resulting slug is the server's answer, not the one that was asked for")
    func resultingSlugComesFromTheServer() async throws {
        let transport = FakeTransport(
            status: 200,
            body: """
                {"slug":"server-settled-on-this",
                 "url":"https://stele.example.com/server-settled-on-this","expires":null}
                """
        )
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        let location = try await client.amend(
            slug: "old-name", newSlug: "asked-for-this", using: credential
        )

        #expect(location.slug == "server-settled-on-this")
        #expect(location.url == "https://stele.example.com/server-settled-on-this")
    }

    /// A delete's request is mostly absences, and each one is a decision. No query: this route has
    /// no parameters at all, and one the server does not know is silence rather than a `400`. No
    /// body and no content type: the server reads neither, so a `Content-Type` here would be a
    /// claim about bytes that are not being sent.
    @Test("delete DELETEs the slug's own path and sends nothing with it")
    func delete() async throws {
        let transport = FakeTransport(status: 204, body: "")
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        try await client.delete(slug: "quiet-cedar-otter", using: credential)

        let request = try #require(await transport.last)
        #expect(request.method == "DELETE")
        #expect(request.url.absoluteString == "https://stele.example.com/pages/quiet-cedar-otter")
        #expect(request.url.query == nil)
        #expect(request.body == nil)
        #expect(request.contentType == nil)
        #expect(request.headerFields()["Content-Type"] == nil)
        // Behind the bearer token like every other write on /pages — a delete is not a read.
        #expect(request.headerFields()["Authorization"] == "Bearer stele_pat_test")
    }

    /// The reason `delete` does not go through the generic `send` helper, pinned. Success on this
    /// route is a `204` with no body — the server strips `Content-Length` too — and `send` decodes
    /// the body unconditionally, so a delete routed through it would fail on every success with a
    /// `malformedResponse` about zero bytes. Nothing downstream could tell that apart from a real
    /// server problem, and by then the page is actually gone: the caller would be told the delete
    /// went wrong about a delete that worked.
    @Test("a 204 with an empty body is a success, not a decoding failure")
    func deleteAcceptsAnEmptyBody() async throws {
        let transport = FakeTransport(status: 204, body: "")
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        try await client.delete(slug: "quiet-cedar-otter", using: credential)

        #expect(await transport.requests.count == 1)
    }

    /// The *other* surface a slug arrives on, and it is protected by something different from
    /// the path segment's percent-encoding. A query value is not a path: dot-segment removal
    /// never looks at it, so `../admin/clients` stays a string sitting in `?slug=`, unresolved,
    /// and the request still acts on the page named in the path. That is the property worth
    /// asserting — not an escaping that does not happen here. What the value *means* is the
    /// server's `Slug` type's business, and a name like this comes back as the `400` that names
    /// the rule it broke, which is exactly where that judgement belongs.
    @Test("a new slug cannot climb out of /pages")
    func newSlugStaysInTheQuery() async throws {
        let transport = FakeTransport(status: 200, body: #"{"slug":"x","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try? await client.amend(
            slug: "quiet-cedar-otter", newSlug: "../admin/clients", using: credential
        )

        let request = try #require(await transport.last)
        #expect(request.url.path == "/pages/quiet-cedar-otter")
        #expect(request.url.standardized.path == "/pages/quiet-cedar-otter")
        // It travelled as a value, whole, for the server to reject on its own terms.
        let components = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        )
        #expect(
            components.queryItems == [URLQueryItem(name: "slug", value: "../admin/clients")]
        )
    }

    /// A slug is one path segment and must stay one, however it is spelled. Left raw it is not
    /// only a `/` away from another route: RFC 3986 removes dot segments before the request is
    /// ever sent, so `update ../admin/clients` reaches the server as `PUT /admin/clients` — an
    /// admin route addressed by a page command. The token still travels only to its own host,
    /// so this is not a leak; it is the request acting on a resource nobody named.
    @Test(
        "a slug cannot climb out of /pages",
        arguments: [
            ("../admin/clients", "https://stele.example.com/pages/..%2Fadmin%2Fclients"),
            ("..", "https://stele.example.com/pages/%2E%2E"),
            (".", "https://stele.example.com/pages/%2E"),
            ("a/b", "https://stele.example.com/pages/a%2Fb"),
            ("quiet-cedar-otter", "https://stele.example.com/pages/quiet-cedar-otter"),
        ]
    )
    func slugStaysOneSegment(_ slug: String, _ expected: String) async throws {
        let transport = FakeTransport(status: 200, body: #"{"slug":"x","url":"u"}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try? await client.update(slug: slug, page: Data("x".utf8), using: credential)

        let request = try #require(await transport.last)
        #expect(request.url.absoluteString == expected)
        // The property the escapes above are only instances of: whatever was typed, the request
        // is still for something under /pages.
        #expect(request.url.standardized.path.hasPrefix("/pages/"))
    }

    /// The same rule on the verb that is already destructive, which is what makes a stray path
    /// segment worth catching here twice over: dot segments are removed before the request leaves,
    /// so `delete ../admin/clients/claude-code` raw is `DELETE /admin/clients/claude-code` — a
    /// page command revoking a credential. Encoded, the whole thing stays one segment and comes
    /// back as the server's `400` naming the rule the slug broke.
    @Test(
        "a deleted slug cannot climb out of /pages",
        arguments: [
            (
                "../admin/clients/claude-code",
                "https://stele.example.com/pages/..%2Fadmin%2Fclients%2Fclaude-code"
            ),
            ("..", "https://stele.example.com/pages/%2E%2E"),
            (".", "https://stele.example.com/pages/%2E"),
            ("a/b", "https://stele.example.com/pages/a%2Fb"),
            ("quiet-cedar-otter", "https://stele.example.com/pages/quiet-cedar-otter"),
        ]
    )
    func deletedSlugStaysOneSegment(_ slug: String, _ expected: String) async throws {
        let transport = FakeTransport(status: 204, body: "")
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        try await client.delete(slug: slug, using: credential)

        let request = try #require(await transport.last)
        #expect(request.url.absoluteString == expected)
        #expect(request.url.standardized.path.hasPrefix("/pages/"))
    }

    /// The same rule on the admin side, where the reachable routes are the destructive ones.
    @Test("a client name cannot climb out of /admin/clients")
    func clientNameStaysOneSegment() async throws {
        let transport = FakeTransport(status: 200, body: #"{"name":"x","scopes":[]}"#)
        let credential = try testCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try? await client.revokeClient(name: "../../pages/quiet-cedar-otter", using: credential)

        let request = try #require(await transport.last)
        #expect(
            request.url.absoluteString
                == "https://stele.example.com/admin/clients/..%2F..%2Fpages%2Fquiet-cedar-otter"
        )
        #expect(request.url.standardized.path.hasPrefix("/admin/clients/"))
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

/// The other half of the lifetime contract: what comes back. The deadline is the server's to
/// compute — against its clock, with its default — so reading it off the response is the only
/// way this side ever knows when a page dies.
@Suite("page location")
struct PageLocationTests {
    private func decode(_ json: String) throws -> PageLocation {
        try JSONDecoder.stele.decode(PageLocation.self, from: Data(json.utf8))
    }

    @Test("a deadline is read off the response rather than computed here")
    func readsTheDeadline() throws {
        let location = try decode(
            #"{"slug":"a-b-c","url":"https://s.example.com/a-b-c","expires":"2026-08-12T10:00:00Z"}"#
        )
        #expect(location.slug == "a-b-c")
        #expect(location.expiresAt == Date(timeIntervalSince1970: 1_786_528_800))
    }

    /// Both wire shapes for "no deadline". An explicit null is what the server sends for a page
    /// it will keep; the key is absent from a deployment older than page expiry, where nothing
    /// expires either. Reading them the same way is not a shortcut — they mean the same thing.
    @Test("null and absent both mean the page has no deadline", arguments: [
        #"{"slug":"a","url":"u","expires":null}"#,
        #"{"slug":"a","url":"u"}"#,
    ])
    func noDeadline(_ json: String) throws {
        #expect(try decode(json).expiresAt == nil)
    }

    /// Fractional seconds are what a Postgres `timestamptz` renders as through most encoders,
    /// so the deadline has to survive the same shapes every other timestamp does.
    @Test("the deadline accepts both ISO 8601 shapes")
    func deadlineTimestampShapes() throws {
        let plain = try decode(#"{"slug":"a","url":"u","expires":"2026-08-12T10:00:00Z"}"#)
        let fractional = try decode(#"{"slug":"a","url":"u","expires":"2026-08-12T10:00:00.123Z"}"#)
        #expect(plain.expiresAt != nil)
        #expect(fractional.expiresAt != nil)
    }

    /// `--json` is a machine contract, and the synthesised encoder would drop the key entirely
    /// for a page that is kept — leaving a reader unable to tell "no deadline" from "this tool
    /// said nothing about deadlines". The server hand-writes its encoder for this; so does this.
    @Test("a kept page encodes an explicit null rather than dropping the key")
    func encodesExplicitNull() throws {
        let json = String(
            decoding: try JSONEncoder().encode(PageLocation(slug: "a", url: "u")), as: UTF8.self
        )
        #expect(json.contains("\"expires\":null"))
    }

    /// The round trip the `--json` documentation promises: what this tool prints, it can read.
    @Test("a location survives the round trip through its own JSON")
    func roundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for expiry in [nil, Date(timeIntervalSince1970: 1_786_528_800)] {
            let original = PageLocation(slug: "a-b-c", url: "u", expiresAt: expiry)
            let decoded = try JSONDecoder.stele.decode(
                PageLocation.self, from: try encoder.encode(original)
            )
            #expect(decoded == original)
        }
    }
}

/// The `409` advice a route carries, read back out of the case that holds it.
///
/// A test asserting the status→case mapping by identity has to build the expected case by hand,
/// and the advice is part of it — but retyping the sentence here would be a copy that goes on
/// passing while the two drift, which is the failure the advice was moved onto `Expectation` to
/// prevent in the first place. What the identity test is for is the *case*; which route's words
/// it carries is asserted separately, by wording, in `amendConflictIsASlug`.
extension SteleError.Expectation {
    var slugTakenAdvice: String {
        guard case .slug(let advice) = conflict else { return "" }
        return advice
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

    /// The same round trip through `amend`, so what is asserted is the advice this *route*
    /// produces rather than the `Expectation` a test picked by hand — the mistake being guarded
    /// against is the call site passing the wrong one.
    private func amendFailure(status: Int, body: String = "") async -> (any Error)? {
        do {
            let credential = try testCredential()
            let client = SteleClient(
                credential: credential, transport: FakeTransport(status: status, body: body)
            )
            _ = try await client.amend(slug: "old-name", newSlug: "new-name", using: credential)
            return nil
        } catch {
            return error
        }
    }

    /// The same round trip through `delete`, and it exists for `amendFailure`'s reason: the thing
    /// worth asserting is the advice this *route* produces, since the mistake being guarded
    /// against is the call site handing `perform` the wrong `Expectation` — which no amount of
    /// testing `Expectation.delete` on its own would catch.
    private func deleteFailure(status: Int, body: String = "") async -> (any Error)? {
        do {
            let credential = try testCredential()
            let client = SteleClient(
                credential: credential, transport: FakeTransport(status: status, body: body)
            )
            try await client.delete(slug: "quiet-cedar-otter", using: credential)
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
            (426, "just -f ~/repos/stele-cli/justfile install"),
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
            (
                409,
                .slugTaken(
                    detail: "m", advice: SteleError.Expectation.write.slugTakenAdvice
                )
            ),
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

    /// The third such status, and the one that was wrong until it was split. `409` means two
    /// unrelated things on this server, and the shared case told an operator whose credential
    /// name had collided to "choose another `--slug`" — naming a flag `admin clients create`
    /// does not have, for a resource the request never mentioned.
    @Test("409 says what it collided with, which depends on the route")
    func conflictFollowsTheOperation() throws {
        let write = try #require(SteleError.from(status: 409, detail: nil, expectation: .write))
        let admin = try #require(
            SteleError.from(status: 409, detail: nil, expectation: .administration)
        )

        #expect(
            write
                == .slugTaken(
                    detail: nil, advice: SteleError.Expectation.write.slugTakenAdvice
                )
        )
        #expect(admin == .nameTaken(nil))
        #expect(write.description.contains("--slug"))
        // A publish *does* have the escape amend has not: no `--slug` at all, and the server
        // allocates one. The advice says so, and this is the route it is true of.
        #expect(write.description.contains("omit it and let the server generate one"))
        #expect(admin.description.contains("stele admin clients revoke"))
        // The specific mistake this split exists to make impossible.
        #expect(!admin.description.contains("--slug"))
    }

    /// The whole reason `Expectation.amend` exists rather than borrowing `write`'s. A `404` here
    /// is most often a page that has *expired*, and `write`'s advice — "`stele update` never
    /// creates a page, publish it first" — names the wrong command and, worse, leaves the obvious
    /// next move looking like `--ttl never`, which fails identically because this verb cannot
    /// revive anything.
    @Test("a 404 from amend advises about amend rather than about update")
    func amendNotFoundAdvice() async throws {
        let error = try #require(
            await amendFailure(status: 404, body: #"{"error":{"message":"No page there"}}"#)
                as? SteleError
        )
        #expect(error.description.contains("stele amend"))
        #expect(error.description.contains("never creates"))
        #expect(!error.description.contains("stele update"))
    }

    /// The new name being held by another live page. It has to reach `slugTaken` rather than
    /// `nameTaken` or an `unexpectedStatus`, because that case is what carries the exit code an
    /// agent reads as "pick another name and retry" — the one outcome here that is worth
    /// retrying at all.
    ///
    /// It carries *this* route's advice with it, and the second half of that is what the last
    /// assertion is for. `publish`'s sentence ends "or omit it and let the server generate one",
    /// which on an amendment is a dead end: omitting `--slug` asks for no rename, the server
    /// allocates nothing, and an agent that follows it lands on the client-side "nothing to
    /// amend" and exit 1 without a request ever leaving the process. Same status, same case, two
    /// remedies — exactly the split `nameTaken` already exists for.
    @Test("a 409 from amend is a taken slug, with advice amend can actually act on")
    func amendConflictIsASlug() async throws {
        let error = try #require(await amendFailure(status: 409, body: "") as? SteleError)
        #expect(
            error
                == .slugTaken(
                    detail: nil, advice: SteleError.Expectation.amend.slugTakenAdvice
                )
        )
        #expect(error.description.contains("--slug"))
        #expect(!error.description.contains("omit it and let the server generate one"))
    }

    /// Why `Expectation.delete` exists rather than reusing `write`'s. That advice names
    /// `stele update` and tells the reader to publish the page first — on a delete that is not the
    /// wrong command so much as the reverse instruction, and an agent obeying it would recreate
    /// the page it had just been asked to remove, ending the run with the page live and nothing
    /// looking like a failure. The truth here is duller and needs no next command: the page is
    /// already gone, expired or deleted earlier, and the server would rather say so than claim a
    /// deletion it never performed.
    @Test("a 404 from delete says the page is already gone rather than to publish it")
    func deleteNotFoundAdvice() async throws {
        let error = try #require(
            await deleteFailure(status: 404, body: #"{"error":{"message":"No page there"}}"#)
                as? SteleError
        )
        #expect(
            error
                == .notFound(
                    detail: "No page there", advice: SteleError.Expectation.delete.notFoundAdvice
                )
        )
        #expect(error.description.contains("nothing left to delete"))
        #expect(!error.description.contains("stele update"))
        #expect(!error.description.contains("stele publish"))
    }

    /// The scope named in a `403` comes off the route's `Expectation`, and a delete is a write on
    /// `/pages` like the rest — `publish`, not `admin`. Naming the wrong one sends an agent whose
    /// credential is perfectly good hunting for an operator token it will never be given.
    @Test("a 403 from delete names the publish scope")
    func deleteForbiddenScope() async throws {
        let error = try #require(
            await deleteFailure(status: 403, body: #"{"error":{"message":"Missing scope"}}"#)
                as? SteleError
        )
        #expect(error == .forbidden(missing: .publish, detail: "Missing scope"))
        #expect(error.description.contains("`publish` scope"))
    }

    /// A read has nothing unique on it for a `409` to be about, so this client says it has no
    /// advice rather than picking whichever of the two conflicts it was written next to.
    @Test("409 on a route with nothing unique is an unexpected status")
    func conflictOnAReadIsUnexpected() {
        #expect(
            SteleError.from(status: 409, detail: "m", expectation: .any)
                == .unexpectedStatus(code: 409, detail: "m")
        )
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
        // The two statuses that answer in the route's own words, taken from the other route that
        // has any: advice is per-`Expectation`, so "every description names a next step" is a
        // claim about each set of words and not about each case.
        for status in [404, 409] {
            seen.append(try #require(SteleError.from(status: status, detail: nil, expectation: .amend)))
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
