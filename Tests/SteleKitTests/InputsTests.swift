import Foundation
import Testing

@testable import SteleKit

/// The two decisions the command line hands straight to the library: what type a file is, and
/// how long a credential should live.
///
/// Both live in `SteleKit` rather than beside the ArgumentParser declarations for the reason
/// the package is split in two — a pure function is testable without spawning a process, and
/// these are the parts with actual rules in them.
@Suite("inputs")
struct InputsTests {
    @Test(
        "the content type comes from the extension",
        arguments: [
            ("page.html", "text/html"),
            ("page.htm", "text/html"),
            ("notes.md", "text/markdown"),
            ("notes.markdown", "text/markdown"),
            ("stele.css", "text/css"),
            ("log.txt", "text/plain"),
        ]
    )
    func inference(_ path: String, _ expected: String) {
        #expect(ContentType.inferred(fromPath: path) == expected)
    }

    /// A path off a case-insensitive filesystem, and a path with directories in it, are both
    /// things a person types.
    @Test("inference ignores case and leading directories")
    func inferenceIsForgiving() {
        #expect(ContentType.inferred(fromPath: "~/pages/PAGE.HTML") == "text/html")
        #expect(ContentType.inferred(fromPath: "/tmp/a.b.c/notes.MD") == "text/markdown")
    }

    /// The map is a hint, not a copy of the server's allowlist: an unknown extension publishes
    /// as HTML and lets the server have the last word, rather than refusing locally.
    @Test("an unknown extension falls through to the default rather than failing")
    func inferenceFallsThrough() {
        #expect(ContentType.inferred(fromPath: "page") == ContentType.fallback)
        #expect(ContentType.inferred(fromPath: "archive.tar.gz") == ContentType.fallback)
    }

    /// Spelled out as a typed constant rather than inline in the `@Test` attribute: the macro
    /// expands its `arguments:` into a generic call the type checker gives up on when the
    /// literals need inference *and* arithmetic. The trailing case is a reminder that the
    /// parser trims and lowercases before it looks at anything.
    static let durationCases: [(String, TimeInterval)] = [
        ("90d", 7_776_000), ("12h", 43_200), ("30m", 1_800), ("45s", 45),
        ("2w", 1_209_600), (" 8D ", 691_200),
    ]

    @Test("a duration is a whole number and a unit", arguments: durationCases)
    func durations(_ raw: String, _ expected: TimeInterval) throws {
        #expect(try ExpiryDuration.seconds(from: raw) == expected)
    }

    /// A bare number is refused rather than defaulted: it reads as days to whoever typed it and
    /// as seconds to whoever wrote the code, and guessing wrong mints a credential that is dead
    /// on arrival or one that outlives the machine it was for.
    @Test(
        "anything without a unit, or with a unit this does not know, is refused",
        arguments: ["90", "", "d", "-5d", "1.5d", "90 d", "90days", "1y"]
    )
    func rejectsAmbiguousDurations(_ raw: String) {
        #expect(throws: ExpiryDuration.ParseError.self) { try ExpiryDuration.seconds(from: raw) }
    }

    /// The ceiling exists to keep a bad argument an *error*. Without it these multiply out past
    /// `Int`'s range, and the conversion the request body needs is a Swift runtime trap — the
    /// user gets a crash and a backtrace where every other bad duration gets a sentence.
    @Test(
        "a lifetime past the ceiling is refused rather than trapped",
        arguments: [
            "999999999999999d",           // overflows the multiply
            "99999999999999999999999d",   // too many digits for Int at all
            "3651d",                      // one day past the ceiling
            "9999w",
        ]
    )
    func refusesAbsurdDurations(_ raw: String) {
        #expect(throws: ExpiryDuration.ParseError.tooLong(raw)) {
            try ExpiryDuration.seconds(from: raw)
        }
    }

    @Test("the ceiling itself is accepted, and says what it is")
    func acceptsTheCeiling() throws {
        let maximum = ExpiryDuration.maximumSeconds
        #expect(try ExpiryDuration.seconds(from: "\(maximum / 86400)d") == TimeInterval(maximum))
        #expect(ExpiryDuration.ParseError.tooLong("9999w").description.contains("\(maximum / 86400)d"))
    }

    /// Not the CLI's path — `ExpiryDuration` bounds that — but `createClient` takes a
    /// `TimeInterval` from any caller of the library, and `Int(someDouble)` out of range traps.
    @Test(
        "an unbounded lifetime reaching the client is clamped rather than trapped",
        arguments: [Double.infinity, -.infinity, .nan, 1e30, -1e30, .greatestFiniteMagnitude]
    )
    func clampsRatherThanTraps(_ interval: TimeInterval) {
        _ = SteleClient.wholeSeconds(interval)
    }

    @Test("an ordinary lifetime survives the clamp unchanged")
    func clampLeavesOrdinaryValuesAlone() {
        #expect(SteleClient.wholeSeconds(7_776_000) == 7_776_000)
        #expect(SteleClient.wholeSeconds(90.4) == 90)
    }

    @Test("a zero lifetime is refused as its own case, because the fix is different")
    func rejectsZero() {
        #expect(throws: ExpiryDuration.ParseError.notPositive("0d")) {
            try ExpiryDuration.seconds(from: "0d")
        }
    }

    /// The message has to name the units it accepts, since that is the whole content of the
    /// correction — and it names them from the table rather than from a retyped list.
    @Test("the parse error lists the vocabulary it accepts")
    func errorNamesTheUnits() {
        let description = ExpiryDuration.ParseError.malformed("90").description
        for unit in ExpiryDuration.units {
            #expect(description.contains(unit.name))
        }
    }
}
