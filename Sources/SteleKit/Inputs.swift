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

/// How long a page lives, as the `?ttl=` value `POST /pages` and `PATCH /pages/:slug` want.
///
/// The server measures a page's life in whole days or not at all: `?ttl=30`, or `?ttl=never`.
/// Omitting it is a third thing — and this is the trap, because it is not the *same* third thing
/// on both routes. On `POST` an absent `?ttl=` takes the server's own default lifetime, a matter
/// of days; on `PATCH` it means **leave the deadline exactly where it is**. `PageTTL?` cannot
/// carry that difference — it is one optional with one absent case, read in opposite directions
/// by the two verbs — so it rests entirely on neither caller inventing a value to fill the
/// silence with. A `ttl=7` sent on an amendment because seven looked like a reasonable default
/// would put a week's deadline on a page published to be kept, and the `200` would look right.
///
/// The default itself is deliberately not repeated here. A CLI that printed "expires in 7 days"
/// from a constant would keep printing it the day the server changed its mind, and the server
/// tells us the real answer in the response body anyway.
///
/// Note what this type does *not* do: it has no maximum. The server's `PageLifetime` owns that
/// bound, for the same reason its `Slug` owns the slug rules — a copy here would be a second
/// source of truth that drifts silently the first time the server moves it. An over-long
/// lifetime comes back as a `400` naming the real limit. What is checked here is only what the
/// server cannot check for us: that the caller wrote something that means a number of days at
/// all, and that turning it into one does not overflow on the way.
public enum PageTTL: Sendable, Equatable {
    case days(Int)
    case never

    /// The query parameter, and the spelling that opts out of expiry. Both are the server's
    /// words, and both are exact-match contracts with another repository — the same class of
    /// constant as `SteleClient.Path` and `expiresIn`, and the same failure if they drift: a
    /// `ttl=forever` would be a `400`, but a parameter named anything but `ttl` would be
    /// *ignored*, and a page the caller asked to keep forever would quietly die in a week.
    public static let queryParameter = "ttl"
    public static let neverKeyword = "never"

    /// Days and weeks, which are the units that survive the trip.
    ///
    /// Nothing shorter is offered, and that is the whole reason this is not `ExpiryDuration`.
    /// The server stores a page's deadline to the day, so `12h` could only be honoured by
    /// rounding it to something the caller did not type — and a lifetime silently rounded is
    /// the failure both ends of this contract are built to refuse.
    static let units: [(suffix: String, days: Int, name: String)] = [
        ("d", 1, "days"),
        ("w", 7, "weeks"),
    ]

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case notPositive(String)
        /// A unit this server cannot store a page to: hours, minutes, seconds. Its own case
        /// because the caller wrote a perfectly good duration and the answer is not "write a
        /// duration" but "days are the resolution you get".
        case tooFine(String, unit: String)
        /// A number of days too large to be turned into one at all. Not a policy limit — the
        /// server's is enforced by the server — but the point past which the arithmetic here
        /// stops being arithmetic.
        case unreachable(String)

        public var description: String {
            switch self {
            case .malformed(let raw):
                return """
                    '\(raw)' is not a page lifetime. Write a whole number of days — 30, or 30d — \
                    or '\(PageTTL.neverKeyword)' for a page that is kept until you delete it.
                    """
            case .notPositive(let raw):
                return """
                    '\(raw)' is not a lifetime. A page that expires now or in the past would be \
                    published dead; use '\(PageTTL.neverKeyword)' for one that is kept.
                    """
            case .tooFine(let raw, let unit):
                return """
                    '\(raw)' is \(unit), and a page's lifetime is measured in whole days — \
                    honouring it would mean rounding to a lifetime you did not ask for. Write \
                    the number of days instead, or '\(PageTTL.neverKeyword)' to keep the page.
                    """
            case .unreachable(let raw):
                return """
                    '\(raw)' is too many days to be a lifetime. Use \
                    '\(PageTTL.neverKeyword)' for a page that should never expire.
                    """
            }
        }
    }

    /// `"30"` and `"30d"` → `.days(30)`; `"2w"` → `.days(14)`; `"never"` → `.never`.
    ///
    /// A bare number is accepted here where `--expires-in` refuses one, and the difference is
    /// not an inconsistency. That flag's underlying unit is *seconds* and its range runs from
    /// seconds to weeks, so `90` genuinely has two readings and guessing between them mints a
    /// credential that dies in a minute and a half. A page's lifetime has one unit, the server's
    /// own document teaches `?ttl=30`, and refusing the spelling an agent just read there would
    /// be a second grammar to no purpose.
    public static func parse(_ raw: String) throws(ParseError) -> PageTTL {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { throw .malformed(raw) }
        if text == neverKeyword { return .never }

        // A trailing unit is optional; its absence means days. Anything that is not a digit run
        // has to be named as a unit before it can be refused as one, so hours and friends are
        // matched here rather than falling through to "that is not a lifetime".
        let (digits, multiplier): (Substring, Int)
        if let last = text.last, last.isASCII, !last.isNumber {
            if let unit = units.first(where: { $0.suffix == String(last) }) {
                (digits, multiplier) = (text.dropLast(), unit.days)
            } else if let finer = ExpiryDuration.units.first(where: { $0.suffix == String(last) }) {
                throw .tooFine(raw, unit: finer.name)
            } else {
                throw .malformed(raw)
            }
        } else {
            (digits, multiplier) = (text[...], 1)
        }

        // ASCII digits specifically, matching `ExpiryDuration`: `isNumber` admits other scripts'
        // digits, which `Int` then declines to parse, and the check below reads a failed parse
        // as a number too large rather than a number in the wrong script.
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            // A leading `-` lands here. It is not a malformed lifetime, it is a negative one,
            // and saying so sends the caller to the right correction.
            if digits.first == "-", digits.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
                throw .notPositive(raw)
            }
            throw .malformed(raw)
        }
        guard let count = Int(digits) else { throw .unreachable(raw) }
        guard count > 0 else { throw .notPositive(raw) }
        let (days, overflowed) = count.multipliedReportingOverflow(by: multiplier)
        guard !overflowed else { throw .unreachable(raw) }
        return .days(days)
    }

    /// What travels as `?ttl=`.
    public var queryValue: String {
        switch self {
        case .days(let count): return String(count)
        case .never: return PageTTL.neverKeyword
        }
    }
}
