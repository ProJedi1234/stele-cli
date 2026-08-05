import Foundation

/// Choosing the `Content-Type` for a file, so the caller does not have to.
///
/// This is the decision the plan singles out as the CLI's to own. The `curl` recipe it replaces
/// made the agent send the header by hand, which produced two standing pitfalls in the skill
/// document — forget it and a wrapper sends `application/json` and earns a `415`; get it wrong
/// and a Markdown file is stored and served as HTML.
///
/// The map is a *hint*, not a gate. The server keeps the real allowlist and answers `415` for
/// anything off it; a copy of that list used for validation here would be a second source of
/// truth that refuses a type the day the server learns a new one. So an unknown extension falls
/// through to `text/html` — the overwhelmingly common case and the one the tool is named for —
/// and an explicit `--content-type` is passed through untouched, whatever it says.
public enum ContentType {
    public static let fallback = "text/html"

    /// Extension to type. Lowercased keys; the lookup lowercases too, because `PAGE.HTML` off a
    /// case-insensitive filesystem is a real path a real person types.
    static let byExtension: [String: String] = [
        "html": "text/html",
        "htm": "text/html",
        "md": "text/markdown",
        "markdown": "text/markdown",
        "css": "text/css",
        "txt": "text/plain",
        "text": "text/plain",
    ]

    /// The distinct types this tool knows about, sorted — what `--content-type` offers at TAB.
    public static var known: [String] { Set(byExtension.values).sorted() }

    public static func inferred(fromPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? fallback
    }
}

/// A human-written lifetime — `90d`, `12h` — as the seconds `POST /admin/clients` wants.
///
/// A duration rather than an absolute date, for the reason the client's request body already
/// gives: two clocks are involved and only the server's has to be right if the caller says "90
/// days from now" and the server does the arithmetic.
///
/// A unit suffix is required. A bare `90` reads as days to whoever wrote it and as seconds to
/// whoever reads the code, and the failure mode of guessing wrong is a credential that expires
/// a minute and a half after it is minted — or one that outlives the machine it was for.
public enum ExpiryDuration {
    /// Seconds per unit, in the order a message should list them. Whole seconds as `Int`, so the
    /// arithmetic below can be checked for overflow — `Double` would silently round instead.
    static let units: [(suffix: String, seconds: Int, name: String)] = [
        ("s", 1, "seconds"),
        ("m", 60, "minutes"),
        ("h", 3600, "hours"),
        ("d", 86400, "days"),
        ("w", 604_800, "weeks"),
    ]

    /// The longest lifetime this will parse.
    ///
    /// A ceiling has to exist, and not for tidiness: without one, `999999999999999d` multiplies
    /// out to about 8.6e19 seconds, and turning that into the `Int` the request body carries is
    /// a Swift *runtime trap* rather than an error. The user gets a crash and a backtrace where
    /// every other bad duration gets a sentence telling them what to type instead.
    ///
    /// Ten years is far past any credential's useful life — a credential that outlives the
    /// machine it was minted for is the thing `--expires-in` exists to prevent — and far short
    /// of where the arithmetic gets interesting.
    public static let maximumSeconds = 3650 * 86400

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case notPositive(String)
        /// A well-formed duration that is longer than `maximumSeconds`, including one whose
        /// digits do not fit in an `Int` at all. Its own case because the correction is
        /// different: the syntax was right and the number was not.
        case tooLong(String)

        public var description: String {
            let vocabulary = ExpiryDuration.units
                .map { "\($0.suffix) (\($0.name))" }
                .joined(separator: ", ")
            switch self {
            case .malformed(let raw):
                return """
                    '\(raw)' is not a duration. Write a whole number and a unit — 90d, 12h — \
                    using one of \(vocabulary). A bare number is refused because its unit is \
                    only obvious to whoever typed it.
                    """
            case .notPositive(let raw):
                return """
                    '\(raw)' is not a lifetime. A credential that expires now or in the past \
                    would be minted dead; omit --expires-in for one that never expires.
                    """
            case .tooLong(let raw):
                return """
                    '\(raw)' is longer than the longest lifetime stele will ask for \
                    (\(ExpiryDuration.maximumSeconds / 86400)d). Give a shorter one, or omit \
                    --expires-in for a credential that never expires — which is what a lifetime \
                    that long means anyway.
                    """
            }
        }
    }

    /// `"90d"` → `7776000`.
    public static func seconds(from raw: String) throws(ParseError) -> TimeInterval {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let suffix = text.last, let unit = units.first(where: { $0.suffix == String(suffix) })
        else { throw .malformed(raw) }

        // ASCII digits specifically. `isNumber` also admits other scripts' digits, which `Int`
        // then declines to parse — and the check below reads a failed parse as overflow.
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw .malformed(raw)
        }
        // So a digit run too long for `Int` lands on `.tooLong` rather than `.malformed`, which
        // would tell the user to write a number and a unit — which is exactly what they did.
        guard let count = Int(digits) else { throw .tooLong(raw) }
        guard count > 0 else { throw .notPositive(raw) }
        let (total, overflowed) = count.multipliedReportingOverflow(by: unit.seconds)
        guard !overflowed, total <= maximumSeconds else { throw .tooLong(raw) }
        return TimeInterval(total)
    }
}
