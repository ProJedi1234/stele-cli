import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A stele deployment, in the canonical form the credential file is keyed by.
///
/// Keying by a *normalised* string rather than by whatever the user typed is what makes
/// `stele auth login --host https://stele.example.com/` and a later
/// `stele publish --host https://stele.example.com` the same deployment. Without it the second
/// invocation reports "no credential for that host" while the file plainly contains one, which
/// is the kind of bug that gets diagnosed as "the token stopped working".
public struct SteleHost: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// `scheme://host[:port]` — lowercased scheme and host, no trailing slash, no path.
    public let value: String

    public var description: String { value }

    /// Normalises a host the user typed.
    ///
    /// A bare `stele.example.com` is rejected rather than defaulted to `https://`: this string
    /// becomes a dictionary key that a credential is filed under, and silently choosing a
    /// scheme would file `http` and `https` against the same deployment under two keys, or the
    /// same key under two schemes, depending on which way the default fell.
    ///
    /// The rejected value is scrubbed before it becomes the error's payload, because the most
    /// likely way to land here is a human pasting the token at `login`'s host prompt — one line
    /// above the token prompt, on the machine the credential is for. Echoing it back would put a
    /// live credential on the terminal, in the scrollback and in whatever transcript is running,
    /// which is the exact accident this tool exists to prevent. `scrubbedEcho` rather than
    /// `scrub`, because the token that gets pasted here is as likely to be the server's shared
    /// upload token, which carries no prefix for `scrub` to recognise.
    public init(_ raw: String) throws(CredentialsError) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { throw .invalidHost(Redaction.scrubbedEcho(raw)) }

        var canonical = "\(scheme)://\(host)"
        // Only a non-default port survives. `https://h:443` and `https://h` are one deployment
        // and must not become two keys.
        if let port = components.port, !(scheme == "http" && port == 80),
           !(scheme == "https" && port == 443) {
            canonical += ":\(port)"
        }
        self.value = canonical
    }

    /// Builds a URL under this host. `path` is expected to start with `/`.
    public func url(path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    public static func < (lhs: SteleHost, rhs: SteleHost) -> Bool { lhs.value < rhs.value }
}

/// One deployment's stored credential: which host, who we are there, and the token — the last
/// of which no accessor on this type will give you as a string.
///
/// Deliberately not `Codable`. `Credentials` serialises it by hand through `Token`'s internal
/// accessor, so there is no conformance sitting on the type waiting to be picked up by a
/// `--json` encoder in the executable.
public struct Credential: Sendable, Equatable {
    public let host: SteleHost
    /// The client name recorded at login, so `auth status` can answer offline. The server's
    /// answer is authoritative; this is the cached label, not a claim of current validity.
    public let clientName: String
    public let token: Token

    public init(host: SteleHost, clientName: String, token: Token) {
        self.host = host
        self.clientName = clientName
        self.token = token
    }
}

/// Everything that can go wrong on the client's own side of the boundary — the credential
/// file, its permissions, and choosing which host an invocation is for.
///
/// Separate from `SteleError`, which is the server's side. The split is not ceremony: these
/// are the errors a user can fix without the network being involved, and every description
/// below names the command that fixes it.
public enum CredentialsError: Error, Equatable, CustomStringConvertible {
    /// The file exists but its mode lets someone other than the owner read or write it.
    case fileTooOpen(path: String, mode: UInt16)
    case unreadable(path: String, reason: String)
    case malformed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case invalidHost(String)
    case emptyToken
    case malformedToken
    /// No credential is stored at all.
    case notAuthenticated
    case noCredentialForHost(SteleHost)
    /// Several hosts are stored and nothing says which one this invocation meant.
    case ambiguousHost([SteleHost])

    public var description: String {
        switch self {
        case .fileTooOpen(let path, let mode):
            // Mirrors ssh's refusal, in its shape and in its reasoning: a credential readable
            // by other users on the machine is not a credential, and continuing past that with
            // a warning teaches people to ignore the warning.
            return """
                permissions \(Self.octal(mode)) for '\(path)' are too open — the file is \
                accessible by users other than its owner, and stele refuses to read a \
                credential in that state. Fix it with: chmod 600 \(path)
                """
        case .unreadable(let path, let reason):
            return "could not read '\(path)': \(reason)"
        case .malformed(let path, let reason):
            return """
                '\(path)' is not a valid stele credential file: \(reason). Fix the file, or \
                remove it and run `stele auth login` again.
                """
        case .writeFailed(let path, let reason):
            return "could not write '\(path)': \(reason)"
        case .invalidHost(let raw):
            return """
                '\(raw)' is not a usable host. Give a full base URL including the scheme, \
                for example https://stele.example.com
                """
        case .emptyToken:
            return "no token was entered."
        case .malformedToken:
            return """
                that token contains characters a credential cannot hold — it is probably \
                truncated, or picked up a line break on the way in. Paste it again.
                """
        case .notAuthenticated:
            return "no stored credential. Ask the user to run `stele auth login`."
        case .noCredentialForHost(let host):
            return """
                no stored credential for \(host). Ask the user to run \
                `stele auth login --host \(host)`.
                """
        case .ambiguousHost(let hosts):
            return """
                several hosts are stored (\(hosts.map(\.value).joined(separator: ", "))) and \
                none is marked as the default. Pass --host, or run `stele auth login --host \
                <url>` again to set one as the default.
                """
        }
    }

