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

    @Test(
        "an attachment's type comes from its extension",
        arguments: [
            ("screenshot.png", "image/png"),
            ("photo.jpg", "image/jpeg"),
            ("photo.jpeg", "image/jpeg"),
            ("loop.gif", "image/gif"),
            ("shot.webp", "image/webp"),
            ("clip.mp4", "video/mp4"),
            ("clip.webm", "video/webm"),
            ("report.pdf", "application/pdf"),
        ]
    )
    func attachmentInference(_ path: String, _ expected: String) {
        #expect(ContentType.attachmentInferred(fromPath: path) == expected)
    }

    @Test("attachment inference ignores case and leading directories")
    func attachmentInferenceIsForgiving() {
        #expect(ContentType.attachmentInferred(fromPath: "~/shots/SCREEN.PNG") == "image/png")
        #expect(ContentType.attachmentInferred(fromPath: "/tmp/a.b.c/clip.MP4") == "video/mp4")
    }

    /// The inversion of `inferenceFallsThrough`, and the reason the two maps are separate. A
    /// guess costs nothing on a page — `text/html` is what the tool is named for. On an upload
    /// it costs the upload: the bytes go up, the server validates them as UTF-8 and answers
    /// `415` naming a type nobody chose. Nil is what lets the command refuse first.
    @Test("an unknown extension has no attachment type rather than a default one")
    func attachmentInferenceRefusesToGuess() {
        #expect(ContentType.attachmentInferred(fromPath: "screenshot") == nil)
        #expect(ContentType.attachmentInferred(fromPath: "archive.tar.gz") == nil)
    }

    /// The two maps do not overlap, and neither is a superset of the other. A `.png` is not a
    /// page and an `.html` is not an attachment, so each lookup declines the other's files in
    /// the way its own caller can act on.
    @Test("pages and attachments keep their own tables")
    func theTablesStaySeparate() {
        #expect(ContentType.attachmentInferred(fromPath: "page.html") == nil)
        #expect(ContentType.inferred(fromPath: "screenshot.png") == ContentType.fallback)
    }

    /// What a refused file's message lists. Extensions, because that is what the person is
    /// holding — `image/png` is not an answer to "so what do I do with this .graffle".
    @Test("the refusal message can name the extensions, not just the types")
    func knownAttachmentExtensionsAreListed() {
        #expect(
            ContentType.knownAttachmentExtensions
                == ["gif", "jpeg", "jpg", "mp4", "pdf", "png", "webm", "webp"]
        )
    }

    /// SVG is the one image format that is also a document. The server does not accept it, and
    /// offering it here would turn a considered `415` into a type this tool appears to know.
    @Test("svg is not an attachment type this tool offers")
    func svgIsNotOffered() {
        #expect(ContentType.attachmentInferred(fromPath: "diagram.svg") == nil)
        #expect(!ContentType.knownAttachments.contains("image/svg+xml"))
    }

    /// What TAB offers, deduplicated: two extensions map to `image/jpeg` and completing it
    /// twice would read as two different types.
    @Test("the completion list is the distinct attachment types, sorted")
    func knownAttachmentsAreDistinct() {
        #expect(
            ContentType.knownAttachments == [
                "application/pdf", "image/gif", "image/jpeg", "image/png", "image/webp",
                "video/mp4", "video/webm",
            ]
        )
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

/// The other lifetime, which is a different grammar for a reason: a credential's is seconds and
/// a page's is whole days, and the two flags are close enough together on the command line that
/// where they diverge is worth pinning.
@Suite("page lifetimes")
struct PageTTLTests {
    static let dayCases: [(String, Int)] = [
        ("30", 30), ("30d", 30), ("1", 1), ("2w", 14), ("365d", 365),
        // Trimmed and lowercased before anything looks at it, like its sibling.
        (" 7D ", 7),
    ]

    @Test("a lifetime is a whole number of days, with or without a unit", arguments: dayCases)
    func days(_ raw: String, _ expected: Int) throws {
        #expect(try PageTTL.parse(raw) == .days(expected))
    }

