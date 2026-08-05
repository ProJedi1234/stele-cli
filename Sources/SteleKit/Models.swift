import Foundation

/// Where a published page lives — the body both writes answer with.
///
/// `url` is the server's own rendering rather than something assembled here from the host and
/// the slug. The deployment knows its public base URL and this client only knows the address
/// it was pointed at, which are not always the same string once anything sits in front of it.
public struct PageLocation: Codable, Sendable, Equatable {
    public let slug: String
    public let url: String

    public init(slug: String, url: String) {
        self.slug = slug
        self.url = url
    }
}

/// A credential as the server describes it — everything except the token, which the server no
/// longer has either: it keeps a SHA-256 and nothing more.
///
/// `scopes` stays `[String]` rather than an array of a closed enum on purpose. The plan adds
/// `delete` to the server's vocabulary the day `DELETE` lands, with no migration and no
/// coordinated release, and a client that failed to decode a credential because it met a scope
/// it had not heard of would break `auth status` on exactly the machines that most need to run
/// it. `Scope` below names the ones this client knows how to explain.
public struct ClientSummary: Codable, Sendable, Equatable {
    public let name: String
    public let scopes: [String]
    public let createdAt: Date?
    public let lastUsedAt: Date?
    public let expiresAt: Date?
    public let revokedAt: Date?

    public init(
        name: String,
        scopes: [String],
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil,
        expiresAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.name = name
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    public var isRevoked: Bool { revokedAt != nil }

    /// Whether the credential has passed its expiry. Takes the moment as a parameter, matching
    /// the server's own `Client.isUsable(at:)`, so a renderer can be tested without a clock.
    public func isExpired(at moment: Date = Date()) -> Bool {
        expiresAt.map { $0 <= moment } ?? false
    }

    public func isUsable(at moment: Date = Date()) -> Bool {
        !isRevoked && !isExpired(at: moment)
    }

    public func has(_ scope: Scope) -> Bool { scopes.contains(scope.rawValue) }
}

/// The scopes this client knows the meaning of.
///
/// Not a validation list — an unknown scope from the server is carried through untouched. This
/// exists so a command can ask "does this credential have `admin`?" without a bare string
/// literal at the call site, and so the wording in a 403 can name the scope that was missing.
public enum Scope: String, Codable, Sendable, CaseIterable {
    /// What every agent credential gets, and all it gets: `POST /pages` and `PUT /pages/:slug`.
    case publish
    /// The operator's scope: minting, listing and revoking credentials.
    case admin
}

/// A newly minted credential: the record, and the plaintext that exists exactly once.
///
/// `Decodable` but not `Encodable`, so the token cannot be re-serialised by anything in this
/// library. The executable prints it once, deliberately, by reaching for `token.secret`.
public struct MintedClient: Decodable, Sendable {
    public let client: ClientSummary
    public let token: MintedToken

    public init(client: ClientSummary, token: MintedToken) {
        self.client = client
        self.token = token
    }
}

extension JSONDecoder {
    /// The decoder every response goes through.
    ///
    /// Dates are ISO 8601 with or without fractional seconds. `.iso8601` alone rejects the
    /// fractional form, which is what a Postgres `timestamptz` renders as through most JSON
    /// encoders — so the strict strategy would fail against real data while passing against
    /// any fixture written by hand. Accepting both costs one closure and removes a whole class
    /// of "works in tests, 500s against the server" mismatch.
    static var stele: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Constructed per call rather than held in a `static let`: `ISO8601DateFormatter`
            // is a non-Sendable class, and a shared mutable formatter is the classic data race
            // in a Foundation codebase. Decoding happens a handful of times per invocation.
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "expected an ISO 8601 timestamp, got '\(text)'"
            )
        }
        return decoder
    }
}
