import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reading from the terminal, which is the only way a token is allowed to enter this program.
///
/// The rule is not "prefer a prompt". A token passed as an argument is visible to every process
/// on the machine through `ps`, it is written to the shell's history file, and shell history is
/// something an agent reads — so there is deliberately no `--token` flag anywhere in the tree
/// for anyone to reach for, and no environment variable either. The prompt is the only door.
///
/// Refusing a non-TTY stdin rather than reading it is the other half. `echo $TOKEN | stele auth
/// login` looks like a reasonable thing to write and would put the credential right back into
/// the environment and the history this design removed it from; accepting a pipe here would make
/// every other precaution decorative.
///
/// This lives in `SteleKit` rather than beside `auth login` in the executable for one reason:
/// the refusal is the load-bearing custody rule of the whole tool, and the executable target has
/// no tests. Deleting the guard used to be a change CI applauded. The console is injected, so
/// `PromptTests` can hold a pipe up to it and watch it refuse.
public struct Prompt: Sendable {
    private let console: any PromptConsole

    public init(console: any PromptConsole = SystemConsole()) {
        self.console = console
    }

    /// Reads a secret with the terminal's echo turned off.
    public func secret(_ label: String) throws(PromptError) -> String {
        guard console.isInteractive else { throw .notATerminal }

        console.writePrompt(label)
        // The read happens inside `withoutEcho` rather than around it: everything typed between
        // the prompt appearing and the read returning is what must not appear on screen.
        guard let line = console.withoutEcho({ console.readLine() }) else {
            // EOF: Ctrl-D at the prompt, or a terminal that went away mid-read.
            throw .nothingEntered("no token was entered")
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads an ordinary, echoed line — used for the host at login, which is not a secret.
    ///
    /// Refuses a pipe for the same reason `secret` does, though nothing confidential passes
    /// through it: this is the *other* half of `auth login`, and a command that answered half of
    /// its questions from a pipe and refused the other half would read as a bug to work around
    /// rather than as a rule.
    public func line(_ label: String) throws(PromptError) -> String {
        guard console.isInteractive else { throw .notATerminal }

        console.writePrompt(label)
        guard let line = console.readLine() else { throw .nothingEntered("nothing was entered") }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a line with an answer already chosen, which Return accepts.
    ///
    /// Takes the question *without* its punctuation, unlike `line(_:)` above, and builds
    /// `question [default]: ` itself. That is the whole reason the method exists rather than
    /// leaving callers to interpolate the default into a label: a prompt that has a default and
    /// does not show it is a prompt whose Return key does something invisible, and making the
    /// caller responsible for showing it is how one eventually will not.
    ///
    /// End of input is still `nothingEntered` and not the default. Return is a person choosing
    /// the offered answer; Ctrl-D is a person leaving, and answering on their behalf because
    /// there happened to be a default would be answering for somebody who has gone.
    public func line(_ question: String, default fallback: String) throws(PromptError) -> String {
        guard console.isInteractive else { throw .notATerminal }

        console.writePrompt("\(question) [\(fallback)]: ")
        guard let line = console.readLine() else { throw .nothingEntered("nothing was entered") }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? fallback : answer
    }

    /// Asks a yes-or-no question.
    ///
    /// `answer` is what Return means, and it is shown in the prompt as the capitalised half of
    /// `[y/N]`. Every caller in this tool nominates the harmless answer, because the questions
    /// worth asking at all are the ones where the other answer destroys something.
    ///
    /// Anything unrecognised is the default rather than a re-ask. The alternative is a loop that
    /// cannot be escaped by a person who has realised they are answering the wrong question, and
    /// since the default is the harmless answer, a typo resolves to *not* doing the destructive
    /// thing — which is the direction a misunderstanding should fall in.
    public func confirm(
        _ question: String,
        default answer: Bool = false
    ) throws(PromptError) -> Bool {
        guard console.isInteractive else { throw .notATerminal }

        console.writePrompt("\(question) [\(answer ? "Y/n" : "y/N")] ")
        guard let line = console.readLine() else { throw .nothingEntered("nothing was entered") }

        switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "y", "yes": return true
        case "n", "no": return false
        default: return answer
        }
    }
}

/// What a prompt can fail with. Two cases, because they call for different next steps and the
/// executable turns each into a different exit code.
public enum PromptError: Error, Equatable, CustomStringConvertible {
    /// stdin is not a terminal. The remedy is a person, never a retry — which is why the
    /// executable gives this the same status as an empty credential file rather than the generic
    /// "fix the input and try again". An agent that got `1` here would burn a retry on advice it
    /// cannot act on.
    case notATerminal

    /// EOF at the prompt: Ctrl-D, or a terminal that went away mid-read. The argument says what
    /// was being asked for, so the message reads as a sentence at either call site.
    case nothingEntered(String)

    public var description: String {
        switch self {
        case .notATerminal:
            return """
                `stele auth login` has to be run by a human at a terminal — stdin is not a TTY, \
                and this command will not read from a pipe. Piping a token in would put the \
                credential back into the environment or the shell history that the credential \
                file exists to keep it out of. If you are an agent: stop here and ask the user \
                to run `stele auth login` themselves.
                """
        case .nothingEntered(let what):
            return "\(what) — run `stele auth login` again when you have it to hand."
        }
    }
}

/// The terminal, as the two questions `Prompt` needs to ask it and the one thing it needs done.
///
/// A protocol rather than direct `isatty`/`readLine` calls so the refusal path is describable
/// without a pipe, in the same spirit as `Style.detect(env:isTTY:)` and `CredentialStore(home:)`.
public protocol PromptConsole: Sendable {
    /// Whether stdin is a terminal with a person at it.
    var isInteractive: Bool { get }

    /// Shows the prompt. Goes to stderr with no trailing newline, so the cursor stays on the
    /// question's line and a redirected stdout still captures only what the caller asked for.
    func writePrompt(_ text: String)

    /// Reads one line, or nil at end of input.
    func readLine() -> String?

    /// Runs `body` with terminal echo off, restoring the previous settings afterwards.
    func withoutEcho(_ body: () -> String?) -> String?
}

/// The real console: stdin, stderr and `termios`.
///
/// It writes to stderr itself rather than through the executable's `Terminal`, because a library
/// that called back into the executable to print would invert the dependency — and this is the
/// one place in `SteleKit` that has anything to say to a human.
public struct SystemConsole: PromptConsole {
    public init() {}

    public var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    public func writePrompt(_ text: String) {
        // `FileHandle` rather than `print`: stderr is unbuffered here, and the prompt has to
        // appear *before* the read blocks rather than when the line eventually flushes.
        FileHandle.standardError.write(Data(text.utf8))
    }

    public func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }

    public func withoutEcho(_ body: () -> String?) -> String? {
        var original = termios()
        let sawTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        if sawTerminal {
            var quiet = original
            // `tcflag_t` is UInt32 on Glibc and UInt on Darwin; converting through it rather
            // than through a literal type keeps this one line portable.
            quiet.c_lflag &= ~tcflag_t(ECHO)
            // TCSAFLUSH discards anything typed between the prompt and the switch, so a
            // keystroke that arrived early cannot be echoed after echo is nominally off.
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
        }
        defer {
            if sawTerminal {
                _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
                // The user's Return was swallowed along with everything else they typed, so the
                // cursor is still sitting after the prompt. Put the line break back by hand or
                // the next line of output lands on top of it.
                FileHandle.standardError.write(Data("\n".utf8))
            }
        }
        return body()
    }
}
