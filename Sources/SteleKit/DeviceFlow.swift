import Foundation

/// What the server hands back when a device sign-in is started: the two strings a human needs,
/// and the three machine values the poll loop runs on.
///
/// The GitHub OAuth app's client ID is not in here and never travels to this machine. The
/// server holds it, calls GitHub with it, and passes only this much through — which is the
/// whole reason the flow is proxied rather than run from the CLI. The access token GitHub
/// eventually issues is born and dies inside one server request; nothing in this process ever
/// holds it.
///
/// `verificationURI` is GitHub's, spelled the way the server spells it on the wire. It is
/// printed for a person to open by hand: see `DeviceSignIn` for why nothing here launches a
/// browser.
public struct DeviceCodeBundle: Decodable, Sendable, Equatable {
    /// The short code the user types into GitHub's page. Meant to be read aloud off a terminal,
    /// which is why it is the one value here that is deliberately shown.
    public let userCode: String
    /// Where they type it.
    public let verificationURI: String
    /// The handle this client polls with, and the one value in here worth withholding — see
    /// `description`.
    public let deviceCode: String
    /// Seconds GitHub asks to be left alone between polls.
    public let interval: Int
    /// Seconds until the user code stops being redeemable.
    public let expiresIn: Int

    public init(
        userCode: String,
        verificationURI: String,
        deviceCode: String,
        interval: Int,
        expiresIn: Int
    ) {
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

extension DeviceCodeBundle: CustomStringConvertible {
    /// Everything except the device code, which is redacted for `Token`'s reason in a smaller
    /// key: for the fifteen minutes it lives, anyone holding it can complete this sign-in and
    /// walk away with the credential it mints. It is not a stele token, so `Redaction` does not
    /// recognise it and would not scrub it out of a message this value was interpolated into —
    /// so the type declines to render it at all, and the poll loop passes it by hand.
    public var description: String {
        """
        DeviceCodeBundle(userCode: \(userCode), verificationURI: \(verificationURI), \
        deviceCode: \(Token.redaction), interval: \(interval), expiresIn: \(expiresIn))
        """
    }
}

/// One answer to one poll of the exchange route.
///
/// Three cases because the server collapses everything else into them: every terminal refusal —
/// the code expired, the user cancelled, the account is not an owner of this deployment, the
/// deployment has no owners — arrives as one byte-identical `401` and there is nothing left in
/// it to branch on. A `500` is not in here at all: that means the server could not reach GitHub,
/// which is a `SteleError` this client already knows how to describe, and it is thrown rather
/// than returned so a poll loop cannot mistake an outage for a refusal.
public enum DevicePoll: Sendable, Equatable {
    /// Nobody has authorised the code yet. Carries the interval the server asked for when it
    /// named one — GitHub's `slow_down` is a bigger number here and not a different case.
    case pending(interval: Int?)
    /// Authorised. The credential exists on the server and this is its only plaintext.
    case minted(MintedClient)
    /// Terminal, and this client is not told which of the several reasons it was.
    case refused
}

extension DevicePoll {
    public static func == (lhs: DevicePoll, rhs: DevicePoll) -> Bool {
        switch (lhs, rhs) {
        case (.pending(let a), .pending(let b)): return a == b
        case (.refused, .refused): return true
        // Compared by the name rather than by the credential: `MintedToken` is not `Equatable`
        // and should not become so — a `==` over a secret is a comparison somebody will reach
        // for as a check, and the answer to "is this the token I think it is" is a request to
        // the server.
        case (.minted(let a), .minted(let b)): return a.client == b.client
        default: return false
        }
    }
}

/// Waits for a person to approve a device sign-in, and hands back what it minted.
///
/// The loop is here rather than in the command for the reason every other decision is in
/// SteleKit: the executable target has no tests, and "does a `slow_down` actually slow the
/// polling down" is not a question worth answering by watching a terminal. `now` and `sleep`
/// are injected for the same reason `CredentialStore` takes `home` — a driver that read the
/// real clock could only be tested in real seconds.
///
/// Nothing in here opens a browser, and that is a decision rather than an omission. This
/// command runs on machines an agent is sitting on, over SSH, and inside containers, where
/// `xdg-open` either fails or — worse — opens the page on somebody else's display. The URL is
/// printed and a human decides where to open it.
public struct DeviceSignIn: Sendable {
    /// How a sign-in ended. Refusal and expiry are outcomes rather than errors because they are
    /// things the *user* did — cancelled, or walked away — and the command has a sentence for
    /// each. What is thrown out of `complete` is the other kind of failure: the server was
    /// unreachable, or answered something this client could not read.
    public enum Outcome: Sendable {
        case minted(MintedClient)
        /// The server said no, and said no more than that.
        case refused
        /// The code stopped being redeemable before anyone approved it.
        case expired
    }

    /// The shortest and longest a poll interval may be, whatever the server asks for.
    ///
    /// The floor keeps a server that answers `0` from becoming a hot loop against GitHub's rate
    /// limiter; the ceiling keeps one that answers a day from parking the command until the
    /// deadline. Both are guards against an answer this side cannot validate, not policy — the
    /// interval GitHub asks for is five seconds and every reasonable value passes through
    /// untouched.
    static let minimumInterval = 1
    static let maximumInterval = 60
    /// The longest this will wait for a person, whatever `expiresIn` claimed. GitHub's device
    /// codes live fifteen minutes; an hour is generous and finite.
    static let maximumLifetime: TimeInterval = 3600

    private let client: SteleClient
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        client: SteleClient,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        }
    ) {
        self.client = client
        self.now = now
        self.sleep = sleep
    }

    /// Polls until the sign-in is approved, refused, or out of time.
    ///
    /// Sleeps *before* the first poll, deliberately: the code has just been printed and nobody
    /// has had time to type it, so an immediate request can only be answered `pending` and
    /// spends one of GitHub's polls to learn nothing.
    public func complete(_ bundle: DeviceCodeBundle) async throws -> Outcome {
        let deadline = now().addingTimeInterval(
            min(Self.maximumLifetime, max(0, TimeInterval(bundle.expiresIn)))
        )
        var interval = Self.bounded(bundle.interval)

        while now() < deadline {
            // Never sleeps past the deadline, however large an interval was asked for. Without
            // this the expiry check above is advisory: one `interval` of 86400 would suspend
            // here until long after the code was dead.
            let remaining = deadline.timeIntervalSince(now())
            try await sleep(min(TimeInterval(interval), max(0, remaining)))

            switch try await client.redeemDeviceCode(bundle.deviceCode) {
            case .minted(let minted):
                return .minted(minted)
            case .refused:
                return .refused
            case .pending(let asked):
                // Only ever upward. `slow_down` is GitHub asking for more room and arrives as a
                // larger number; a smaller one is not an invitation to poll harder than the
                // interval the flow was started with.
                if let asked, Self.bounded(asked) > interval { interval = Self.bounded(asked) }
            }
        }
        return .expired
    }

    static func bounded(_ seconds: Int) -> Int {
        min(maximumInterval, max(minimumInterval, seconds))
    }
}
