import Foundation
import Testing

@testable import SteleKit

/// A console the test drives, and — more to the point — one that records whether it was *read*.
///
/// A test that only checked for a thrown error would pass against an implementation that read
/// the pipe first and threw afterwards, which is the same leak with an error message on top. So
/// `reads` is the assertion that matters on the refusal path.
///
/// A class rather than an actor because `Prompt` is synchronous; `@unchecked Sendable` because
/// each instance is used from one test and never crosses a suspension.
private final class FakeConsole: PromptConsole, @unchecked Sendable {
    let isInteractive: Bool
    private var lines: [String]
    private(set) var prompts: [String] = []
    private(set) var reads = 0
    private(set) var echoWasOffDuringRead: Bool?

    private var echoOff = false

    init(isInteractive: Bool, lines: [String] = []) {
        self.isInteractive = isInteractive
        self.lines = lines
    }

    func writePrompt(_ text: String) { prompts.append(text) }

    func readLine() -> String? {
        reads += 1
        echoWasOffDuringRead = echoOff
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    func withoutEcho(_ body: () -> String?) -> String? {
        echoOff = true
        defer { echoOff = false }
        return body()
    }
}

/// The custody boundary, as the one rule everything else in this tool rests on.
///
/// `echo $TOKEN | stele auth login` has to keep failing. It is the shape of the mistake the
/// whole design exists to make impossible — argv and shell history are what the credential file
/// replaced, and a pipe puts the token straight back into both.
@Suite("prompt custody")
struct PromptTests {
    @Test("a non-TTY stdin is refused for a secret, and is never read")
    func secretRefusesAPipe() throws {
        let console = FakeConsole(isInteractive: false, lines: ["stele_pat_piped"])
        let prompt = Prompt(console: console)

        #expect(throws: PromptError.notATerminal) {
            try prompt.secret("token: ")
        }
        #expect(console.reads == 0)
        // Nor is a prompt printed at something that cannot answer it.
        #expect(console.prompts.isEmpty)
    }

    /// The host prompt is not a secret, and it is refused all the same: `auth login` answering
    /// half its questions from a pipe would read as a bug to work around rather than as a rule.
    @Test("a non-TTY stdin is refused for the host line too, and is never read")
    func lineRefusesAPipe() throws {
        let console = FakeConsole(isInteractive: false, lines: ["https://stele.example.com"])
        let prompt = Prompt(console: console)

        #expect(throws: PromptError.notATerminal) {
            try prompt.line("host: ")
        }
        #expect(console.reads == 0)
    }

    /// The refusal is read by an agent deciding what to do next, and the only correct next step
    /// is to stop and ask a person. It has to say so in words, not only in an exit code.
    @Test("the refusal tells an agent to stop and ask the user")
    func refusalNamesTheRemedy() {
        let description = PromptError.notATerminal.description
        #expect(description.contains("not a TTY"))
        #expect(description.contains("stele auth login"))
        #expect(description.contains("ask the user"))
    }

    @Test("a terminal is read, with echo off, and the answer is trimmed")
    func secretReadsATerminal() throws {
        let console = FakeConsole(isInteractive: true, lines: ["  stele_pat_typed  "])
        let prompt = Prompt(console: console)

        #expect(try prompt.secret("token for https://stele.example.com: ")
            == "stele_pat_typed")
        #expect(console.prompts == ["token for https://stele.example.com: "])
        // The read itself happens with echo off — turning it off around the read rather than
        // during it would put the token on screen and in the scrollback.
        #expect(console.echoWasOffDuringRead == true)
    }

    /// The host is typed at a terminal a person is looking at; hiding it would make a typo
    /// impossible to spot.
    @Test("the host line is read with echo left on")
    func lineIsEchoed() throws {
        let console = FakeConsole(isInteractive: true, lines: ["https://stele.example.com"])
        let prompt = Prompt(console: console)

        #expect(try prompt.line("host: ") == "https://stele.example.com")
        #expect(console.echoWasOffDuringRead == false)
    }

    /// Ctrl-D at the prompt. A person was there and gave nothing, which is "try again", not
    /// "stop and find a human" — the executable maps the two cases to different exit codes.
    @Test("EOF at a real terminal is nothing-entered, not a refusal")
    func eofIsNotARefusal() {
        let console = FakeConsole(isInteractive: true)
        let prompt = Prompt(console: console)

        #expect(throws: PromptError.nothingEntered("no token was entered")) {
            try prompt.secret("token: ")
        }
    }
}
