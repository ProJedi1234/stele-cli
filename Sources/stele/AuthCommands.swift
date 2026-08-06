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
///
/// Verifying is also what makes the second rule possible: an `admin` token is not stored, it is
/// *spent*. The server's answer says which kind of credential was pasted, and an operator's one
/// is the thing that mints credentials rather than a thing to keep on the machine an agent
/// publishes from. See `LoginDecision`, which holds the rule itself.
struct LoginCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Store a credential for a stele deployment. Prompts on a terminal.",
        discussion: """
            The token is read from the terminal with echo off. It is never an argument and \
            never an environment variable: argv shows up in `ps` and in shell history, and \
            shell history is something an agent reads.

            Paste an operator token and this mints a publish-only credential for this machine \
            and stores that instead — the admin token is used for one request and never \
            written to disk. Pass --admin to keep it, which is what the workstation you run \
            `stele admin clients` from wants.

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

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Store an operator token as it stands instead of minting a publish-only credential.",
            discussion: """
                For the machine you administer the deployment from. A credential file holds one \
                credential per host, so this machine will hold `admin` instead of `publish` and \
                `stele publish` will stop working on it — the two scopes are disjoint.
                """
        )
    )
    var admin = false

    func execute() async throws {
        var credentials = try options.store.load()
        let host = try resolveHost(existing: credentials)

        let raw = try Prompt().secret("token for \(host): ")
        // `Token` refuses an empty or header-unsafe value here, before anything is sent and
        // long before anything is written.
        let token = try Token(raw)

        // The name is not known until the server answers; this placeholder exists for exactly
        // one HTTP request and is replaced before anything reaches the disk.
        let provisional = Credential(host: host, clientName: "", token: token)
        let client = SteleClient(host: host)
        let summary = try await client.verifyCredential(provisional)

        // The hostname is read here rather than inside `LoginDecision`, for the reason
        // `CredentialStore` takes `home` and `Style.detect` takes its environment: a decision
        // that reads the machine it is running on can only be tested on that machine.
        let decision = LoginDecision.decide(
            summary: summary,
            keepAdmin: admin,
            machineName: ProcessInfo.processInfo.hostName
        )

        switch decision {
        case .store:
            try store(token, as: summary, on: host, minted: false, into: &credentials)

        case .storeAdmin(let shared):
            warnAboutKeepingAdmin(shared: shared, host: host)
            try store(token, as: summary, on: host, minted: false, into: &credentials)

        case .mint(let suggestedName, let shared):
            let minted = try await mint(
                suggesting: suggestedName,
                explaining: summary,
                shared: shared,
                using: provisional,
                on: host,
                client: client
            )
            try store(
                try minted.token.inCustody(),
                as: minted.client,
                on: host,
                minted: true,
                into: &credentials
            )
        }
    }

    /// Mints a publish-only credential for this machine, using the operator token in hand.
    ///
    /// No expiry, deliberately. `admin clients create` offers `--expires-in` because an operator
    /// provisioning a credential for someone else may want one that lapses; a credential this
    /// machine mints for itself, unattended, would lapse into a `401` an agent reports to its
    /// user hours later — and nothing here would be watching for the date.
    private func mint(
        suggesting suggestedName: String,
        explaining summary: ClientSummary,
        shared: Bool,
        using operatorCredential: Credential,
        on host: SteleHost,
        client: SteleClient
    ) async throws -> MintedClient {
        explainTheMint(summary: summary, shared: shared, host: host)
        var name = try Prompt().line("name for this machine", default: suggestedName)

        // Bounded rather than `while true`. Every turn of this loop needs a person to answer a
        // prompt, so it cannot spin on its own — but a revoke that succeeds followed by a create
        // that still collides is a state no amount of asking will get out of, and looping on it
        // would keep asking anyway.
        for _ in 0..<Self.nameAttempts {
            do {
                // Sent as typed. The alphabet is the server's `Client.validated(name:)` and a
                // copy of it here would be a second source of truth — a `400` names the rule it
                // broke, which is more than this side could say.
                return try await client.createClient(
                    name: name, scopes: [.publish], expiresIn: nil, using: operatorCredential
                )
            } catch let error as SteleError {
                guard case .nameTaken = error else { throw error }
                name = try await resolveNameConflict(
                    named: name, using: operatorCredential, on: host, client: client
                )
            }
        }

        throw Failure(
            "gave up after \(Self.nameAttempts) attempts to mint a credential for this machine. "
                + "Check `stele admin clients list` and try again."
        )
    }

    /// How many names one login will try before it stops asking.
    private static let nameAttempts = 5

    /// The name is taken. Offer the rotation, or take another name.
    ///
    /// Rotation is the honest common case — a reinstall, an expiry, a credential that was minted
    /// for this machine months ago — and the operator credential that can do it is in hand at
    /// exactly this moment. It also destroys a live credential, so it is an explicit `y/N` at
    /// the terminal and never the default: whatever is publishing under that name stops
    /// publishing the instant it is revoked, and that may not be this machine.
    private func resolveNameConflict(
        named name: String,
        using operatorCredential: Credential,
        on host: SteleHost,
        client: SteleClient
    ) async throws -> String {
        let style = options.style

        // Best effort, and only to make the question answerable: "last used yesterday" is what
        // tells an operator whether anything is still publishing under this name. A listing that
        // fails costs the dates and not the prompt.
        let existing = try? await client.listClients(using: operatorCredential)
            .first { $0.name == name }
        let described = existing.map {
            " (created \(Format.moment($0.createdAt)), last used \(Format.moment($0.lastUsedAt)))"
        } ?? ""

        Terminal.error(
            style.warn("a credential named \(name) is already live on \(host)\(described).")
        )

        guard try Prompt().confirm("revoke it and mint a replacement?") else {
            return try Prompt().line("another name for this machine: ")
        }

        let revoked = try await client.revokeClient(name: name, using: operatorCredential)
        Terminal.error(style.dim("revoked \(revoked.name)."))
        return name
    }

    /// Files the credential and reports it.
    ///
    /// One path for all three decisions, so the reporting cannot drift between them and so there
    /// is exactly one line in this command that writes a token to disk.
    private func store(
        _ token: Token,
        as summary: ClientSummary,
        on host: SteleHost,
        minted: Bool,
        into credentials: inout Credentials
    ) throws {
        credentials.set(
            Credential(host: host, clientName: summary.name, token: token),
            makeDefault: !noDefault
        )

        do {
            try options.store.save(credentials)
        } catch {
            // A minted credential is live on the server and this was the only copy of its
            // plaintext — the server keeps a hash and cannot reissue it. Failing with the
            // generic write error would leave a credential nobody can use and nobody knows to
            // revoke, so the message carries the name needed to clean it up.
            guard minted else { throw error }
            throw Failure(
                "minted '\(summary.name)' on \(host), but could not write the credential file: "
                    + "\(error) That credential is live and its token is now lost — revoke it "
                    + "with `stele admin clients revoke \(summary.name)`."
            )
        }

        if options.json {
            Terminal.out(
                try Format.json(
                    AuthStatus(
                        host: host, summary: summary, path: options.store.path, minted: minted
                    )
                )
            )
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
        if minted {
            // The reassurance the whole command exists to be able to give, and it is only worth
            // saying where it is true — so it is printed on this branch and not as a footer.
            Terminal.out(style.dim("the admin token was not written to disk."))
        }
    }

    /// Why this command is about to do something the user did not ask for.
    ///
    /// stderr and above the prompt, because it is the reason the next question is being asked.
    /// A person who pasted an operator token and got back a credential called `argos` deserves
    /// to have been told why between the two, rather than to work it out from the output.
    private func explainTheMint(summary: ClientSummary, shared: Bool, host: SteleHost) {
        let style = options.style
        if shared {
            Terminal.error(
                style.warn("that is \(host)'s bootstrap token (\(summary.name)).")
                    + " It is configuration rather than a credential — it stops working when the"
                    + " deployment is redeployed — and it carries `admin`, so storing it here"
                    + " would let anything on this machine mint and revoke credentials."
            )
        } else {
            Terminal.error(
                style.warn("that is an operator credential (\(summary.name), scopes: "
                    + "\(summary.scopes.joined(separator: ", "))).")
                    + " Storing it here would let anything on this machine mint and revoke"
                    + " credentials on \(host)."
            )
        }
        Terminal.error(
            style.dim(
                "Minting a publish-only credential for this machine instead. Pass --admin to "
                    + "store the operator credential as it stands."
            )
        )
    }

    /// What `--admin` costs, said once, on the machine it is being spent on.
    ///
    /// stderr, like every other warning: this is advice attached to an outcome, not the outcome,
    /// and `stele auth login --admin --json` should still emit one JSON document on stdout.
    private func warnAboutKeepingAdmin(shared: Bool, host: SteleHost) {
        let style = options.style
        Terminal.error(
            style.warn("storing an operator credential on this machine.")
                + " Anything that can run stele as this user can now mint and revoke credentials"
                + " on \(host) — and `stele publish` will not work here, since `admin` and"
                + " `publish` are disjoint."
        )
        if shared {
            Terminal.error(
                style.dim(
                    "This is the server's bootstrap token, which is configuration rather than a "
                        + "credential: it stops working the next time the deployment is "
                        + "redeployed or the value is rotated."
                )
            )
        }
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
        return try SteleHost(try Prompt().line("host (e.g. https://stele.example.com): "))
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
    /// True when `auth login` minted this credential rather than storing the token that was
    /// pasted — which is also the assurance that the pasted token reached no file.
    ///
    /// Always present, including on `auth status` where it is always false. A key that appears
    /// only sometimes is a key every reader has to write a branch for, and "did this login mint
    /// something?" is exactly the question a script wrapping this command asks.
    let minted: Bool

    init(
        host: SteleHost,
        summary: ClientSummary,
        path: String,
        verified: Bool = true,
        minted: Bool = false
    ) {
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
        self.minted = minted
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
