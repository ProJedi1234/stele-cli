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
    /// `404` — a PUT to a slug that does not exist, a PATCH to one with no live page behind it
    /// (an expired page counts as none), or an unknown client name. The advice comes from the
    /// caller, because those three have nothing useful in common to say.
    case notFound(detail: String?, advice: String)
    /// `409` on a write — the requested slug is taken.
    ///
    /// The advice comes from the caller for the same reason `notFound`'s does, and it was the
    /// same mistake found twice: "omit `--slug` and let the server generate one" is the right
    /// next move on a `publish` and a false one on an `amend`, where omitting `--slug` means
    /// *do not rename* and no slug is ever allocated. An agent that took that branch would come
    /// back with a client-side "nothing to amend" and never reach the server at all.
    case slugTaken(detail: String?, advice: String)
    /// `409` on an admin route — a live credential already holds that name.
    ///
    /// Split from `slugTaken` rather than sharing it, because a `409` means two unrelated things
    /// on this server and the remedies have nothing in common: one is about the name a *page*
    /// wanted, and the other is "revoke the credential holding the name, or pick a different
    /// one". A single case answered `admin clients create` by naming a flag that command does
    /// not have.
    case nameTaken(String?)
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
    /// The host answered with a redirect to a different origin, and the client declined to
    /// carry the credential there. Distinct from `transportFailure`, whose message promises the
    /// credential was never sent — here it was sent, to the right host, which then pointed
    /// somewhere else.
    case redirected(host: SteleHost, destination: String)
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
        case .slugTaken(let detail, let advice):
            return "that slug is already taken\(Self.suffix(detail)) \(advice)"
        case .nameTaken(let detail):
            return """
                a live credential already has that name\(Self.suffix(detail)) Choose another \
                name, or retire the existing one with `stele admin clients revoke <name>` and \
                mint again — rotating a credential is revoke-then-mint under the same name.
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
                requires\(Self.suffix(detail)) Reinstall the CLI with \
                `make -C ~/repos/stele-cli install` and retry once.
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
        case .redirected(let host, let destination):
            return """
                \(host) answered with a redirect to \(destination), and stele does not follow a \
                redirect to another host — the credential would travel with it. Nothing was \
                sent there. Do not retry. If the deployment has really moved, ask the user to \
                run `stele auth login --host <its new URL>`; if it has not, something is \
                answering for \(host) that should not be.
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
        case 409: return expectation.conflict.error(detail)
        case 413: return .pageTooLarge(detail)
        case 415: return .unsupportedContentType(detail)
        case 426: return .upgradeRequired(detail)
        case 503: return .slugAllocationFailed(detail)
        default: return .unexpectedStatus(code: status, detail: detail)
        }
    }

    /// What the request was trying to do, for the three statuses whose advice depends on it.
    struct Expectation: Sendable {
        /// What is unique on this route, and therefore what a `409` says is already there.
        ///
        /// Named for the *resource* rather than for the error, because that is the thing the
        /// route knows about itself: `/pages` has slugs, `/admin/clients` has names, and a read
        /// has neither and should say so rather than pick one.
        enum Conflict: Sendable {
            /// A route where a slug is what collided, carrying what *this* route's caller can
            /// do about it. Two routes ask for a slug and they do not have the same escape: one
            /// can drop `--slug` and take whatever the server allocates, and the other cannot,
            /// because there dropping it means asking for no rename at all.
            case slug(advice: String)
            case name
            /// A route with nothing unique on it. A `409` here is a genuine surprise, and
            /// `unexpectedStatus` says exactly that instead of inventing advice.
            case none

            func error(_ detail: String?) -> SteleError {
                switch self {
                case .slug(let advice): return .slugTaken(detail: detail, advice: advice)
                case .name: return .nameTaken(detail)
                case .none: return .unexpectedStatus(code: 409, detail: detail)
                }
            }
        }

        /// The scope a `403` on this route implies was missing.
        var scope: Scope?
        /// What to do about a `404` here.
        var notFoundAdvice: String
        /// What a `409` here collided with.
        var conflict: Conflict

        static let write = Expectation(
            scope: .publish,
            notFoundAdvice: """
                `stele update` never creates a page — publish it with `stele publish` first.
                """,
            conflict: .slug(advice: """
                Choose another `--slug`, or omit it and let the server generate one.
                """)
        )
        /// A write too, and still `publish`-scoped, but it can borrow neither half of `write`'s
        /// advice. The `404`: that one names `stele update` and tells the reader to publish the
        /// page first, which is true of a replacement and misleading here — the `404` an
        /// amendment earns is usually a page that has *expired*, and the thing the reader has to
        /// be told is that this verb neither creates nor revives, otherwise the obvious next move
        /// is `--ttl never`, which will fail exactly the same way. The `409`: `publish`'s
        /// "omit it and let the server generate one" is an escape this route does not have.
        /// Omitting `--slug` on an amendment is not a request for any other name, it is a request
        /// for no rename — and on its own it is refused before the request is even sent.
        static let amend = Expectation(
            scope: .publish,
            notFoundAdvice: """
                `stele amend` only ever moves a page that is still live — it never creates one, \
                and it cannot bring back a page whose deadline has already passed, not even \
                with `--ttl never`. Check the slug, and publish the page again with \
                `stele publish --slug <name>` if it is gone.
                """,
            conflict: .slug(advice: """
                Another live page holds that name. Choose a different `--slug`: dropping it \
                asks for no rename rather than for another name, and an amendment never \
                allocates one of its own.
                """)
        )
        /// The third `publish`-scoped write, and the third route that cannot take `write`'s `404`
        /// as it stands. That one names `stele update` and tells the reader to publish the page
        /// first, which here is not merely the wrong command but the opposite instruction: an
        /// agent following it would recreate the very page it was asked to remove, and the run
        /// would end with the page live and nothing reading as a failure. What a `404` on a delete
        /// actually reports is that the work is already done — the page expired, or an earlier
        /// delete took it — so the advice names no follow-up command, because there is none to
        /// name. Its whole job is to stop the reader treating "already gone" as a problem of
        /// theirs to fix. The `409` is `.none` for the plainer reason: this route asks for no
        /// name, so there is nothing on it for a conflict to be about.
        static let delete = Expectation(
            scope: .publish,
            notFoundAdvice: """
                Nothing is published at that slug — it may have expired, or it may already have \
                been deleted. Either way the page is gone and there is nothing left to delete: \
                the server refuses to claim work it never did rather than answering yes to a \
                page it does not have. If you expected one there, the slug is the thing to check.
                """,
            conflict: .none
        )
        static let administration = Expectation(
            scope: .admin,
            notFoundAdvice: "Check the name against `stele admin clients list`.",
            conflict: .name
        )
        /// A read, or a route open to any valid credential.
        static let any = Expectation(
            scope: nil,
            notFoundAdvice: "Check that the host is a stele server and that the path exists.",
            conflict: .none
        )
    }
}
