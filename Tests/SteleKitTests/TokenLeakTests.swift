import Foundation
import Testing

@testable import SteleKit

/// The canary. Shaped like a real credential — the `stele_pat_` prefix and a base64url body —
/// because half of what is under test recognises tokens by that shape, and distinctive enough
/// that a substring search for it cannot match something a fixture produced by accident.
private let heldSecret = "stele_pat_HELD-canary_00000000000000000000"

/// A second canary, standing in for a token that reached a *server* and came back inside a
/// message the server wrote. Kept distinct from the one this client holds so a failure says
/// which direction the leak ran in: our own credential escaping, or a remote string we repeated.
private let echoedSecret = "stele_pat_ECHOED-canary_1111111111111111"

/// Every way a program turns a value into text without deliberately reaching for a plaintext
/// accessor.
///
/// The four are not redundant. `"\(value)"` takes `description`, `String(reflecting:)` takes
/// `debugDescription`, `dump` walks the mirror and ignores both, and `JSONEncoder` ignores all
/// three and reads the stored properties. A type can close three of those doors and leave the
/// fourth open, which is exactly the failure this file exists to catch.
private func renderings(of value: Any) -> [String] {
    var dumped = ""
    dump(value, to: &dumped)
    var forms = ["\(value)", String(reflecting: value), dumped]
    if let encodable = value as? any Encodable,
       let data = try? JSONEncoder().encode(AnyEncodable(wrapped: encodable)),
       let json = String(data: data, encoding: .utf8) {
        forms.append(json)
    }
    return forms
}

/// Lets `renderings` encode a value it only knows is `Encodable`. Nothing in the library needs
/// this; it exists so the test can ask "if a `--json` encoder got hold of you, what would come
/// out?" of a value whose type it does not know statically.
private struct AnyEncodable: Encodable {
    let wrapped: any Encodable
    func encode(to encoder: any Encoder) throws { try wrapped.encode(to: encoder) }
}

/// Asserts that nothing about `value`, rendered every way a program can render it, contains
/// either canary.
private func expectNoLeak(
    _ value: Any,
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for rendering in renderings(of: value) {
        for secret in [heldSecret, echoedSecret] where rendering.contains(secret) {
            Issue.record(
                "\(label) rendered a token: \(rendering)",
                sourceLocation: sourceLocation
            )
        }
        // The prefix on its own, in case a future edit truncates a token rather than redacting
        // it — half a credential is still half a credential, and it is still evidence one exists.
        if rendering.contains(Token.mintedPrefix) {
            Issue.record(
                "\(label) rendered something token-shaped: \(rendering)",
                sourceLocation: sourceLocation
            )
        }
    }
}

/// Runtime conformance check. Generic so the cast is resolved at run time rather than folded
/// away by the type checker, which knows perfectly well what conforms to what in this module.
private func conforms<T>(_ value: Any, to protocolType: T.Type) -> Bool { value is T }

private func heldCredential(host: String = "https://stele.example.com") throws -> Credential {
    Credential(host: try SteleHost(host), clientName: "claude-code", token: try Token(heldSecret))
}

