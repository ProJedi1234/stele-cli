import ArgumentParser
import Foundation
import SteleKit

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage the stored credential.",
        discussion: """
            `login` is the one command in this tool meant for a human: it signs in with GitHub \
            in a browser the user opens themselves, checks what the server minted and writes it \
            0600. Nothing else here, or anywhere else in the tree, will show you the token \
            again.
            """,
        subcommands: [LoginCommand.self, StatusCommand.self, LogoutCommand.self],
        defaultSubcommand: StatusCommand.self
    )
}

// MARK: - login

/// Records a credential for a deployment, after checking the server agrees it is one.
///
/// The ordinary way in is a GitHub sign-in: this asks the server to start a device flow, prints
/// the code and the URL for a person to open, and waits. The credential it walks away with is
/// minted by the server and is publish-only. Nothing secret is typed at this terminal on that
/// path — no stele token, and no GitHub token either. The OAuth app's client ID lives on the
/// server and the access token GitHub issues is consumed inside one server request, so the only
/// credential this machine ever holds is the one it is entitled to hold.
///
/// The pasted-token path is still here, and is not a legacy branch. It is what `--admin` uses,
/// because a sign-in mints `publish` and can never produce the operator credential that flag
/// asks for; and it is the fallback for a deployment that has not configured GitHub sign-in,
/// which answers the start route with a refusal. Without it, `stele auth login` would have no
/// answer at all on a server whose owners have not adopted the flow — including the first login
/// against a fresh one, which is how the bootstrap token gets spent.
///
/// Verifying before writing is what stops a typo becoming a puzzle. A token stored unverified
/// looks perfectly healthy in the file and fails at the next `stele publish`, which is a 401 an
/// agent then reports to the user hours later; verifying here turns that into an error the
/// person who typed it is still standing in front of. It is also what the sign-in path does
/// with what it was handed, for a second reason: a credential minted a moment ago and refused
/// by `whoami` is one worth finding out about before it reaches the file.
///
/// Verifying is also what makes the second rule possible: an `admin` token is not stored, it is
/// *spent*. The server's answer says which kind of credential was pasted, and an operator's one
/// is the thing that mints credentials rather than a thing to keep on the machine an agent
/// publishes from. See `LoginDecision`, which holds the rule itself.
struct LoginCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign in to a stele deployment and store the credential it mints.",
        discussion: """
            Signs in with GitHub: the server starts a device flow and this prints a code and a \
            URL to open. Nothing is opened for you — the URL is printed and you decide where to \
            open it, which is the only thing that works over SSH and in a container. The \
            credential the server mints carries `publish`, and no GitHub token ever reaches \
            this machine.

            A deployment that has not configured GitHub sign-in falls back to a token read from \
            the terminal with echo off. It is never an argument and never an environment \
            variable: argv shows up in `ps` and in shell history, and shell history is \
            something an agent reads.

            On that path, paste an operator token and this mints a publish-only credential for \
            this machine and stores that instead — the admin token is used for one request and \
            never written to disk. Pass --admin to keep it, which is what the workstation you \
            run `stele admin clients` from wants; that flag skips the sign-in, since a sign-in \
            only ever mints `publish`.

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

                Skips the GitHub sign-in and prompts for a token, because signing in mints \
                `publish` and only `publish`: there is no sign-in that ends in the credential \
                this flag asks to keep.
                """
        )
    )
    var admin = false

    func execute() async throws {
        var credentials = try options.store.load()
        let host = try resolveHost(existing: credentials)
        let client = SteleClient(host: host)

        // `--admin` asks for an operator credential, and a sign-in cannot produce one: what the
        // exchange mints carries `publish` and only `publish`. Starting a flow whose answer is
        // the wrong scope would waste a person's trip to a browser to arrive somewhere the flag
        // already said was wrong, so it goes straight to the prompt.
        if !admin, let bundle = try await beginSignIn(on: host, client: client) {
            try await completeSignIn(bundle, on: host, client: client, into: &credentials)
            return
        }

        try await loginWithAPastedToken(on: host, client: client, into: &credentials)
    }

    /// Asks the server to start a GitHub sign-in and tells the user what to do with it.
    ///
    /// Nil means this deployment does not offer one — the caller falls back to a pasted token.
    /// A refusal is how that arrives and it is not a mistake in the reading: the server answers
    /// an unconfigured client ID with the same bytes it refuses a sign-in with, deliberately, so
    /// that a prober cannot tell a deployment with no OAuth app from one whose allowlist they
    /// are not on. This side is not a prober and can simply try the other door.
    private func beginSignIn(on host: SteleHost, client: SteleClient) async throws
        -> DeviceCodeBundle?
    {
        let bundle: DeviceCodeBundle
        do {
            bundle = try await client.startDeviceSignIn()
        } catch let error as SteleError {
            guard case .unauthorized = error else { throw error }
            // Said before the prompt appears, because a person who ran this expecting a browser
            // and got a token prompt deserves to know which of the two happened. Hedged on
            // purpose: all this side knows is that the deployment declined, and the server does
            // not say why — the caller here is a human at their own terminal rather than a
            // prober, but the answer is the same bytes either way.
            Terminal.error(
                options.style.dim(
                    "\(host) did not offer a GitHub sign-in — asking for a token instead."
                )
            )
            return nil
        }

        // stderr, like every other prompt: `stele auth login --json` still emits exactly one
        // document on stdout, and this is the question rather than the answer.
        let style = options.style
        Terminal.error("sign in to \(style.accent(host.value)) with GitHub.")
        Terminal.error("  open \(style.accent(bundle.verificationURI))")
        Terminal.error("  enter the code \(style.bold(bundle.userCode))")
        Terminal.error(
            style.dim("waiting for GitHub — this window can be left open. Ctrl-C to stop.")
        )
        return bundle
    }

    /// Waits for the sign-in to be approved, then verifies and files what it minted.
    ///
    /// The credential arrives already minted, so from `verifyCredential` onwards this is the
    /// same path a pasted token takes — the same `whoami` check and the same one line that
    /// writes to disk. `LoginDecision` is deliberately not consulted: its whole subject is which
    /// kind of credential was *pasted*, and there is nothing to decide about one the server just
    /// minted to be publish-only.
    private func completeSignIn(
        _ bundle: DeviceCodeBundle,
        on host: SteleHost,
        client: SteleClient,
        into credentials: inout Credentials
    ) async throws {
        switch try await DeviceSignIn(client: client).complete(bundle) {
        case .refused:
            // One sentence for several facts, because one refusal is all the server said. It
            // covers a cancelled authorisation, an account that is not an owner here, and a
            // deployment with no owners configured — and it names the only move that is open
            // either way rather than guessing which of them happened.
            throw Failure(
                "sign-in failed or was cancelled — run `stele auth login` to try again."
            )
        case .expired:
            // Split from the refusal because it is the one outcome that is nobody's decision:
            // the code simply timed out, usually because the browser was never opened.
            throw Failure(
                "the code expired before it was approved — run `stele auth login` to try again."
            )
        case .minted(let minted):
            let token: Token
            do {
                token = try minted.token.inCustody()
            } catch {
                throw Self.signInLost(
                    minted.client.name,
                    on: host,
                    "the token it sent back is not one a credential can hold."
                )
            }
            let credential = Credential(host: host, clientName: minted.client.name, token: token)
            let summary: ClientSummary
            do {
                summary = try await client.verifyCredential(credential)
            } catch {
                throw Self.signInLost(minted.client.name, on: host, "\(error)")
            }
            try store(token, as: summary, on: host, origin: .signedIn, into: &credentials)
        }
    }

    /// The original path: a token typed at the terminal, verified, and then either stored or
    /// spent on minting the credential that is stored instead.
    private func loginWithAPastedToken(
        on host: SteleHost,
        client: SteleClient,
        into credentials: inout Credentials
    ) async throws {
        let raw = try Prompt().secret("token for \(host): ")
        // `Token` refuses an empty or header-unsafe value here, before anything is sent and
        // long before anything is written.
        let token = try Token(raw)

        // The name is not known until the server answers; this placeholder exists for exactly
        // one HTTP request and is replaced before anything reaches the disk.
        let provisional = Credential(host: host, clientName: "", token: token)
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
            try store(token, as: summary, on: host, origin: .pasted, into: &credentials)

        case .storeAdmin(let shared):
            warnAboutKeepingAdmin(shared: shared, host: host)
            try store(token, as: summary, on: host, origin: .pasted, into: &credentials)

        case .mint(let suggestedName, let shared):
            let minted = try await mint(
                suggesting: suggestedName,
                explaining: summary,
                shared: shared,
                using: provisional,
                on: host,
                client: client
            )
            // Converted here rather than inline at the `store` call, so the failure lands in
            // this `catch` instead of escaping as a bare `malformedToken`. The bad state is the
            // same one `store` guards against — a row created on the server whose plaintext is
            // gone — and it deserves the same message, since the operator's next move is the
            // same too.
            let token: Token
            do {
                token = try minted.token.inCustody()
            } catch {
                throw Self.orphaned(
                    minted.client.name,
                    on: host,
                    "the token it sent back is not one a credential can hold."
                )
            }
            try store(
                token, as: minted.client, on: host, origin: .mintedByOperator, into: &credentials
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
        for attempt in 0..<Self.nameAttempts {
            do {
                // Sent as typed. The alphabet is the server's `Client.validated(name:)` and a
                // copy of it here would be a second source of truth — a `400` names the rule it
                // broke, which is more than this side could say.
                return try await client.createClient(
                    name: name, scopes: [.publish], expiresIn: nil, using: operatorCredential
                )
            } catch let error as SteleError {
                guard case .nameTaken = error else { throw error }
                // Only worth resolving while there is a create left to use the answer. On the
                // last turn the resolution would still prompt — and a `y` there revokes a live
                // credential, whatever was publishing under that name stops, and then the loop
                // falls out and mints nothing. Better to fail with the name still working.
                guard attempt < Self.nameAttempts - 1 else { break }
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
        //
        // Revoked rows are skipped, and that is the whole point of the filter: the server's
        // name uniqueness is a *partial* index over the live rows, so a name that has been
        // rotated before appears several times in this listing. The listing is oldest-first,
        // so the unfiltered answer is the retired credential — which would put months-old
        // dates in front of the operator as though they described the thing about to be
        // destroyed. `last` rather than `first` for the same reason, belt and braces: the
        // newest live row is the one holding the name.
        let existing = try? await client.listClients(using: operatorCredential)
            .last { $0.name == name && !$0.isRevoked }
        let described = existing.map {
            " (created \(Format.moment($0.createdAt)), last used \(Format.moment($0.lastUsedAt)))"
        } ?? ""

        Terminal.error(
            style.warn("a credential named \(name) is already live on \(host)\(described).")
        )

        guard try Prompt().confirm("revoke it and mint a replacement?") else {
            let replacement = try Prompt().line("another name for this machine: ")
            // No default is offered here, because the only obvious name is the one that just
            // collided — so Return means nothing, and this says so. Sending the empty string
            // would spend the attempt on a `400` from the server's name validator, arriving
            // after the operator has already answered three prompts.
            guard !replacement.isEmpty else {
                throw Failure(
                    "no name was entered. Nothing was minted — run `stele auth login` again."
                )
            }
            return replacement
        }

        let revoked = try await client.revokeClient(name: name, using: operatorCredential)
        Terminal.error(style.dim("revoked \(revoked.name)."))
        return name
    }

    /// Where the credential being filed came from.
    ///
    /// Three things depend on it and they are kept together rather than as three booleans at the
    /// call sites: the `minted` field `--json` promises, the reassurance printed under a
    /// successful login, and what an operator is told if the credential is live on the server
    /// and its only plaintext could not be kept.
    private enum Origin {
        /// Verified and stored as it was typed. Nothing was minted, so nothing can be orphaned.
        case pasted
        /// Minted with an operator token that was spent for the purpose and never written down.
        case mintedByOperator
        /// Minted by the server at the end of a GitHub sign-in.
        case signedIn

        /// Whether this login *created* the credential it is storing — which is also the
        /// assurance that whatever was pasted, if anything was, reached no file.
        var minted: Bool {
            switch self {
            case .pasted: return false
            case .mintedByOperator, .signedIn: return true
            }
        }

        /// The one thing worth saying that the rest of the output does not already say, or
        /// nothing. Printed on the branch where it is true rather than as a footer.
        var reassurance: String? {
            switch self {
            case .pasted: return nil
            case .mintedByOperator: return "the admin token was not written to disk."
            case .signedIn: return "no GitHub token ever reached this machine."
            }
        }
    }

    /// Files the credential and reports it.
    ///
    /// One path for every way in, so the reporting cannot drift between them and so there is
    /// exactly one line in this command that writes a token to disk.
    private func store(
        _ token: Token,
        as summary: ClientSummary,
        on host: SteleHost,
        origin: Origin,
        into credentials: inout Credentials
    ) throws {
        credentials.set(
            Credential(host: host, clientName: summary.name, token: token),
            makeDefault: !noDefault
        )

        do {
            try options.store.save(credentials)
        } catch {
            switch origin {
            case .pasted: throw error
            case .mintedByOperator:
                throw Self.orphaned(
                    summary.name, on: host, "could not write the credential file: \(error)."
                )
            case .signedIn:
                throw Self.signInLost(
                    summary.name, on: host, "could not write the credential file: \(error)."
                )
            }
        }

        if options.json {
            Terminal.out(
                try Format.json(
                    AuthStatus(
                        host: host,
                        summary: summary,
                        path: options.store.path,
                        minted: origin.minted
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
        if let reassurance = origin.reassurance {
            // The reassurance the whole command exists to be able to give, and it says a
            // different true thing depending on how the credential was got.
            Terminal.out(style.dim(reassurance))
        }
    }

    /// A credential that is live on the server and whose only copy of the plaintext is gone.
    ///
    /// The server keeps a hash and cannot reissue it, so what is left is a credential nobody can
    /// use and nobody knows to revoke. Two routes reach this state — a token the file would not
    /// take, and a token this side could not hold — and both need the same thing from the
    /// operator, so the message is written once rather than twice into drift.
    private static func orphaned(
        _ name: String, on host: SteleHost, _ problem: String
    ) -> Failure {
        Failure(
            "minted '\(name)' on \(host), but \(problem) That credential is live and its token "
                + "is now lost — revoke it with `stele admin clients revoke \(name)`."
        )
    }

    /// A credential a sign-in minted, whose plaintext this side then failed to keep.
    ///
    /// The same bad state `orphaned` describes and a different remedy, which is why it is a
    /// second message rather than a shared one. There the operator holds the token that can
    /// revoke the stranded credential; here they hold nothing at all — a sign-in mints
    /// `publish`, which cannot revoke anything. What recovers it is signing in again: the
    /// exchange retires whatever live credential holds the login's name before minting the
    /// replacement, so the stranded row is cleaned up by the retry rather than by an operator.
    private static func signInLost(
        _ name: String, on host: SteleHost, _ problem: String
    ) -> Failure {
        Failure(
            "signed in to \(host) and the server minted '\(name)', but \(problem) Nothing was "
                + "written. Run `stele auth login` again — the next sign-in retires that "
                + "credential and mints another under the same name."
        )
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
        var rows: [(String, String)] = [
            ("host", style.accent(host.value)),
            ("client", style.bold(summary.name)),
        ]
        // Only when there is one. A deployment that has not adopted GitHub sign-in — or one
        // predating it, which does not answer the key at all — would otherwise print a row that
        // says nothing on every machine it is run on, and `client` already carries the name.
        // Worth showing when it exists because it need not match: the credential is addressed
        // by a lowercased name and attributed to the spelling GitHub reports.
        if let login = summary.githubLogin {
            rows.append(("github", login))
        }
        rows += [
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
    /// The GitHub login this credential was minted for, when one was. Absent otherwise, the way
    /// `expiresAt` is — this is a field the server either reports or does not, and unlike
    /// `minted` below there is no answer this side could invent for it.
    let githubLogin: String?
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
        self.githubLogin = summary.githubLogin
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