    /// `0600`-style rendering, because that is how the mode is written in every message and
    /// every `chmod` the user is about to type.
    static func octal(_ mode: UInt16) -> String {
        String(format: "%04o", mode)
    }
}

/// The parsed contents of `credentials.json`: hosts to credentials, plus which one is meant
/// when the command line does not say.
///
/// A value type with no filesystem in it, so host resolution — the part with actual rules in
/// it — is a pure function that tests can drive without a temp directory.
public struct Credentials: Sendable, Equatable {
    /// The key `default` holds the default-host marker rather than a credential. A host can
    /// never collide with it: `SteleHost` requires a scheme, so every other key contains `://`.
    static let defaultHostKey = "default"

    private var entries: [SteleHost: Entry]
    /// Which host commands mean when several are stored and `--host` was not given.
    public private(set) var defaultHost: SteleHost?

    struct Entry: Sendable, Equatable {
        var clientName: String
        var token: Token
    }

    public init() {
        self.entries = [:]
        self.defaultHost = nil
    }

    init(entries: [SteleHost: Entry], defaultHost: SteleHost?) {
        self.entries = entries
        self.defaultHost = defaultHost
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Stored hosts, in a stable order so listing output does not reshuffle between runs.
    public var hosts: [SteleHost] { entries.keys.sorted() }

    public func clientName(for host: SteleHost) -> String? { entries[host]?.clientName }

    /// The stored entry, token included. `internal`, because `Entry` holds a `Token` and this
    /// is how `CredentialStore.encode` reaches it — the executable target sees only
    /// `clientName(for:)` and `resolve(host:)`.
    func entry(for host: SteleHost) -> Entry? { entries[host] }

    /// Which host this invocation is for, and the credential filed under it.
    ///
    /// The three rules, in the order they are tried:
    ///
    /// 1. `--host` wins, and must have a credential — falling back to another host because the
    ///    named one is unknown would publish to a deployment the user did not ask for.
    /// 2. Exactly one stored host needs no marker and no flag. This is the common case, and
    ///    requiring a `default` key for it would be ceremony.
    /// 3. Several hosts: the `default` marker breaks the tie, and its absence is an error
    ///    rather than a guess. Picking the alphabetically first, or the most recent, would
    ///    make the destination of `stele publish` depend on something invisible.
    ///
    /// There is no environment-variable step anywhere in that list, which is the point of the
    /// project on the client side: an env var that can name the host is an env var that will
    /// eventually be asked to carry the token too.
    public func resolve(host override: SteleHost? = nil) throws(CredentialsError) -> Credential {
        if let override {
            guard let entry = entries[override] else { throw .noCredentialForHost(override) }
            return Credential(host: override, clientName: entry.clientName, token: entry.token)
        }
        guard !entries.isEmpty else { throw .notAuthenticated }
        if entries.count == 1, let (host, entry) = entries.first {
            return Credential(host: host, clientName: entry.clientName, token: entry.token)
        }
        guard let defaultHost, let entry = entries[defaultHost] else {
            throw .ambiguousHost(hosts)
        }
        return Credential(host: defaultHost, clientName: entry.clientName, token: entry.token)
    }

    /// Files a credential, replacing any credential already stored for that host.
    ///
    /// `makeDefault` defaults to true because the interactive path — a human running
    /// `stele auth login` — has just told us which deployment they care about, and the
    /// alternative is a second command to say the thing they clearly meant. It stays a
    /// parameter so a caller adding a second deployment non-interactively can decline.
    ///
    /// Declining still leaves a default behind when there was none, so a file written only by
    /// this method is never ambiguous: the first deployment logged into keeps the marker until
    /// something says otherwise. `resolve`'s ambiguity case is therefore reachable only from a
    /// hand-edited file — which is a state worth handling, since the file is documented and
    /// people edit it.
    public mutating func set(_ credential: Credential, makeDefault: Bool = true) {
        entries[credential.host] = Entry(
            clientName: credential.clientName, token: credential.token
        )
        if makeDefault || defaultHost == nil { defaultHost = credential.host }
    }

    /// Forgets a host's credential. Returns false if there was nothing stored for it, so
    /// `auth logout` can tell "removed" from "there was nothing there".
    @discardableResult
    public mutating func remove(host: SteleHost) -> Bool {
        let existed = entries.removeValue(forKey: host) != nil
        // A default pointing at a host that is no longer stored would turn every later
        // command into `noCredentialForHost` for a host the user never names.
        if defaultHost == host { defaultHost = entries.count == 1 ? entries.keys.first : nil }
        return existed
    }
}

/// Reads and writes `~/.config/stele/credentials.json`.
///
/// `home` is a parameter rather than a global read so the tests can point the whole store at a
/// temp directory and exercise the permission rules against a real filesystem — the only way
/// to test them honestly, since the rule is about `st_mode` and not about anything we control.
/// Its default calls `NSHomeDirectory()`, which is this library's *one* environment read, and
/// it is at a call-site default where a test can displace it, not buried in a method body.
///
/// There is no `XDG_CONFIG_HOME` support, deliberately. "The CLI reads no environment
/// variables" is a claim worth being able to make without an asterisk, and a relocatable
/// credential path is also a way to point an agent at a file the user did not write.
public struct CredentialStore: Sendable {
    /// `~/.config/stele`.
    public let directory: String
    /// `~/.config/stele/credentials.json`.
    public let path: String

