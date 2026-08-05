import Foundation
import Testing

@testable import SteleKit

/// The promise this library exists to keep: a token reaches the `Authorization` header and the
/// `0600` file, and nothing else.
///
/// Most of the enforcement is structural — `Token`'s plaintext accessors are `internal`, so the
/// executable target that owns every `print` has no expression that yields it — and structure
/// is not something a test can assert from inside the module, where those members are visible.
/// What these tests cover is the part that access control cannot: the reflection paths, which
/// are available to any caller and would happily print the secret if the conformances below
/// were ever dropped.
@Suite("secrecy")
struct SecrecyTests {
    private static let secret = "stele_pat_s3cret-value_AA"

    @Test("interpolating a token prints the redaction, not the secret")
    func interpolationIsRedacted() throws {
        let token = try Token(Self.secret)
        #expect("\(token)" == Token.redaction)
        #expect(!"\(token)".contains(Self.secret))
    }

    /// `debugPrint`, `String(reflecting:)` and the default `dump` all route here.
    @Test("the debug description is redacted too")
    func debugDescriptionIsRedacted() throws {
        let token = try Token(Self.secret)
        #expect(String(reflecting: token) == Token.redaction)
    }

    /// `dump` walks children rather than asking for a description, so the mirror has to be
    /// empty as well — this is the path that would otherwise print `secret: "stele_pat_…"`.
    @Test("dumping a credential shows no children")
    func mirrorHasNoChildren() throws {
        let token = try Token(Self.secret)
        #expect(Mirror(reflecting: token).children.isEmpty)

        var dumped = ""
        dump(
            Credential(
                host: try SteleHost("https://stele.example.com"),
                clientName: "claude-code",
                token: token
            ),
            to: &dumped
        )
        #expect(!dumped.contains(Self.secret))
    }

    /// A freshly minted credential is the one thing that must be printable, and printing it
    /// still has to be a deliberate `.secret` at the call site rather than an interpolation
    /// someone wrote without thinking about it.
    @Test("a minted token reveals its secret only through an explicit accessor")
    func mintedTokenIsExplicit() {
        let minted = MintedToken(secret: Self.secret)
        #expect("\(minted)" == Token.redaction)
        #expect(Mirror(reflecting: minted).children.isEmpty)
        #expect(minted.secret == Self.secret)
    }

    /// A header value assembled anywhere but here would mean a second place holding the
    /// plaintext, and the scheme and the secret would exist as separate strings in between.
    @Test("the authorization header is the only assembled form of the token")
    func authorizationHeader() throws {
        let token = try Token(Self.secret)
        #expect(token.authorizationHeaderValue == "Bearer \(Self.secret)")
    }

    /// A CR or LF in a pasted token would end the `Authorization` header and let the rest be
    /// read as another one. Rejected at construction, so no later code has to think about it.
    @Test(
        "a token with characters a header cannot carry is refused",
        arguments: ["", " ", "abc\r\nX-Evil: 1", "abc\n", "tok en", "tok\u{00A0}en"]
    )
    func refusesUnsafeTokens(_ raw: String) {
        #expect(throws: CredentialsError.self) { try Token(raw) }
    }

    /// Defence in depth on the one string in an error that came from somewhere else. The
    /// server does not echo tokens; this library's promise should not depend on that.
    @Test("a token-shaped string in a server message is scrubbed")
    func serverMessagesAreScrubbed() {
        let body = Data(#"{"error":{"message":"rejected stele_pat_AbC-1_2 for that page"}}"#.utf8)
        let detail = SteleClient.detail(from: body)
        #expect(detail == "rejected \(Token.redaction) for that page")
    }

    @Test("scrubbing leaves ordinary prose alone")
    func scrubbingIsNarrow() {
        #expect(Redaction.scrub("the slug 'a-b' is already taken.") == "the slug 'a-b' is already taken.")
    }
}
