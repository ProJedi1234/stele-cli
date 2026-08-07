import Foundation

/// Where a published page lives — the body every write answers with: `publish`, `update` and
/// `amend` alike.
///
/// `url` is the server's own rendering rather than something assembled here from the host and
/// the slug. The deployment knows its public base URL and this client only knows the address
/// it was pointed at, which are not always the same string once anything sits in front of it.
public struct PageLocation: Codable, Sendable, Equatable {
    public let slug: String
    public let url: String

    /// When the page stops being served, or nil for one that is kept until it is deleted.
    ///
    /// Reading this rather than computing it from the `--ttl` that was sent is the point: the
    /// server resolves the deadline against *its* clock at the moment of the request, on
    /// `publish` it applies its own default when the caller expressed no opinion, and on
    /// `update` it reports the deadline the page already had — a number this side never knew.
    ///
    /// `amend` is the one that reads a silent caller the other way round: with no `?ttl=` it
    /// touches nothing and reports the deadline already in force, and with one it reports a
    /// deadline counted from *now* rather than from publication. Either way the answer is here
    /// and nowhere else, which is exactly why no caller should be computing it.
    ///
    /// Nil covers two wire shapes, and they mean the same thing. The server sends an explicit
    /// `null` for a permanent page; a deployment older than page expiry omits the key, and on
    /// that server nothing expires either. Both are honestly "no deadline".
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case slug, url
        /// The server's spelling. One key on the wire in both directions, so the `--json` this
        /// tool prints is the shape it reads.
        case expiresAt = "expires"
    }

    public init(slug: String, url: String, expiresAt: Date? = nil) {
        self.slug = slug
        self.url = url
        self.expiresAt = expiresAt
    }

    /// Hand-written for the one line in the middle, and for the reason the server hand-writes
    /// its own encoder: the synthesised version calls `encodeIfPresent`, which *drops the key*
    /// when there is no deadline — so `stele publish --json` on a permanent page would emit a
    /// blob with no `expires` in it, and whatever read that blob could not tell "this page is
    /// kept" from "this tool has nothing to say about lifetimes". An explicit null says which.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
        try container.encode(url, forKey: .url)
        if let expiresAt {
            try container.encode(expiresAt, forKey: .expiresAt)
        } else {
            try container.encodeNil(forKey: .expiresAt)
        }
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

    /// Whether the server synthesised this credential from `STELE_UPLOAD_TOKEN` rather than
    /// reading it out of a row.
    ///
    /// `Bool?` and not `Bool`, because the field is newer than the deployments that will answer
    /// this call: a server that has never heard of it omits the key, the synthesised decoder
    /// reaches for `decodeIfPresent`, and nil arrives meaning "this server does not say". Nil is
    /// therefore genuinely a third state and not a defaulted `false` — `LoginDecision.isShared`
    /// falls back to the name only when it lands, and prefers this answer whenever there is one.
    public let shared: Bool?

    public init(
        name: String,
        scopes: [String],
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil,
        expiresAt: Date? = nil,
        revokedAt: Date? = nil,
        shared: Bool? = nil
    ) {
        self.name = name
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.shared = shared
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
    /// What every agent credential gets, and all it gets: `POST /pages`, `PUT /pages/:slug` and
    /// `PATCH /pages/:slug` — write, replace, and rename-or-retime. An amendment is a write like
    /// the other two, so it sits under this scope and not behind `admin`.
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