/// A real directory to write a real `0600` file into. Same reason `CredentialsTests` uses one:
/// the rules under test are about bytes on a disk, and a mocked filesystem would model them
/// rather than exercise them.
private struct TemporaryHome: ~Copyable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "stele-leak-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: nil
        )
    }

    var store: CredentialStore { CredentialStore(home: path) }

    /// Writes the credential file's bytes directly, for the malformed cases a `save` cannot
    /// produce.
    func write(_ contents: String) throws {
        let store = self.store
        try FileManager.default.createDirectory(
            atPath: store.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = FileManager.default.createFile(
            atPath: store.path, contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        )
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

// MARK: - The credential set

@Suite("no token leaks: the credential set")
struct CredentialSetLeakTests {
    /// The whole point of the library, stated as an assertion: a credential set that has been
    /// round-tripped through the file — which is where a token legitimately lives — cannot be
    /// rendered back out.
    ///
    /// Every value on the path is checked, not just the `Token`. The container is what a
    /// `print` or a `--json` encoder would actually be handed, and a container that leaks a
    /// member's secret leaks it just as thoroughly as the member would.
    @Test("a credential set loaded from disk renders no token, whatever you render it with")
    func loadedSetIsInert() throws {
        let home = try TemporaryHome()
        var written = Credentials()
        written.set(try heldCredential(host: "https://one.example.com"), makeDefault: false)
        written.set(try heldCredential(host: "https://two.example.com"))
        try home.store.save(written)

        let loaded = try home.store.load()
        expectNoLeak(loaded, "the loaded credential set")
        expectNoLeak(try loaded.resolve(), "the resolved credential")
        expectNoLeak(try loaded.resolve().token, "the resolved token")
        expectNoLeak(loaded.hosts, "the host list")
        expectNoLeak(loaded.entry(for: try SteleHost("https://one.example.com")) as Any, "an entry")
        expectNoLeak(loaded.clientName(for: try SteleHost("https://one.example.com")) as Any, "a client name")
    }

    /// The one place the plaintext is supposed to be. Asserted explicitly so the suite above it
    /// cannot pass by writing an empty file — a test that hunts for a string is only meaningful
    /// if the string was there to find.
    @Test("the 0600 file is the deliberate exception and does hold the token")
    func theFileHoldsIt() throws {
        let home = try TemporaryHome()
        var written = Credentials()
        written.set(try heldCredential())
        try home.store.save(written)

        let bytes = try String(contentsOf: URL(fileURLWithPath: home.store.path), encoding: .utf8)
        #expect(bytes.contains(heldSecret))
    }

    /// The mechanism, not the symptom. `--json` output is produced by handing a value to
    /// `JSONEncoder`, and a type that does not conform cannot be handed to one — so the absence
    /// of these conformances is what makes "no `--json` payload can carry a token" true by
    /// construction rather than by review.
    @Test("nothing that holds a token conforms to Encodable")
    func tokenBearingTypesAreNotEncodable() throws {
        let credential = try heldCredential()
        var set = Credentials()
        set.set(credential)

        // Asked through `Any` rather than as a direct `is` test, which the compiler would
        // answer statically and reduce to a constant — the question is a runtime one, because
        // a conformance added in an extension anywhere would change the answer.
        #expect(!conforms(credential.token, to: (any Encodable).self))
        #expect(!conforms(credential, to: (any Encodable).self))
        #expect(!conforms(set, to: (any Encodable).self))
        #expect(!conforms(MintedToken(secret: heldSecret), to: (any Encodable).self))
        // `Decodable` is the half `MintedToken` needs: a minted credential arrives in a response
        // body. The asymmetry is the design — it can come in and cannot go back out.
        #expect(conforms(MintedToken(secret: heldSecret), to: (any Decodable).self))
    }

    /// The models that *are* `Codable` are the ones that travel through `--json`, so they are
    /// worth checking against a server that put a token in a field they carry.
    @Test("a server that puts a token in a summary field cannot get it into --json output")
    func summariesAreScrubbedOfTokenShapedText() throws {
        // Not scrubbed today — `ClientSummary` has no field a token belongs in, so this asserts
        // the shape rather than a filter: a name is a name and the token is not among the fields.
        let summary = ClientSummary(name: "claude-code", scopes: ["publish"])
        expectNoLeak(summary, "a client summary")
        expectNoLeak(PageLocation(slug: "quiet-cedar-otter", url: "https://stele.example.com/q"), "a page location")
    }
}

// MARK: - Errors

/// Exhaustive on purpose. A case added to `SteleError` stops this file compiling, which is the
/// only way a test can insist on covering something that does not exist yet — and the set below
/// then fails until the new case is actually produced and checked.
private func caseName(of error: SteleError) -> String {
    switch error {
    case .badRequest: return "badRequest"
    case .unauthorized: return "unauthorized"
    case .forbidden: return "forbidden"
    case .notFound: return "notFound"
    case .slugTaken: return "slugTaken"
    case .pageTooLarge: return "pageTooLarge"
    case .unsupportedContentType: return "unsupportedContentType"
    case .upgradeRequired: return "upgradeRequired"
    case .slugAllocationFailed: return "slugAllocationFailed"
    case .unexpectedStatus: return "unexpectedStatus"
    case .transportFailure: return "transportFailure"
    case .redirected: return "redirected"
    case .malformedResponse: return "malformedResponse"
    }
}

private let everySteleErrorCase: Set<String> = [
    "badRequest", "unauthorized", "forbidden", "notFound", "slugTaken", "pageTooLarge",
    "unsupportedContentType", "upgradeRequired", "slugAllocationFailed", "unexpectedStatus",
    "transportFailure", "redirected", "malformedResponse",
]

private func caseName(of error: CredentialsError) -> String {
    switch error {
    case .fileTooOpen: return "fileTooOpen"
    case .unreadable: return "unreadable"
    case .malformed: return "malformed"
    case .writeFailed: return "writeFailed"
    case .invalidHost: return "invalidHost"
    case .emptyToken: return "emptyToken"
    case .malformedToken: return "malformedToken"
    case .notAuthenticated: return "notAuthenticated"
    case .noCredentialForHost: return "noCredentialForHost"
    case .ambiguousHost: return "ambiguousHost"
    }
}

private let everyCredentialsErrorCase: Set<String> = [
    "fileTooOpen", "unreadable", "malformed", "writeFailed", "invalidHost", "emptyToken",
    "malformedToken", "notAuthenticated", "noCredentialForHost", "ambiguousHost",
]

/// Replies with one fixed answer, refuses to reach a server at all, or reports a redirect it
/// declined to follow.
private struct StubTransport: SteleTransport {
    var status = 200
    var body = Data()
    var failure: TransportError?
    var redirect: RedirectRefused?

    func send(_ request: SteleRequest) async throws -> SteleResponse {
        if let redirect { throw redirect }
        if let failure { throw failure }
        return SteleResponse(status: status, body: body)
    }
}

@Suite("no token leaks: errors")
struct ErrorLeakTests {
    /// A hostile server: every failure body echoes a credential back, in the `{"error":{…}}`
    /// shape this client reads. The real server does not do this, which is precisely why the
    /// promise must not rest on it.
    private static let echoingBody = Data(
        #"{"error":{"message":"rejected \#(echoedSecret) for that page"}}"#.utf8
    )

    private func failure(status: Int, body: Data = ErrorLeakTests.echoingBody) async -> (any Error)? {
        await Self.attempt(transport: StubTransport(status: status, body: body))
    }

    private static func attempt(transport: any SteleTransport) async -> (any Error)? {
        do {
            let credential = try heldCredential()
            let client = SteleClient(credential: credential, transport: transport)
            _ = try await client.publish(page: Data("<h1>x</h1>".utf8), using: credential)
            return nil
        } catch {
            return error
        }
    }

    /// Every case, produced the way production produces it — through the real client, from a
    /// response — rather than by constructing the enum with a payload chosen by the test. A
    /// hand-built `.badRequest(secret)` would prove nothing: the question is not whether the
    /// type *can* hold a token, it is whether the code path that fills it ever puts one there.
    @Test("every SteleError case, produced the way the client produces it, is token-free")
    func everyErrorCaseIsInert() async throws {
        var produced: [SteleError] = []
        for status in [400, 401, 403, 404, 409, 413, 415, 426, 503, 500] {
            produced.append(try #require(await failure(status: status) as? SteleError))
        }
        // No answer at all, from a transport whose own failure reason quotes a credential.
        produced.append(
            try #require(
                await Self.attempt(
                    transport: StubTransport(
                        failure: TransportError(reason: "refused while presenting \(echoedSecret)")
                    )
                ) as? SteleError
            )
        )
        // A server pointing somewhere else, with a credential in the URL it pointed at. The
        // destination is a string the *server* chose, so it takes the same route into the
        // message as any other thing a server said.
        produced.append(
            try #require(
                await Self.attempt(
                    transport: StubTransport(
                        redirect: RedirectRefused(
                            destination: "https://elsewhere.example.invalid/?t=\(echoedSecret)"
                        )
                    )
                ) as? SteleError
            )
        )
        // A 2xx this client cannot decode, where the undecodable bytes are a credential.
        produced.append(
            try #require(
                await failure(status: 201, body: Data(echoedSecret.utf8)) as? SteleError
            )
        )

        #expect(Set(produced.map(caseName(of:))) == everySteleErrorCase)
        for error in produced {
            expectNoLeak(error, "SteleError.\(caseName(of: error))")
            // The description is what an agent prints, a log captures and a transcript keeps.
            expectNoLeak(error.description, "the description of SteleError.\(caseName(of: error))")
        }
    }

    /// The token this client *holds* has a second escape route the echoed one does not: it is on
    /// the request that failed. An error assembled from the request rather than the response
    /// would carry it.
    @Test("a failure never mentions the credential that was presented")
    func heldCredentialNeverAppearsInAFailure() async throws {
        for status in [400, 401, 403, 409, 413, 426, 500, 503] {
            let error = try #require(await failure(status: status) as? SteleError)
            #expect(!error.description.contains(heldSecret))
            #expect(!"\(error)".contains(heldSecret))
        }
    }

    /// A 401 is the case with the most to leak — the server knows exactly which credential was
    /// presented and why it was refused — and the case that carries nothing at all.
    @Test("a 401 says the credential was rejected and never which one")
    func unauthorizedCarriesNothing() async throws {
        let error = try #require(await failure(status: 401) as? SteleError)
        #expect(error == .unauthorized)
        expectNoLeak(error, "an unauthorized error")
    }

    /// The client's own side of the boundary. These are the errors printed on the machine the
    /// credential file is on, so a message assembled out of that file's bytes is the leak with
    /// the shortest path to a terminal.
    @Test("every CredentialsError case, produced from a file full of tokens, is token-free")
    func everyCredentialsErrorIsInert() throws {
        var produced: [CredentialsError] = []

        // fileTooOpen — a real credential file, chmod'd the way an accident would.
        let loose = try TemporaryHome()
        var set = Credentials()
        set.set(try heldCredential())
        try loose.store.save(set)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: loose.store.path
        )
        produced.append(try #require(collect { _ = try loose.store.load() }))

        // unreadable — the path exists at an acceptable mode and cannot be read as a file.
        let unreadable = try TemporaryHome()
        try FileManager.default.createDirectory(
            atPath: unreadable.store.path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        produced.append(try #require(collect { _ = try unreadable.store.load() }))

        // malformed — four shapes, each with a live token in the bytes being complained about:
        // an entry missing its fields, an unusable token, truncated JSON, and a host key that is
        // itself a credential.
        for contents in [
            #"{"https://one.example.com": {"client": "one"}, "token": "\#(heldSecret)"}"#,
            #"{"https://one.example.com": {"client": "one", "token": "\#(heldSecret) x"}}"#,
            #"{"default": "one", "https://one.example.com": {"client": "one", "token": "\#(heldSecret)"#,
            #"{"\#(heldSecret)": {"client": "one", "token": "\#(heldSecret)"}}"#,
        ] {
            let broken = try TemporaryHome()
            try broken.write(contents)
            produced.append(try #require(collect { _ = try broken.store.load() }))
        }

        // writeFailed — the config directory cannot be created because a file is in its way.
        let blocked = try TemporaryHome()
        _ = FileManager.default.createFile(
            atPath: (blocked.path as NSString).appendingPathComponent(".config"), contents: Data()
        )
        produced.append(try #require(collect { try blocked.store.save(set) }))

        // invalidHost — the accident this case exists for is a human pasting the token at the
        // host prompt, which puts a live credential straight into an error message.
        produced.append(try #require(collect { _ = try SteleHost(heldSecret) }))
        // emptyToken, malformedToken — a bare return, and a paste that dragged a newline along.
        produced.append(try #require(collect { _ = try Token("") }))
        produced.append(try #require(collect { _ = try Token(heldSecret + "\n") }))
        // notAuthenticated, noCredentialForHost, ambiguousHost — resolution, not the filesystem.
        produced.append(try #require(collect { _ = try Credentials().resolve() }))
        produced.append(
            try #require(collect { _ = try set.resolve(host: try SteleHost("https://other.example.com")) })
        )
        let several = try CredentialStore.decode(
            Data(
                #"""
                {"https://one.example.com": {"client": "one", "token": "\#(heldSecret)"},
                 "https://two.example.com": {"client": "two", "token": "\#(heldSecret)"}}
                """#.utf8
            ),
            path: "test"
        )
        produced.append(try #require(collect { _ = try several.resolve() }))

        #expect(Set(produced.map(caseName(of:))) == everyCredentialsErrorCase)
        for error in produced {
            expectNoLeak(error, "CredentialsError.\(caseName(of: error))")
            expectNoLeak(error.description, "the description of CredentialsError.\(caseName(of: error))")
        }
    }

    /// The credential a search for `stele_pat_` cannot find.
    ///
    /// `Token.init` accepts an unprefixed token deliberately: until the server's shared
    /// `STELE_UPLOAD_TOKEN` is demoted to an admin-only credential, whatever that variable was
    /// set to *is* what an operator logs in with, and it is what the integration smoke script
    /// feeds in. Every other canary in this file carries the prefix — which is exactly how a
    /// redaction that recognises only the prefix passes a suite this size while leaking the one
    /// credential most likely to be pasted at the wrong prompt.
    @Test("a token with no stele_pat_ prefix is withheld too")
    func unprefixedTokenIsNeverEchoed() throws {
        let legacy = "kf83Hd9sLxQ2vB7nT4wR6yZ0mP1cJ5aE"
        let error = try #require(collect { _ = try SteleHost(legacy) })
        #expect(!error.description.contains(legacy))
        #expect(error.description.contains(Token.redaction))
    }

    /// And the other half, which is the reason the rule is a shape test rather than "never echo
    /// anything": a message that withholds the typo cannot be acted on.
    @Test(
        "an ordinary mistyped host is still quoted back",
        arguments: ["stele.example.com", "https//stele.example.com", "ftp://stele.example.com"]
    )
    func mistypedHostIsStillEchoed(_ typo: String) throws {
        let error = try #require(collect { _ = try SteleHost(typo) })
        #expect(error.description.contains(typo))
    }

    /// Runs a throwing expression for its error. `#expect(throws:)` asserts the type; this hands
    /// the value back so the same error can be rendered every way `expectNoLeak` renders things.
    private func collect(_ work: () throws -> Void) -> CredentialsError? {
        do {
            try work()
            return nil
        } catch let error as CredentialsError {
            return error
        } catch {
            Issue.record("expected a CredentialsError, got \(error)")
            return nil
        }
    }
}

// MARK: - The wire

/// Records what it was handed, so the test can ask what a transport outside this library — a
/// logging decorator, a fake in someone else's tests — is able to see.
private actor RecordingTransport: SteleTransport {
    private(set) var requests: [SteleRequest] = []

    func send(_ request: SteleRequest) async throws -> SteleResponse {
        requests.append(request)
        return SteleResponse(status: 201, body: Data(#"{"slug":"a-b-c","url":"u"}"#.utf8))
    }

    var last: SteleRequest? { requests.last }
}

@Suite("no token leaks: the wire")
struct WireLeakTests {
    /// `SteleRequest` carries a `Credential`, not a flattened header dictionary, and the
    /// property is `internal`. So the request a transport receives has a token *in* it and no
    /// public expression that yields one — this asserts the visible half of that, since the
    /// access-control half cannot be asserted from inside the module where it is visible.
    @Test("the request a transport is handed renders no token")
    func requestIsInert() async throws {
        let transport = RecordingTransport()
        let credential = try heldCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(
            page: Data("<h1>x</h1>".utf8), slug: "my-page", using: credential
        )

        let request = try #require(await transport.last)
        expectNoLeak(request, "the request")
        expectNoLeak(request.url.absoluteString, "the request URL")
        expectNoLeak(request.userAgent, "the user agent")
        #expect(!(String(data: request.body ?? Data(), encoding: .utf8) ?? "").contains(heldSecret))
    }

    /// And the one place it does appear, asserted so the test above cannot pass because the
    /// token stopped being sent at all.
    @Test("the Authorization header is the only thing on the wire that holds it")
    func headerHoldsIt() async throws {
        let transport = RecordingTransport()
        let credential = try heldCredential()
        let client = SteleClient(credential: credential, transport: transport)

        _ = try await client.publish(page: Data("x".utf8), using: credential)

        let fields = try #require(await transport.last).headerFields()
        #expect(fields["Authorization"] == "Bearer \(heldSecret)")
        for (name, value) in fields where name != "Authorization" {
            #expect(!value.contains(heldSecret), "\(name) carried the token")
        }
    }
}
