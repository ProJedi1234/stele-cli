import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
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
/// the environment and the history this design removed it from; accepting a pipe here would
/// make every other precaution decorative.
enum Prompt {
    /// Reads a secret with the terminal's echo turned off.
    ///
    /// - Parameter isTTY: injected so the refusal path is describable without a terminal, in the
    ///   same spirit as `Style.detect(env:isTTY:)`.
    static func secret(
        _ label: String,
        isTTY: Bool = isatty(STDIN_FILENO) == 1
    ) throws -> String {
        guard isTTY else { throw notATerminal }

        // The prompt goes to stderr: stdout belongs to whatever the caller is capturing, and a
        // prompt in a redirected file is a prompt nobody saw.
        Terminal.prompt(label)

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
                Terminal.error("")
            }
        }

        guard let line = readLine(strippingNewline: true) else {
            // EOF: Ctrl-D at the prompt, or a terminal that went away mid-read.
            throw Failure("no token was entered.")
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads an ordinary, echoed line — used for the host at login, which is not a secret.
    static func line(
        _ label: String,
        isTTY: Bool = isatty(STDIN_FILENO) == 1
    ) throws -> String {
        guard isTTY else { throw notATerminal }
        Terminal.prompt(label)
        guard let line = readLine(strippingNewline: true) else { throw Failure("nothing entered.") }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let notATerminal = NeedsHuman(
        """
        `stele auth login` has to be run by a human at a terminal — stdin is not a TTY, and \
        this command will not read from a pipe. Piping a token in would put the credential back \
        into the environment or the shell history that the credential file exists to keep it \
        out of. If you are an agent: stop here and ask the user to run `stele auth login` \
        themselves.
        """
    )
}

/// A failure whose only remedy is a person.
///
/// Distinct from `Failure` for one reason: the exit code. An agent that tried to authenticate
/// unattended should get the same signal it gets when no credential is stored at all —
/// `Exit.noCredential`, "stop and ask the user" — rather than the generic `1` that means "fix
/// the input and try again", which is advice it cannot act on and would burn a retry on.
struct NeedsHuman: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
