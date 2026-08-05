import Foundation

/// A credential held in custody: the bytes are in there, and nothing this library hands you
/// will show them to you.
///
/// The secrecy is structural rather than a convention to remember. `secret` is `private`, and
/// the two places that legitimately need the plaintext — the `Authorization` header and the
/// credential file — reach it through `internal` members. Both are invisible outside SteleKit,
/// so the executable target, which is where every `print` lives, has *no* expression that
/// yields the token as a `String`. A rule enforced by access control cannot be forgotten
/// during a refactor the way "remember not to log this" can.
///
/// Three reflection paths would otherwise route around that:
///
/// - string interpolation and `print`, closed by `description`;
/// - `debugPrint` and `String(reflecting:)`, closed by `debugDescription`;
/// - `dump` and any hand-rolled `Mirror` walk, closed by `customMirror`.
///
/// And `Token` deliberately conforms to neither `Encodable` nor `Decodable`. Encoding is how a
/// secret escapes into `--json` output by accident: someone adds a token to a model that is
/// already `Codable` and the leak ships silently. The credential file needs the plaintext, so
/// it does its own serialisation through the `internal` accessor below — one place, reviewed
/// as the sensitive thing it is, rather than a conformance that travels wherever the type does.
///
/// See `MintedToken` for the single deliberate exception, which exists because a freshly minted
/// credential has no other delivery path.
public struct Token: Sendable, Equatable, Hashable {
    /// Shown wherever the token would otherwise be. Not the empty string: an operator reading
    /// a message needs to see that something was there and was withheld, not wonder whether a
    /// field went missing.
    public static let redaction = "<redacted>"

    /// The prefix the server puts on every credential it mints. Used only by `Redaction` to
    /// recognise a token in text that came from elsewhere — never as a validity check, for the
    /// reason `init(_:)` gives.
    public static let mintedPrefix = "stele_pat_"

    private let secret: String

    /// Wraps a token the user typed, or one read back out of the credential file.
    ///
    /// The character rule is not cosmetic. This string is interpolated into an
    /// `Authorization` header, so a CR or LF in it would end the header and let whatever
    /// follows be read as another one — header injection, from a value a user pasted. Visible
    /// ASCII is exactly the RFC 7230 `token`/`quoted-string` safe range, it covers every
    /// credential this server mints (base64url of 32 bytes behind an ASCII prefix), and it
    /// rejects the whitespace a copy-paste out of a terminal drags along.
    ///
    /// Deliberately does *not* require the `stele_pat_` prefix: until the server's shared
    /// upload token is demoted to an admin-only credential, the thing a user logs in with is
    /// whatever `STELE_UPLOAD_TOKEN` was set to, and a prefix check here would refuse to
    /// authenticate against every deployment that has not upgraded yet.
    public init(_ raw: String) throws(CredentialsError) {
        guard !raw.isEmpty else { throw .emptyToken }
        for scalar in raw.unicodeScalars where !(0x21...0x7E).contains(scalar.value) {
            throw .malformedToken
        }
        self.secret = raw
    }

    /// The full `Authorization` header value, assembled here so no caller ever holds the
    /// scheme and the secret as two separate strings it could log one half of.
    var authorizationHeaderValue: String { "Bearer \(secret)" }

    /// The plaintext, for `Credentials` to write into the `0600` file. `internal` on purpose:
    /// this is the only other member that yields the secret, and it is one grep away.
    var storedRepresentation: String { secret }
}

extension Token: CustomStringConvertible {
    public var description: String { Self.redaction }
}

extension Token: CustomDebugStringConvertible {
    public var debugDescription: String { Self.redaction }
}

extension Token: CustomReflectable {
    /// An empty mirror, so `dump(credential)` and anything walking the value with `Mirror`
    /// see a leaf with no children instead of the stored property.
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// A credential that has just been minted and has to be shown to a human exactly once.
///
/// A separate type from `Token`, not a flag on it, because the two have opposite obligations
/// and the type system should be the thing that keeps them apart: a `Token` must never be
/// printed, and a `MintedToken` must be printed or the credential is lost — the server keeps
/// only a SHA-256 of it and cannot reissue the plaintext.
///
/// `secret` is therefore public, and it is the only public accessor for a token's plaintext in
/// the whole library. It is spelled as an explicit property access rather than a
/// `description`, so revealing it is a visible decision at the call site: interpolating this
/// value prints the redaction, and printing the secret requires typing `.secret`, which is
/// exactly the line a reviewer should stop on.
///
/// Not `Encodable`, for the reason `Token` is not: a `--json` shape that carries the token is
/// the executable's decision to make explicitly, not something a synthesised conformance
/// should make on its behalf.
public struct MintedToken: Sendable, Decodable {
    /// The plaintext, available once. Handing this to anything other than the operator's
    /// terminal is the mistake this library is built to prevent.
    public let secret: String

    public init(secret: String) {
        self.secret = secret
    }

    public init(from decoder: any Decoder) throws {
        self.secret = try decoder.singleValueContainer().decode(String.self)
    }

    /// The same credential, in custody — for `auth login` to store what it just minted
    /// without the plaintext making a second trip through the presentation layer.
    public func inCustody() throws(CredentialsError) -> Token {
        try Token(secret)
    }
}

extension MintedToken: CustomStringConvertible {
    public var description: String { Token.redaction }
}

extension MintedToken: CustomDebugStringConvertible {
    public var debugDescription: String { Token.redaction }
}

extension MintedToken: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// Removes anything shaped like a stele credential from text that came from somewhere else.
///
/// Every server-supplied message passes through this before it can reach a `SteleError`
/// description. The server does not echo tokens today, so this is defence in depth — but the
/// alternative is a claim about *another repository's* behaviour holding this library's core
/// promise up, and that promise should not depend on a remote deployment's error strings.
enum Redaction {
    static func scrub(_ text: String) -> String {
        guard text.contains(Token.mintedPrefix) else { return text }

        var result = ""
        var remainder = Substring(text)
        while let range = remainder.range(of: Token.mintedPrefix) {
            result += remainder[remainder.startIndex..<range.lowerBound]
            result += Token.redaction
            // Consume the prefix and the credential body behind it: base64url is
            // alphanumerics plus `-` and `_`, and the first character outside that set ends
            // the token and resumes ordinary prose.
            var tail = remainder[range.upperBound...]
            while let first = tail.first,
                  first.isLetter || first.isNumber || first == "-" || first == "_" {
                tail = tail.dropFirst()
            }
            remainder = tail
        }
        return result + remainder
    }
}
