import ArgumentParser
import Foundation
import SteleKit

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage the stored credential.",
        discussion: """
            `login` is the one command in this tool meant for a human: it reads the token from \
            a terminal, checks it against the server and writes it 0600. Nothing else here, or \
            anywhere else in the tree, will show you the token again.
            """,
        subcommands: [LoginCommand.self, StatusCommand.self, LogoutCommand.self],
        defaultSubcommand: StatusCommand.self
    )
}

// MARK: - login

/// Records a credential for a deployment, after checking the server agrees it is one.
///
/// Verifying before writing is what stops a typo becoming a puzzle. A token stored unverified
/// looks perfectly healthy in the file and fails at the next `stele publish`, which is a 401 an
/// agent then reports to the user hours later; verifying here turns that into an error the
/// person who typed it is still standing in front of.
struct LoginCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Store a credential for a stele deployment. Prompts on a terminal.",
        discussion: """
            The token is read from the terminal with echo off. It is never an argument and \
            never an environment variable: argv shows up in `ps` and in shell history, and \
            shell history is something an agent reads.

            If stdin is not a TTY this command fails rather than reading it. Agents should ask \
            the user to run this themselves.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Flag(
        name: .long,
        help: "Do not make this the default host. Only meaningful with several deployments."
    )
    var noDefault = false

    func execute() async throws {
        var credentials = try options.store.load()
        let host = try resolveHost(existing: credentials)

        let raw = try Prompt.secret("token for \(host): ")
        // `Token` refuses an empty or header-unsafe value here, before anything is sent and
        // long before anything is written.
        let token = try Token(raw)

        // The name is not known until the server answers; this placeholder exists for exactly
        // one HTTP request and is replaced by `summary.name` before anything reaches the disk.
        let provisional = Credential(host: host, clientName: "", token: token)
        let summary = try await SteleClient(host: host).verifyCredential(provisional)

        credentials.set(
            Credential(host: host, clientName: summary.name, token: token),
            makeDefault: !noDefault
        )
        try options.store.save(credentials)

        if options.json {
            Terminal.out(try Format.json(AuthStatus(host: host, summary: summary, path: options.store.path)))
            return
        }

        let style = options.style
        Terminal.out(
            "authenticated as \(style.bold(summary.name)) on \(style.accent(host.value)) — "
                + "scopes: \(summary.scopes.joined(separator: ", "))"
        )
        if let expiry = summary.expiresAt {
            Terminal.out(style.dim("expires \(Format.moment(expiry))"))
        }
        Terminal.out(style.dim("stored 0600 in \(Format.tildify(options.store.path))"))
    }

    /// Which deployment this login is for.
    ///
    /// `--host` wins. Failing that, re-authenticating the one deployment already in the file is
    /// the overwhelmingly common case — a token expired, a human is replacing it — and asking
    /// for a URL that is already on disk would be ceremony. Only a genuinely fresh machine
    /// prompts, and it prompts rather than guessing a scheme, for the reason `SteleHost` gives:
    /// this string becomes the key a credential is filed under.
    private func resolveHost(existing: Credentials) throws -> SteleHost {
        if let override = try options.hostOverride() { return override }
        if existing.hosts.count == 1, let only = existing.hosts.first { return only }
        if let known = existing.defaultHost { return known }
        guard existing.isEmpty else {
            throw Failure(
                "several deployments are stored and none is the default — say which one with "
                    + "--host <url>."
            )
        }
        return try SteleHost(try Prompt.line("host (e.g. https://stele.example.com): "))
    }
}

// MARK: - status

/// What credential this machine holds, and whether the server still accepts it.
///
/// The first thing an agent runs, and the reason it asks the server rather than reading the
/// file: a credential revoked yesterday still sits on disk looking healthy, and the question
/// worth answering is whether publishing will work *now*.
struct StatusCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the stored credential's host, client name, scopes and expiry.",
        discussion: """
            Never prints the token — there is no flag that makes it, and no code path in this \
            binary that could. Exits 2 when there is no usable credential here and 3 when the \
            server rejects the one there is; both mean a human has to run `stele auth login`.
            """
    )

    @OptionGroup var options: GlobalOptions

    func execute() async throws {
        let credential = try options.credential()
        let client = SteleClient(credential: credential)

        do {
            let summary = try await client.verifyCredential(credential)
            try report(host: credential.host, summary: summary)
        } catch let error as SteleError {
            guard case .transportFailure = error else { throw error }
            // The server is unreachable, not disagreeing. What is on disk is still worth
            // printing — it answers "which deployment am I pointed at" — but it is reported as
            // unverified and the exit code says the check did not happen.
            try reportOffline(credential: credential, reason: error)
            throw ExitCode(Exit.unreachable)
        }
    }

    private func report(host: SteleHost, summary: ClientSummary) throws {
        if options.json {
            Terminal.out(
                try Format.json(AuthStatus(host: host, summary: summary, path: options.store.path))
            )
            return
        }
        let style = options.style
        let rows: [(String, String)] = [
            ("host", style.accent(host.value)),
            ("client", style.bold(summary.name)),
            ("scopes", summary.scopes.isEmpty ? "—" : summary.scopes.joined(separator: ", ")),
            ("expires", summary.expiresAt.map(Format.moment) ?? "never"),
            ("last used", Format.moment(summary.lastUsedAt)),
            ("state", style.state(summary)),
        ]
        for (label, value) in rows {
            Terminal.out("\(style.dim(Format.pad(label, 9)))  \(value)")
        }
        Terminal.out(style.dim("credential  \(Format.tildify(options.store.path))"))
    }

    private func reportOffline(credential: Credential, reason: SteleError) throws {
        if options.json {
            Terminal.out(
                try Format.json(
                    AuthStatus(
                        host: credential.host,
                        // The cached client name from the file, flagged as unverified rather
                        // than presented as the server's answer.
                        summary: ClientSummary(name: credential.clientName, scopes: []),
                        path: options.store.path,
                        verified: false
                    )
                )
            )
        } else {
            let style = options.style
            Terminal.out("\(style.dim(Format.pad("host", 9)))  \(style.accent(credential.host.value))")
            Terminal.out("\(style.dim(Format.pad("client", 9)))  \(style.bold(credential.clientName))")
            Terminal.out("\(style.dim(Format.pad("state", 9)))  \(style.warn("unverified"))")
        }
        Terminal.error("Error: \(reason)")
    }
}

/// The `--json` shape of `auth login` and `auth status`.
///
/// Hand-written rather than `ClientSummary` encoded directly, because the caller needs the host
/// and the file path alongside it — and because writing the shape out by hand is what makes it
/// obvious, to anyone editing it, that there is no field here for a token and no way to add one
/// by accident: `Credential` is not `Codable` and `Token` is neither `Encodable` nor
/// `Decodable`, so a token could not be spliced in here without deliberately unpicking that.
struct AuthStatus: Encodable {
    let host: String
    let client: String
    let scopes: [String]
    let createdAt: Date?
    let lastUsedAt: Date?
    let expiresAt: Date?
    let revokedAt: Date?
    let state: String
    let credentialFile: String
    /// False when the server could not be reached and these are the file's cached values.
    let verified: Bool

    init(host: SteleHost, summary: ClientSummary, path: String, verified: Bool = true) {
        self.host = host.value
        self.client = summary.name
        self.scopes = summary.scopes
        self.createdAt = summary.createdAt
        self.lastUsedAt = summary.lastUsedAt
        self.expiresAt = summary.expiresAt
        self.revokedAt = summary.revokedAt
        self.state = verified ? Format.state(summary) : "unverified"
        self.credentialFile = path
        self.verified = verified
    }
}

// MARK: - logout

struct LogoutCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Remove the stored credential for a host.",
        discussion: """
            Local only. The credential is forgotten here and stays valid on the server — revoke \
            it with `stele admin clients revoke <name>` if it should stop working everywhere.
            """
    )

    @OptionGroup var options: GlobalOptions

    /// The `--json` shape. Two fields, because the caller's question is "is it gone" and
    /// "was there anything there" — and an absent credential is not an error, since logging out
    /// twice should not fail the second time.
    private struct Removal: Encodable {
        let host: String?
        let removed: Bool
    }

    func execute() async throws {
        var credentials = try options.store.load()
        guard !credentials.isEmpty else {
            try report(host: nil, removed: false, message: "no stored credential — nothing to remove")
            return
        }

        // Resolving rather than requiring `--host` keeps the single-deployment case a bare
        // `stele auth logout`, and makes the ambiguous case an error naming the hosts instead
        // of a coin flip over which credential to delete.
        let host = try options.hostOverride() ?? credentials.resolve().host
        let existed = credentials.remove(host: host)
        try options.store.save(credentials)

        try report(
            host: host,
            removed: existed,
            message: existed
                ? "removed the credential for \(options.style.accent(host.value))"
                : "no credential was stored for \(host)"
        )
    }

    private func report(host: SteleHost?, removed: Bool, message: String) throws {
        if options.json {
            Terminal.out(try Format.json(Removal(host: host?.value, removed: removed)))
            return
        }
        Terminal.out(removed ? message : options.style.dim(message))
    }
}
