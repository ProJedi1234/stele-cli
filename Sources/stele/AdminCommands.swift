import ArgumentParser
import Foundation
import SteleKit

struct AdminCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "admin",
        abstract: "Operator commands. Needs a credential with the `admin` scope.",
        discussion: """
            No agent holds `admin`. That is what makes revocation work: a leaked publish-only \
            credential can deface pages, which is recoverable, but it cannot mint itself a \
            second credential and revoke yours.

            Every command here exits 4 when the credential in use is valid but publish-only.
            """,
        subcommands: [ClientsCommand.self]
    )
}

struct ClientsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clients",
        abstract: "Mint, list and revoke client credentials.",
        subcommands: [
            CreateClientCommand.self, ListClientsCommand.self, RevokeClientCommand.self,
        ],
        defaultSubcommand: ListClientsCommand.self
    )
}

// MARK: - create

/// Mints a credential and shows it once.
///
/// This is the single command in the tree that prints a token, and it has to: the server keeps
/// a SHA-256 and cannot reissue the plaintext, so the value either reaches the operator's
/// terminal now or the credential is lost and has to be minted again. Everything about the
/// output is built around making that one-shot obvious — the token on its own line, and a
/// sentence saying it will not be shown again, before the operator has scrolled past it.
///
/// The plaintext is reached through `MintedToken.secret`, which is the library's only public
/// accessor for a token's bytes and is spelled as an explicit property access precisely so this
/// line is the one a reviewer stops on.
struct CreateClientCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Mint a credential for a client. Prints the token once.",
        discussion: """
            The token is shown exactly once, here, and cannot be recovered afterwards — the \
            server stores only a hash of it. If you lose it, mint another and revoke this one.

            Hand it over by running `stele auth login` on the machine that needs it and pasting \
            it at the prompt. Do not mail it, and do not put it in a file an agent can read.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: ArgumentHelp("A name for the client, e.g. claude-code.", valueName: "name"))
    var name: String

    @Option(
        name: .long,
        parsing: .singleValue,
        help: ArgumentHelp(
            "Scope to grant; repeat for several. Defaults to publish.",
            discussion: "Agents get `publish` and nothing else. `admin` is for an operator.",
            valueName: "scope"
        ),
        completion: .list(Scope.allCases.map(\.rawValue))
    )
    var scopes: [String] = []

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Lifetime, e.g. 90d. Omit for a credential that never expires.",
            valueName: "duration"
        )
    )
    var expiresIn: String?

    func execute() async throws {
        let granted = try resolveScopes()
        let lifetime = try expiresIn.map { raw -> TimeInterval in
            do { return try ExpiryDuration.seconds(from: raw) } catch { throw Failure("\(error)") }
        }

        let credential = try options.credential()
        let minted = try await SteleClient(credential: credential).createClient(
            name: name, scopes: granted, expiresIn: lifetime, using: credential
        )

        if options.json {
            // The one `--json` payload that carries a token, and the reason is the same reason
            // the human output does: there is no second chance to deliver it. Omitting it would
            // make `--json` a quiet way to lose a credential you just created, which is a worse
            // failure than printing it to a stream the operator asked for.
            Terminal.out(try Format.json(MintedClientJSON(minted)))
            return
        }

        let style = options.style
        let expiry = minted.client.expiresAt.map(Format.moment) ?? "never"
        Terminal.out(
            "created \(style.bold(minted.client.name)) — "
                + "scopes: \(minted.client.scopes.joined(separator: ", ")) — expires \(expiry)"
        )
        Terminal.out("")
        Terminal.out("  \(style.accent(minted.token.secret))")
        Terminal.out("")
        Terminal.out(
            style.warn("This token is shown once and cannot be recovered.")
                + " Copy it now; if you lose it, mint another and revoke this one."
        )
        Terminal.out(
            style.dim(
                "Deliver it by running `stele auth login` on the machine that needs it and "
                    + "pasting it at the prompt."
            )
        )
    }

    /// Repeated `--scopes` values, checked against the vocabulary this build knows.
    ///
    /// Unknown values are refused rather than forwarded. The server will grow scopes this
    /// binary has not heard of — `delete` is already planned — and forwarding blind would let a
    /// typo mint a credential with a scope that does nothing, which reads as a working
    /// credential right up until it is used. The cost is a CLI release to grant a new scope,
    /// and the error below says exactly what it accepts today.
    private func resolveScopes() throws -> [Scope] {
        guard !scopes.isEmpty else { return [.publish] }
        return try scopes.map { raw in
            guard let scope = Scope(rawValue: raw) else {
                throw Failure(
                    "'\(raw)' is not a scope this build knows. Accepted: "
                        + Scope.allCases.map(\.rawValue).joined(separator: ", ") + "."
                )
            }
            return scope
        }
    }
}

/// The `--json` body of `admin clients create`.
///
/// Written out by hand, because `MintedClient` is deliberately not `Encodable` and `MintedToken`
/// is not either — a token cannot travel into JSON by a synthesised conformance somebody
/// forgot was there. Getting it into this payload takes writing `.secret` on the line below,
/// which is exactly how visible that decision should be.
struct MintedClientJSON: Encodable {
    let name: String
    let scopes: [String]
    let createdAt: Date?
    let expiresAt: Date?
    let token: String
    /// Spelled out in the payload itself, so a script that logs its own output has been told.
    let note = "This token is not recoverable — the server stores only a hash of it."

    init(_ minted: MintedClient) {
        self.name = minted.client.name
        self.scopes = minted.client.scopes
        self.createdAt = minted.client.createdAt
        self.expiresAt = minted.client.expiresAt
        self.token = minted.token.secret
    }
}

// MARK: - list

struct ListClientsCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every credential the server holds, revoked ones included.",
        discussion: """
            Revoked credentials are listed rather than filtered out: "was this revoked, and \
            when?" is the question this list is opened to answer.
            """,
        aliases: ["ls"]
    )

    @OptionGroup var options: GlobalOptions

    func execute() async throws {
        let credential = try options.credential()
        let clients = try await SteleClient(credential: credential).listClients(using: credential)

        if options.json {
            Terminal.out(try Format.json(clients.map(ClientJSON.init)))
            return
        }

        let style = options.style
        guard !clients.isEmpty else {
            Terminal.out(
                style.dim("no clients — mint one with `stele admin clients create <name>`")
            )
            return
        }

        let nameWidth = max(4, min(28, clients.map(\.name.count).max() ?? 4))
        let scopeWidth = max(
            6, min(24, clients.map { $0.scopes.joined(separator: ",").count }.max() ?? 6)
        )
        Terminal.out(
            style.dim(
                [
                    Format.pad("NAME", nameWidth), Format.pad("SCOPES", scopeWidth),
                    Format.pad("CREATED", 16), Format.pad("LAST USED", 16), "STATE",
                ].joined(separator: "  ")
            )
        )
        for client in clients {
            let row = [
                Format.pad(client.name, nameWidth),
                Format.pad(client.scopes.joined(separator: ","), scopeWidth),
                Format.pad(Format.moment(client.createdAt), 16),
                Format.pad(Format.moment(client.lastUsedAt), 16),
            ].joined(separator: "  ")
            Terminal.out("\(row)  \(style.state(client))")
        }
    }
}

/// `ClientSummary` plus the derived `state` the table shows, so `--json` and the human output
/// answer "is this usable" the same way instead of leaving the caller to recompute it.
struct ClientJSON: Encodable {
    let name: String
    let scopes: [String]
    let createdAt: Date?
    let lastUsedAt: Date?
    let expiresAt: Date?
    let revokedAt: Date?
    let state: String

    init(_ summary: ClientSummary) {
        self.name = summary.name
        self.scopes = summary.scopes
        self.createdAt = summary.createdAt
        self.lastUsedAt = summary.lastUsedAt
        self.expiresAt = summary.expiresAt
        self.revokedAt = summary.revokedAt
        self.state = Format.state(summary)
    }
}

// MARK: - revoke

struct RevokeClientCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Stop a credential working, keeping its record.",
        discussion: """
            Not deletion: the row survives with its revocation time, which is what lets the \
            list say "retired in March" rather than forgetting the credential existed. There is \
            no un-revoke — mint a new credential for that client instead.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: ArgumentHelp("The client name, as `list` shows it.", valueName: "name"))
    var name: String

    func execute() async throws {
        let credential = try options.credential()
        let summary = try await SteleClient(credential: credential).revokeClient(
            name: name, using: credential
        )

        if options.json {
            Terminal.out(try Format.json(ClientJSON(summary)))
            return
        }
        let style = options.style
        Terminal.out(
            "revoked \(style.bold(summary.name)) "
                + style.dim("(last used \(Format.moment(summary.lastUsedAt)))")
        )
    }
}