    /// The bare number is the case worth stating outright, because it is exactly what
    /// `--expires-in` refuses. A page's lifetime has one unit and the server's own document
    /// teaches `?ttl=30`, so the spelling an agent just read there has to work.
    @Test("a bare number means days, unlike --expires-in")
    func bareNumberIsDays() throws {
        #expect(try PageTTL.parse("30") == .days(30))
        #expect(throws: ExpiryDuration.ParseError.malformed("30")) {
            try ExpiryDuration.seconds(from: "30")
        }
    }

    @Test("'never' is the only way to ask for a page that is kept")
    func never() throws {
        #expect(try PageTTL.parse(PageTTL.neverKeyword) == .never)
        #expect(try PageTTL.parse("NEVER") == .never)
        // Not a synonym. The server matches one keyword exactly, and a parser that quietly
        // accepted a second spelling would send a `400` for a page the caller meant to keep.
        #expect(throws: PageTTL.ParseError.malformed("forever")) { try PageTTL.parse("forever") }
    }

    /// The heart of why this is not `ExpiryDuration`. `12h` is a perfectly good duration that
    /// this server cannot store, and the only ways to honour it are to round — silently giving
    /// the caller a lifetime they did not type — or to say so.
    @Test(
        "a unit finer than a day is refused rather than rounded",
        arguments: [("12h", "hours"), ("90m", "minutes"), ("3600s", "seconds")]
    )
    func refusesSubDayUnits(_ raw: String, _ unit: String) {
        #expect(throws: PageTTL.ParseError.tooFine(raw, unit: unit)) { try PageTTL.parse(raw) }
        // And the message says which unit it was, so the correction is arithmetic the caller
        // can do rather than a guess at what the tool wanted.
        #expect(PageTTL.ParseError.tooFine(raw, unit: unit).description.contains(unit))
    }

    @Test(
        "anything that is not a number of days is refused",
        arguments: ["", "  ", "7.5", "abc", "d", "w", "30x", "3 0", "٣٠", "-", "1e3"]
    )
    func refusesMalformed(_ raw: String) {
        #expect(throws: PageTTL.ParseError.self) { try PageTTL.parse(raw) }
    }

    /// Zero and negative get their own case for the same reason `ExpiryDuration` gives them one:
    /// the syntax was right and the correction is a different sentence.
    @Test("a lifetime of zero or less is refused as its own case", arguments: ["0", "0d", "-5", "-5d"])
    func refusesNonPositive(_ raw: String) {
        #expect(throws: PageTTL.ParseError.notPositive(raw)) { try PageTTL.parse(raw) }
    }

    /// This type deliberately has no maximum — the server owns that bound. What it does have is
    /// arithmetic, and the arithmetic must not trap: `Int(_:)` on a digit run too long, and the
    /// weeks multiplication, are the two places a number can run off the end.
    @Test(
        "a number too large to become days is reported, not trapped",
        arguments: ["999999999999999999999999", "9999999999999999999w", "\(Int.max)w"]
    )
    func refusesUnreachable(_ raw: String) {
        #expect(throws: PageTTL.ParseError.unreachable(raw)) { try PageTTL.parse(raw) }
    }

    /// A lifetime past the *server's* maximum is not rejected here. A copy of that bound would
    /// be a second source of truth that drifts the day the server moves it, and the `400` it
    /// earns names the real limit — which a local guess could not.
    @Test("a lifetime past the server's ceiling is left for the server to refuse")
    func doesNotCopyTheServersCeiling() throws {
        #expect(try PageTTL.parse("36501") == .days(36_501))
        #expect(try PageTTL.parse("100000d") == .days(100_000))
    }

    @Test("what travels on the wire is the server's own spelling")
    func queryValues() {
        #expect(PageTTL.days(30).queryValue == "30")
        #expect(PageTTL.days(14).queryValue == "14")
        #expect(PageTTL.never.queryValue == "never")
        #expect(PageTTL.queryParameter == "ttl")
    }
}
