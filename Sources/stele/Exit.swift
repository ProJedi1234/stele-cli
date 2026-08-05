import ArgumentParser
import Foundation
import SteleKit

/// Exit statuses, and the one place a thrown error becomes a printed message.
///
/// The primary reader of this program is an agent, and an agent branches on `$?` long before it
/// parses prose. So the outcomes that call for *different next steps* get different codes: "ask
/// the user to authenticate" and "pick another slug" and "the server is down" are three
/// different situations and a shared `1` would flatten them into one.
///
/// The codes are deliberately few. One per status the server can return would look thorough and
/// would mostly encode distinctions with the same remedy — `400` and a malformed local file are
/// both "fix the input and do not retry", and they share `1`.
///
/// Nothing in here can print a token: every description below comes from a `CustomStringConvertible`
/// error in SteleKit, and no `SteleError` or `CredentialsError` case carries a credential.
enum Exit {
    /// Anything with no better answer than "read the message": a `400`, an unreadable file, a
    /// server that answered something this client has no advice for. ArgumentParser's own
    /// `ExitCode.failure`, so an error thrown out of `validate()` lands here too.
    static let failure: Int32 = 1

    /// No usable credential *on this machine*: none stored, none for the named host, several
    /// with no default, or a file at permissions the CLI refuses to read. The remedy is always a
    /// human running `stele auth login`, which an agent must not attempt itself.
    static let noCredential: Int32 = 2

    /// `401` — a credential exists and the server refused it. Revoked, expired or unknown; the
    /// server does not say which, and neither do we. Also a human's job to fix.
    static let credentialRejected: Int32 = 3

    /// `403` — valid credential, wrong scope. An agent holds `publish` and has hit an operator
    /// route; retrying, re-authenticating and rewording the request all fail identically.
    static let forbidden: Int32 = 4

    /// `409` — the requested slug is taken. The one failure with an obvious programmatic
    /// remedy: choose another `--slug`, or drop it and let the server allocate.
    static let slugTaken: Int32 = 5

    /// `413` / `415` — the page itself is the problem. Retrying is pointless; the input changes
    /// or nothing does.
    static let pageRejected: Int32 = 6

    /// `404` — an update to a slug that does not exist, or an unknown client name.
    static let notFound: Int32 = 7

    /// `426` — this build is older than the server requires. Uniquely recoverable without
    /// asking anyone: reinstall and retry once.
    static let upgradeRequired: Int32 = 8

    /// The request never reached a server. Retryable, unlike everything above it.
    static let unreachable: Int32 = 9

    /// The server answered, and the answer was the server's fault: a `503`, a `5xx`, or a body
    /// this client could not parse. Retry once, then stop.
    static let serverError: Int32 = 10

    /// The table as `stele --help` prints it. Rendered from the constants above rather than
    /// retyped, so a code that changes cannot leave the documentation behind.
    static var helpTable: String {
        let rows: [(Int32, String)] = [
            (0, "success"),
            (failure, "failed — read the message, fix the input, do not retry"),
            (noCredential, "no usable credential here — ask the user to run `stele auth login`"),
            (credentialRejected, "the server rejected the credential — ask the user to log in again"),
            (forbidden, "valid credential, insufficient scope — an operator has to run this"),
            (slugTaken, "that slug is taken — choose another --slug or omit it"),
            (pageRejected, "the page is too large or the wrong type"),
            (notFound, "no such page or client"),
            (upgradeRequired, "the CLI is too old — reinstall it and retry once"),
            (unreachable, "could not reach the server — retryable"),
            (serverError, "the server failed — retry once, then stop"),
        ]
        let width = rows.map { String($0.0).count }.max() ?? 1
        let lines = rows.map { code, meaning in
            "  \(String(repeating: " ", count: width - String(code).count))\(code)  \(meaning)"
        }
        return "EXIT CODES:\n" + lines.joined(separator: "\n")
    }

    /// Prints `error` the way ArgumentParser prints an uncaught one — `Error: …` on stderr —
    /// and returns the status to exit with.
    ///
    /// Reporting here rather than rethrowing is what buys the per-outcome codes: ArgumentParser
    /// gives every `CustomStringConvertible` error `EXIT_FAILURE`, and an `ExitCode` thrown on
    /// its own prints nothing. Doing both means doing it in one place, and this is it.
    static func report(_ error: any Error) -> ExitCode {
        Terminal.error("Error: \(describe(error))")
        return ExitCode(code(for: error))
    }

    /// The message, taken from the error's own description.
    ///
    /// `String(describing:)` rather than a cast to `CustomStringConvertible` — every `Error` is
    /// already convertible, so the cast never fails and the conditional would read as a
    /// fallback that does not exist. What actually matters is that `SteleError`,
    /// `CredentialsError`, `PromptError` and `Failure` each write a `description` ending in an
    /// instruction, and `String(describing:)` prefers it.
    static func describe(_ error: any Error) -> String {
        String(describing: error)
    }

    static func code(for error: any Error) -> Int32 {
        switch error {
        case let error as SteleError:
            switch error {
            case .unauthorized: return credentialRejected
            case .forbidden: return forbidden
            case .slugTaken: return slugTaken
            case .pageTooLarge, .unsupportedContentType: return pageRejected
            case .notFound: return notFound
            case .upgradeRequired: return upgradeRequired
            case .transportFailure: return unreachable
            case .slugAllocationFailed, .malformedResponse: return serverError
            case .unexpectedStatus(let status, _):
                // A 5xx is the server's fault and worth one retry; a 4xx this client has no
                // case for is the caller's, and retrying it changes nothing.
                return (500..<600).contains(status) ? serverError : failure
            case .badRequest: return failure
            }
        case let error as CredentialsError:
            switch error {
            case .notAuthenticated, .noCredentialForHost, .ambiguousHost, .fileTooOpen,
                .malformed:
                return noCredential
            case .unreadable, .writeFailed, .invalidHost, .emptyToken, .malformedToken:
                return failure
            }
        case let error as PromptError:
            switch error {
            // A prompt this program refused to fake. Same signal as an empty credential file,
            // because the remedy is the same person doing the same thing — and an agent that
            // saw the generic `1` here would retry the pipe it just had refused.
            case .notATerminal: return noCredential
            // A human was there and gave nothing. "Fix the input and try again" is exactly right.
            case .nothingEntered: return failure
            }
        default:
            return failure
        }
    }
}

/// stdout and stderr, kept apart on purpose.
///
/// Everything a caller consumes — the published URL, the JSON, the skill document — goes to
/// stdout and nothing else does. Prompts, warnings and errors go to stderr, so
/// `stele publish page.html > url.txt` captures a URL and not a prompt, and `stele skill | less`
/// pages a document rather than a document with a warning wedged into it.
enum Terminal {
    static func out(_ text: String) {
        print(text)
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// A prompt: stderr, and no trailing newline, so the cursor stays on the same line as the
    /// question. `FileHandle` rather than `print` because stderr is unbuffered here and the
    /// prompt has to appear *before* the read blocks, not when the line eventually flushes.
    static func prompt(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
