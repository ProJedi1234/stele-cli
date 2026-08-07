import ArgumentParser
import Foundation
import SteleKit

/// The `stele` command tree.
///
/// The executable target holds ArgumentParser and every `print`; the decisions live in
/// `SteleKit`. That split is what makes `--json` a formatting choice rather than a second code
/// path, and it is what lets the tests cover behaviour without spawning a process.
///
/// `AsyncParsableCommand` rather than `ParsableCommand`: every subcommand that talks to a
/// server is `async`, and ArgumentParser only awaits a subcommand's `run()` when the *root* is
/// async too. Getting this wrong compiles and then silently runs the synchronous overload.
@main
struct Stele: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stele",
        abstract: "Publish HTML pages to a stele server.",
        discussion: """
            The upload credential lives in a 0600 file written by `stele auth login`, never in \
            the environment and never in an argument — argv is visible in `ps` and lands in \
            shell history. An agent runs `stele publish`; it never sees the token.

            \(Exit.helpTable)
            """,
        // Interpolated, not retyped: `--version` and the `User-Agent` the server version-gates
        // on have to be the same string.
        version: SteleVersion.current,
        subcommands: [
            AuthCommand.self,
            PublishCommand.self,
            UpdateCommand.self,
            AmendCommand.self,
            SkillCommand.self,
            AdminCommand.self,
        ]
    )
}

/// Thrown for expected failures — ArgumentParser prints these without a stack trace or usage
/// dump, which is exactly what an agent should see.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Options every subcommand shares.
///
/// Two of them and no more, deliberately. `--host` is the only thing an environment variable
/// would have been asked to carry on this client, and the credential file answers it instead;
/// `--json` is the machine contract. Anything else belongs to the subcommand that needs it.
struct GlobalOptions: ParsableArguments {
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Base URL of the stele deployment, e.g. https://stele.example.com.",
            discussion: """
                Optional when the credential file holds exactly one host, or when one of \
                several is marked as the default. There is no STELE_HOST — see the README.
                """,
            valueName: "url"
        ),
        completion: Completions.hosts
    )
    var host: String?

    @Flag(name: .long, help: "Emit JSON instead of formatted output.")
    var json = false

    /// The credential file this invocation reads and writes.
    ///
    /// Constructed rather than injected: `CredentialStore`'s own `home` parameter is where the
    /// seam for tests lives, and duplicating it as a hidden `--credentials` flag would be a way
    /// to point an agent at a file the user did not write.
    var store: CredentialStore { CredentialStore() }

    /// `--host`, normalised, or nil when the invocation did not name one.
    ///
    /// Parsed here rather than at each call site so a typo'd URL fails the same way — and with
    /// the same message — on every command.
    func hostOverride() throws -> SteleHost? {
        guard let host else { return nil }
        return try SteleHost(host)
    }

    /// The credential this invocation should present, resolved by `--host`, by there being only
    /// one, or by the `default` marker. Throws a `CredentialsError` naming the fix.
    func credential() throws -> Credential {
        try store.credential(host: hostOverride())
    }

    /// Where an *unauthenticated* call goes: `--host` if given, otherwise the host the stored
    /// credential is filed under. `stele skill` is the only caller — the skill document is a
    /// read, but which deployment's skill you want is still a question the credential file
    /// happens to answer.
    func readHost() throws -> SteleHost {
        if let override = try hostOverride() { return override }
        do {
            return try credential().host
        } catch {
            // The credential errors all end in "run `stele auth login`", which is true but not
            // the whole truth for a read: `--host` answers this without authenticating at all,
            // and a caller told only to log in would go and ask a human for nothing.
            throw Failure("\(error) Or name one directly with --host <url> — this read needs no credential.")
        }
    }

    /// JSON output is a machine contract: never styled, regardless of terminal.
    var style: Style { json ? Style(depth: .none) : Style.detect() }
}

/// The shape every subcommand takes.
///
/// The `run()` default is the whole point: it is the single place that turns a thrown error
/// into a printed message and an exit code, so no command can accidentally report a `409` as a
/// bare `1`, and no command has to remember to. Commands implement `execute()` and throw.
protocol SteleCommand: AsyncParsableCommand {
    var options: GlobalOptions { get }
    func execute() async throws
}

extension SteleCommand {
    func run() async throws {
        do {
            try await execute()
        } catch let code as ExitCode {
            // Already carries its own status and has already been reported.
            throw code
        } catch let clean as CleanExit {
            throw clean
        } catch {
            throw Exit.report(error)
        }
    }
}
