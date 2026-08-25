import ArgumentParser
import Foundation
import SteleKit

/// Shell completion callbacks.
///
/// `stele --generate-completion-script zsh` bakes the command tree into a script; anything
/// completed from live state is completed by the script spawning `stele` again at TAB time, so
/// these run in a fresh process with no parsed options to consult. That is what
/// `just install-completions` installs, and it needs regenerating when the tree changes, not
/// when your hosts do.
///
/// Nothing here reads a token, and nothing here can: `Credentials` exposes hosts and client
/// names, and the plaintext is behind `internal` accessors in SteleKit. A completion closure is
/// the last place a secret should be able to reach — its output is written into a shell's
/// completion buffer, which is a place values are seen and not audited.
enum Completions {
    /// Deployments the credential file knows about, for `--host`.
    ///
    /// Failures are swallowed into an empty list on purpose. A missing file, or one at
    /// permissions the CLI refuses, is the normal state on a fresh machine — and a TAB press
    /// that printed an error into the middle of a half-typed command line would be a worse
    /// answer than no suggestions.
    static let hosts = CompletionKind.custom { _, _, _ in
        let credentials = (try? CredentialStore().load()) ?? Credentials()
        return credentials.hosts.map { host in
            describe(host.value, credentials.clientName(for: host) ?? "stele deployment")
        }
    }

    /// zsh's `_describe` reads a candidate as `value:description`; bash and fish would take the
    /// whole string as the value. The generated script exports `SAP_SHELL`, which is the only
    /// way a callback can tell which shell is asking.
    private static func describe(_ value: String, _ description: String) -> String {
        ProcessInfo.processInfo.environment["SAP_SHELL"] == "zsh"
            ? "\(value):\(description)" : value
    }
}