    public init(home: String = NSHomeDirectory()) {
        self.directory = (home as NSString).appendingPathComponent(".config/stele")
        self.path = (directory as NSString).appendingPathComponent("credentials.json")
    }

    /// The stored credentials, or an empty document when the file does not exist yet.
    ///
    /// An absent file is not an error: it is the state a fresh machine is in, and the useful
    /// message for that comes from `resolve` ("run `stele auth login`"), not from a stat.
    public func load() throws(CredentialsError) -> Credentials {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return Credentials() }

        // Resolved before it is stat'ed, and named in the message that follows.
        // `attributesOfItem` does not follow symlinks, so it reports the *link's* own mode — and
        // a symlink is `0777` by construction. A credentials file symlinked out of a dotfiles
        // repository, which is an ordinary way to keep one, would therefore be refused forever:
        // the printed remedy is `chmod 600 <path>`, `chmod` follows the link and changes the
        // target, the link stays `0777`, and the advice loops. The mode that matters is the real
        // file's, and so is the path to put in front of the user.
        //
        // Only when the last component is actually a link. Intermediate ones need no help —
        // `stat` walks those itself — and resolving unconditionally would rewrite every path in
        // every message on a platform where a parent happens to be symlinked (`/tmp` on macOS),
        // which would make the messages harder to match against what the user typed.
        let isSymbolicLink = (try? manager.destinationOfSymbolicLink(atPath: path)) != nil
        let resolved = isSymbolicLink ? (path as NSString).resolvingSymlinksInPath : path

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: resolved)
        } catch {
            throw .unreadable(path: resolved, reason: error.localizedDescription)
        }

        // The permission check happens before the bytes are read, so a world-readable file is
        // refused rather than parsed-then-refused. It also runs on every load rather than only
        // on the first: a `chmod` after login is exactly the accident this is here to catch.
        if let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value {
            let mode = mode & 0o7777
            // Any group or other bit, not just read. A file another user can *write* is worse
            // than one they can read — they choose the token, and the CLI presents it.
            if mode & 0o077 != 0 {
                throw .fileTooOpen(path: resolved, mode: mode)
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw .unreadable(path: path, reason: error.localizedDescription)
        }

        return try Self.decode(data, path: path)
    }

    /// Writes the document back, with the directory `0700` and the file `0600`.
    ///
    /// Written to a sibling temp file and renamed over the target. `rename(2)` is atomic, so a
    /// crash or a concurrent read can only ever see the whole old file or the whole new one —
    /// never a truncated one, which for a credential file means an agent mid-publish reading a
    /// half-written token and reporting a mysterious 401. The temp file is created `0600`
    /// before anything is written into it, so the plaintext never exists at a looser mode even
    /// momentarily.
    public func save(_ credentials: Credentials) throws(CredentialsError) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .writeFailed(path: directory, reason: error.localizedDescription)
        }
        // `createDirectory` only applies attributes to directories it creates, so an existing
        // `~/.config/stele` keeps whatever mode it had. Tighten it either way.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)

        let data: Data
        do {
            data = try Self.encode(credentials)
        } catch {
            throw .writeFailed(path: path, reason: "\(error)")
        }

        let temporary = path + ".new"
        guard manager.createFile(
            atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]
        ) else {
            throw .writeFailed(path: temporary, reason: "could not create the file")
        }
        // `createFile` leaves an *existing* file's mode alone, and a leftover `.new` from an
        // interrupted write is exactly when that matters.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)

        guard rename(temporary, path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(atPath: temporary)
            throw .writeFailed(path: path, reason: reason)
        }
    }

    /// Load and resolve in one step — what every command that talks to a server starts with.
    public func credential(host override: SteleHost? = nil) throws(CredentialsError) -> Credential {
        try load().resolve(host: override)
    }

    // MARK: - Serialisation

    /// The file's JSON shape, hand-rolled because it is heterogeneous: host keys map to
    /// objects and `default` maps to a string.
    ///
    /// ```json
    /// {
    ///   "default": "https://stele.example.com",
    ///   "https://stele.example.com": { "client": "claude-code", "token": "stele_pat_…" }
    /// }
    /// ```
    ///
    /// Flat rather than `{"hosts": {…}, "default": …}` because the file is something a human
    /// occasionally opens, and one level of nesting for a single-deployment install is noise.
    /// It is also the shape the plan specifies, and the file is a contract with the user's
    /// text editor once it exists.
    static func decode(_ data: Data, path: String) throws(CredentialsError) -> Credentials {
        /// Every reason below is assembled out of the file's own bytes — a key it read, or a
        /// parser's `localizedDescription` quoting the text it choked on — and those bytes are a
        /// credential file. So each one goes through the scrubber on its way into the error,
        /// rather than relying on this function never happening to include the token: this is
        /// the message most likely to be printed on the machine the credential lives on.
        func malformed(_ reason: String) -> CredentialsError {
            .malformed(path: path, reason: Redaction.scrub(reason))
        }

        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw malformed("the top level is not an object")
            }
            object = parsed
        } catch let error as CredentialsError {
            throw error
        } catch {
            throw malformed(error.localizedDescription)
        }

        var entries: [SteleHost: Credentials.Entry] = [:]
        /// Which key each host came from, so a second key naming the same deployment can be
        /// reported against the first. `[String: Any]` has no order, so without this the file
        /// would resolve to whichever spelling the iteration happened to reach last — a
        /// credential that can differ between two runs over identical bytes.
        var keysByHost: [SteleHost: String] = [:]
        var defaultRaw: String?

        for (key, value) in object {
            if key == Credentials.defaultHostKey {
                guard let raw = value as? String else {
                    throw malformed("'default' is not a host string")
                }
                defaultRaw = raw
                continue
            }
            guard let fields = value as? [String: Any],
                  let client = fields["client"] as? String,
                  let token = fields["token"] as? String
            else {
                // Names the key and never the value: this is the one place in the library
                // where a message is assembled from bytes that include a token.
                throw malformed("the entry for '\(key)' has no 'client' and 'token'")
            }
            guard let host = try? SteleHost(key) else {
                throw malformed("'\(Redaction.scrubbedEcho(key))' is not a host URL")
            }
            // Two spellings of one deployment — `https://h` and `https://h:443`, or two casings
            // — normalise onto the same key, and the file gives no way to say which credential
            // is meant. Refused rather than resolved arbitrarily: this file is documented as
            // something a human edits, and "which token gets used" is not a question to answer
            // by dictionary order.
            if let existing = keysByHost[host] {
                throw malformed("""
                    '\(Redaction.scrubbedEcho(key))' and '\(Redaction.scrubbedEcho(existing))' \
                    are both \(host), and nothing says which credential wins — keep one of them
                    """)
            }
            guard let token = try? Token(token) else {
                throw malformed("the token for '\(Redaction.scrubbedEcho(key))' is not a usable token")
            }
            keysByHost[host] = key
            entries[host] = Credentials.Entry(clientName: client, token: token)
        }

        // A `default` naming a host with no entry is dropped rather than rejected: the file
        // still holds usable credentials, and `resolve` reports the ambiguity in terms the
        // user can act on. Refusing to load would make a stale marker lock them out entirely.
        var defaultHost: SteleHost?
        if let defaultRaw {
            guard let parsed = try? SteleHost(defaultRaw) else {
                throw malformed("'default' is not a host URL")
            }
            defaultHost = entries[parsed] != nil ? parsed : nil
        }
        return Credentials(entries: entries, defaultHost: defaultHost)
    }

    static func encode(_ credentials: Credentials) throws -> Data {
        var object: [String: Any] = [:]
        for host in credentials.hosts {
            guard let entry = credentials.entry(for: host) else { continue }
            // `storedRepresentation` is the internal accessor on `Token`; this line and the
            // `Authorization` header are the only two readers of a token's plaintext.
            object[host.value] = [
                "client": entry.clientName, "token": entry.token.storedRepresentation,
            ]
        }
        // Only written when it disambiguates something. A `default` key in a file with one
        // host is a second fact to keep in sync with the first for no benefit.
        if let defaultHost = credentials.defaultHost, credentials.hosts.count > 1 {
            object[Credentials.defaultHostKey] = defaultHost.value
        }
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }
}

