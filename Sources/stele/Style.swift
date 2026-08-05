import Foundation
import SteleKit

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Terminal styling, gated on the environment rather than on a config flag.
///
/// Both inputs are parameters with defaults rather than reads buried in the body, so the whole
/// decision can be exercised without a terminal — the same reason `CredentialStore` takes
/// `home`. Colour never carries information that the text does not: strip every escape and the
/// output says the same thing, which is what makes `--json` and a redirected stdout safe.
struct Style: Sendable {
    enum Depth: Sendable { case none, ansi256, truecolor }

    let depth: Depth

    /// `#0f766e`, the `--stele-accent` the server's own stylesheet ships. One accent across the
    /// pages and the tool that publishes them.
    private static let accentRGB = (r: 15, g: 118, b: 110)
    private static let accent256: UInt8 = 30

    static func detect(
        env: [String: String] = ProcessInfo.processInfo.environment,
        isTTY: Bool = isatty(STDOUT_FILENO) == 1
    ) -> Style {
        guard isTTY else { return Style(depth: .none) }
        if env["NO_COLOR"] != nil { return Style(depth: .none) }
        let term = env["TERM"] ?? ""
        if term.isEmpty || term == "dumb" { return Style(depth: .none) }
        let colorterm = (env["COLORTERM"] ?? "").lowercased()
        if colorterm.contains("truecolor") || colorterm.contains("24bit") {
            return Style(depth: .truecolor)
        }
        return Style(depth: .ansi256)
    }

    private func wrap(_ text: String, _ code: String) -> String {
        depth == .none ? text : "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    /// Chrome only — never used to signal state.
    func accent(_ text: String) -> String {
        switch depth {
        case .none: return text
        case .ansi256: return wrap(text, "38;5;\(Self.accent256)")
        case .truecolor:
            return wrap(text, "38;2;\(Self.accentRGB.r);\(Self.accentRGB.g);\(Self.accentRGB.b)")
        }
    }

    func bold(_ text: String) -> String { wrap(text, "1") }
    func dim(_ text: String) -> String { wrap(text, "2") }

    // Semantic colours carry outcome and nothing else.
    func good(_ text: String) -> String { wrap(text, "32") }
    func warn(_ text: String) -> String { wrap(text, "33") }
    func bad(_ text: String) -> String { wrap(text, "31") }

    /// How a credential's health reads at a glance. The words are the same ones
    /// `stele admin clients list` puts in its STATE column and `--json` puts in `state`.
    func state(_ summary: ClientSummary, at moment: Date = Date()) -> String {
        if summary.isRevoked { return bad(Format.state(summary, at: moment)) }
        if summary.isExpired(at: moment) { return warn(Format.state(summary, at: moment)) }
        return good(Format.state(summary, at: moment))
    }
}

enum Format {
    /// Pads to `width`, truncating with an ellipsis when too long.
    static func pad(_ text: String, _ width: Int) -> String {
        if text.count > width {
            guard width > 1 else { return String(text.prefix(width)) }
            return String(text.prefix(width - 1)) + "…"
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    /// The JSON every `--json` path emits.
    ///
    /// ISO 8601 out, matching what `JSONDecoder.stele` accepts coming in, so a `--json` blob
    /// this tool prints is a blob it could read back. Sorted keys because a diff between two
    /// runs should show what changed and not what got rehashed.
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// One word for a credential's health, shared by the human table and the JSON.
    static func state(_ summary: ClientSummary, at moment: Date = Date()) -> String {
        if summary.isRevoked { return "revoked" }
        if summary.isExpired(at: moment) { return "expired" }
        return "active"
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed locale and a fixed format: this is a column in a table an operator scans, not
        // prose, and a machine-parsable timestamp is more use than a localised one.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// A timestamp for the human output, or a dash. Never "now" arithmetic in the table itself
    /// — "3 weeks ago" is friendlier and worse, because the follow-up question is always "so
    /// what date is that".
    static func moment(_ date: Date?) -> String {
        date.map { timestamp.string(from: $0) } ?? "—"
    }

    /// `~/.config/stele/credentials.json` rather than the absolute path, for output a user is
    /// meant to recognise.
    static func tildify(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
