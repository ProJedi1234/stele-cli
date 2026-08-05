import ArgumentParser
import SteleKit

/// The `stele` command tree.
///
/// The executable target holds ArgumentParser and every `print`; the decisions live in
/// `SteleKit`. That split is what makes `--json` a formatting choice rather than a second code
/// path, and it is what lets the tests cover behaviour without spawning a process.
///
/// Subcommands land in later commits. The scaffold builds and runs on its own so the Makefile,
/// the completion script and CI have something real to exercise from the first commit.
@main
struct Stele: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stele",
        abstract: "Publish HTML pages to a stele server.",
        discussion: """
            The upload credential lives in a 0600 file written by `stele auth login`, never in \
            the environment and never in an argument — argv is visible in `ps` and lands in \
            shell history. An agent runs `stele publish`; it never sees the token.
            """,
        // Interpolated, not retyped: `--version` and the `User-Agent` the server version-gates
        // on have to be the same string.
        version: SteleVersion.current
    )
}
