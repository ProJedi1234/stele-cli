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
    /// Seconds per unit, in the order a message should list them.
    static let units: [(suffix: String, seconds: Double, name: String)] = [
        ("s", 1, "seconds"),
        ("m", 60, "minutes"),
        ("h", 3600, "hours"),
        ("d", 86400, "days"),
        ("w", 604_800, "weeks"),
    ]

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case notPositive(String)

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
            }
        }
    }

    /// `"90d"` → `7776000`.
    public static func seconds(from raw: String) throws(ParseError) -> TimeInterval {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let suffix = text.last, let unit = units.first(where: { $0.suffix == String(suffix) })
        else { throw .malformed(raw) }

        let digits = text.dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let count = Int(digits) else {
            throw .malformed(raw)
        }
        guard count > 0 else { throw .notPositive(raw) }
        return TimeInterval(count) * unit.seconds
    }
}
