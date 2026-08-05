import Foundation

/// Everything a stele server can say no with, plus the two ways a request can fail without
/// reaching one.
///
/// One case per outcome the caller has a *different response* to, which is a narrower set than
/// "one case per status code the server might emit" — `unexpectedStatus` catches the rest,
/// because inventing a case for a status this client has no advice about would only produce a
/// message pretending to know something. Every description ends in an instruction, since the
/// primary reader is an agent deciding whether to retry, change the input, or stop and ask the
/// user; "409 Conflict" tells it none of those things. The wording tracks the status table in
/// the server's own skill document, which is what the agent will have read.
///
/// The associated values are the server's message and nothing else. No case carries a
/// credential, and none can: `Token` has no public accessor that yields its plaintext, and
/// every server-supplied string is put through `Redaction.scrub` before it gets here.
public enum SteleError: Error, Equatable, CustomStringConvertible {
    /// `400` — a bad slug, an empty body, non-UTF-8, or a NUL byte.
    case badRequest(String?)
    /// `401` — the credential was refused. Carries nothing: unknown, revoked and expired are
    /// one answer from the server by design, and the client has nothing to add.
    case unauthorized
    /// `403` — a valid credential without the scope this operation needs.
    case forbidden(missing: Scope?, detail: String?)
    /// `404` — a PUT to a slug that does not exist, or an unknown client name. The advice
    /// comes from the caller, because those two have nothing useful in common to say.
    case notFound(detail: String?, advice: String)
    /// `409` — the requested slug is taken.
    case slugTaken(String?)
    /// `413` — the page is over the server's byte limit.
    case pageTooLarge(String?)
    /// `415` — the content type is not on the server's allowlist.
    case unsupportedContentType(String?)
    /// `426` — this build of the CLI is older than the server's `minimumCLIVersion`.
    case upgradeRequired(String?)
    /// `503` — the server could not allocate a slug.
    case slugAllocationFailed(String?)
    /// A status with no specific advice attached to it.
    case unexpectedStatus(code: Int, detail: String?)
    /// The request never got an answer: DNS, connection refused, TLS, timeout.
    case transportFailure(host: SteleHost, reason: String)
    /// A 2xx whose body was not what this client expects — a proxy's landing page, a server
    /// too new or too old to share a shape.
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .badRequest(let detail):
            return """
                the server rejected the request\(Self.suffix(detail)) Fix the input and try \
                again — retrying it unchanged will fail the same way.
                """
        case .unauthorized:
            // Never says *which* credential, and has no room to: the case holds no payload.
            // A 401 is also the one server answer that carries no detail through, since the
            // useful next step is entirely local.
            return """
                the credential was rejected — it may have been revoked, or it may have \
                expired. Do not retry. Ask the user to run `stele auth login`.
                """
        case .forbidden(let missing, let detail):
            let scope = missing.map { " It needs the `\($0.rawValue)` scope." } ?? ""
            return """
                this credential is valid but is not allowed to do that.\(scope) Agent \
                credentials carry `\(Scope.publish.rawValue)` only; ask the user to run this \
                one with an operator credential.\(Self.suffix(detail, leading: " "))
                """
        case .notFound(let detail, let advice):
            return "the server has nothing there\(Self.suffix(detail)) \(advice)"
        case .slugTaken(let detail):
            return """
                that slug is already taken\(Self.suffix(detail)) Choose another `--slug`, or \
                omit it and let the server generate one.
                """
        case .pageTooLarge(let detail):
            return """
                the page is over the server's size limit\(Self.suffix(detail)) Drop inline \
                images and link them instead — the limit is on the HTML, and a data: URI \
                counts against it.
                """
        case .unsupportedContentType(let detail):
            return """
                the server will not store that content type\(Self.suffix(detail)) Publish one \
                of the types it lists, or leave the type to the CLI.
                """
        case .upgradeRequired(let detail):
            return """
                this stele build (\(SteleVersion.current)) is older than the server \
                requires\(Self.suffix(detail)) Reinstall the CLI with `make install` in the \
                stele-cli checkout, then retry once.
                """
        case .slugAllocationFailed(let detail):
            return """
                the server could not allocate a slug\(Self.suffix(detail)) Retry once, or \
                pass `--slug` to name the page yourself.
                """
        case .unexpectedStatus(let code, let detail):
            return """
                the server answered \(code), which this client has no advice \
                for\(Self.suffix(detail)) Retry once; if it persists, check the server's logs.
                """
        case .transportFailure(let host, let reason):
            return """
                could not reach \(host): \(reason). Check that the host is right and that the \
                server is up — the credential was never sent.
                """
        case .malformedResponse(let reason):
            return """
                the server's answer was not in the expected form: \(reason). That usually \
                means something other than stele answered — check the host.
                """
        }
    }

    /// Renders the server's own message as a clause, or closes the sentence when there is none.
    ///
    /// Every description reads as prose in both cases, which matters because the message is
    /// the *specific* half — "invalid slug: contains '_'" — and this client's advice is the
    /// general half. Losing either one leaves the reader guessing.
    private static func suffix(_ detail: String?, leading: String = "") -> String {
        guard let detail, !detail.isEmpty else { return leading.isEmpty ? "." : "" }
        return "\(leading.isEmpty ? ": " : leading)\(detail.hasSuffix(".") ? detail : detail + ".")"
    }
}

extension SteleError {
    /// Maps a response onto an error, or nil when the server said yes.
    ///
    /// `expectation` names the operation so `403` and `404` — the two statuses whose meaning
    /// depends on what was asked — can say something true. Everything else means the same
    /// thing on every route.
    static func from(status: Int, detail: String?, expectation: Expectation) -> SteleError? {
        guard !(200..<300).contains(status) else { return nil }
        switch status {
        case 400: return .badRequest(detail)
        case 401: return .unauthorized
        case 403: return .forbidden(missing: expectation.scope, detail: detail)
        case 404: return .notFound(detail: detail, advice: expectation.notFoundAdvice)
        case 409: return .slugTaken(detail)
        case 413: return .pageTooLarge(detail)
        case 415: return .unsupportedContentType(detail)
        case 426: return .upgradeRequired(detail)
        case 503: return .slugAllocationFailed(detail)
        default: return .unexpectedStatus(code: status, detail: detail)
        }
    }

    /// What the request was trying to do, for the two statuses whose advice depends on it.
    struct Expectation: Sendable {
        /// The scope a `403` on this route implies was missing.
        var scope: Scope?
        /// What to do about a `404` here.
        var notFoundAdvice: String

        static let write = Expectation(
            scope: .publish,
            notFoundAdvice: """
                `stele update` never creates a page — publish it with `stele publish` first.
                """
        )
        static let administration = Expectation(
            scope: .admin,
            notFoundAdvice: "Check the name against `stele admin clients list`."
        )
        /// A read, or a route open to any valid credential.
        static let any = Expectation(
            scope: nil,
            notFoundAdvice: "Check that the host is a stele server and that the path exists."
        )
    }
}
