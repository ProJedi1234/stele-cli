import Foundation
import Testing

@testable import SteleKit

/// Replies to each poll with the next scripted answer, and records what it was asked.
///
/// A queue rather than a closure over a counter, because every test in here is a *sequence* —
/// "pending, pending, then minted" is the shape of the whole feature, and a transport that
/// answers the same thing every time cannot express it. The last scripted answer repeats, so a
/// test about giving up does not have to script the give-up.
private actor ScriptedTransport: SteleTransport {
    private(set) var requests: [SteleRequest] = []
    private var replies: [SteleResponse]

    init(_ replies: [SteleResponse]) {
        self.replies = replies
    }

    init(status: Int, body: String = "") {
        self.replies = [SteleResponse(status: status, body: Data(body.utf8))]
    }

    func send(_ request: SteleRequest) async throws -> SteleResponse {
        requests.append(request)
        return replies.count > 1 ? replies.removeFirst() : replies[0]
    }

    var last: SteleRequest? { requests.last }
    var count: Int { requests.count }
}

private func response(_ status: Int, _ body: String = "") -> SteleResponse {
    SteleResponse(status: status, body: Data(body.utf8))
}

private let bundleJSON = """
    {"userCode":"WDJB-MJHT","verificationURI":"https://github.com/login/device",\
    "deviceCode":"3584d83530557fdd1f46af8289938c8ef79f9dc5","interval":5,"expiresIn":900}
    """

private let mintedJSON = """
    {"token":"stele_pat_minted","client":{"name":"projedi1234","scopes":["publish"],\
    "createdAt":"2026-08-25T10:00:00Z","githubLogin":"ProJedi1234"}}
    """

private func testHost() throws -> SteleHost {
    try SteleHost("https://stele.example.com")
}

private func testBundle(interval: Int = 5, expiresIn: Int = 900) -> DeviceCodeBundle {
    DeviceCodeBundle(
        userCode: "WDJB-MJHT",
        verificationURI: "https://github.com/login/device",
        deviceCode: "device-code",
        interval: interval,
        expiresIn: expiresIn
    )
}

@Suite("device sign-in requests")
struct DeviceSignInRequestTests {
    @Test("starting a sign-in posts to /auth/github/device with no body and no credential")
    func start() async throws {
        let transport = ScriptedTransport(status: 200, body: bundleJSON)
        let client = SteleClient(host: try testHost(), transport: transport)

        let bundle = try await client.startDeviceSignIn()

        #expect(bundle.userCode == "WDJB-MJHT")
        #expect(bundle.verificationURI == "https://github.com/login/device")
        #expect(bundle.interval == 5)
        #expect(bundle.expiresIn == 900)
        let request = try #require(await transport.last)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://stele.example.com/auth/github/device")
        #expect(request.body == nil)
        // The route is the one place this client has nothing to present. A credential sent here
        // would be one the deployment never asked for, on the request whose whole premise is
        // that there is not one yet.
        #expect(request.headerFields()["Authorization"] == nil)
    }

    /// The deployment declining, which is what `auth login` reads as "fall back to a token".
    /// It is the same answer a refused sign-in gets, by the server's design, and it has to reach
    /// the caller as an ordinary `unauthorized` rather than as anything cleverer — there is
    /// nothing in it to be clever about.
    @Test("a deployment with no GitHub sign-in configured refuses the start route")
    func startRefused() async throws {
        let transport = ScriptedTransport(status: 401, body: #"{"error":{"message":"refused"}}"#)
        let client = SteleClient(host: try testHost(), transport: transport)

        await #expect(throws: SteleError.unauthorized) {
            _ = try await client.startDeviceSignIn()
        }
    }

    /// The field name is the whole contract of this body, and a misspelling of it is a `400`
    /// rather than a silent nothing — but only because the server has one required field. Read
    /// back off the encoded bytes for `CreateClientRequest`'s reason: a wire mismatch that
    /// travels is not one any assertion about the call arguments would notice.
    @Test("a poll posts the device code to /auth/github/exchange, and nothing else")
    func poll() async throws {
        let transport = ScriptedTransport(status: 202, body: #"{"interval":5}"#)
        let client = SteleClient(host: try testHost(), transport: transport)

        _ = try await client.redeemDeviceCode("device-code")

        let request = try #require(await transport.last)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://stele.example.com/auth/github/exchange")
        #expect(request.headerFields()["Content-Type"] == "application/json")
        #expect(request.headerFields()["Authorization"] == nil)
        let body = try #require(request.body)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(decoded == ["deviceCode": "device-code"])
    }

    @Test("a 201 carries the minted credential")
    func minted() async throws {
        let transport = ScriptedTransport(status: 201, body: mintedJSON)
        let client = SteleClient(host: try testHost(), transport: transport)

        guard case .minted(let minted) = try await client.redeemDeviceCode("device-code") else {
            Issue.record("expected a minted credential")
            return
        }
        #expect(minted.client.name == "projedi1234")
        #expect(minted.client.githubLogin == "ProJedi1234")
        #expect(minted.token.secret == "stele_pat_minted")
    }

    @Test("a 202 is pending and carries the interval the server asked for")
    func pending() async throws {
        let transport = ScriptedTransport(status: 202, body: #"{"interval":10}"#)
        let client = SteleClient(host: try testHost(), transport: transport)

        #expect(try await client.redeemDeviceCode("device-code") == .pending(interval: 10))
    }

    /// The interval is advice on top of one the flow already has, so a `202` this client cannot
    /// read is still a perfectly good "keep waiting". Failing here would end a sign-in that is
    /// going fine over a field that only ever slows the polling down.
    @Test(
        "a 202 with nothing readable in it is still pending",
        arguments: ["", "{}", "not json at all", #"{"interval":"soon"}"#]
    )
    func pendingWithoutAnInterval(_ body: String) async throws {
        let transport = ScriptedTransport(status: 202, body: body)
        let client = SteleClient(host: try testHost(), transport: transport)

        #expect(try await client.redeemDeviceCode("device-code") == .pending(interval: nil))
    }

    /// Every terminal refusal is one byte-identical `401` on the server, so there is nothing to
    /// describe and nothing to retry — which is why this is an outcome rather than a thrown
    /// error. The loop stops on it.
    @Test("a 401 is a refusal, not an error")
    func refused() async throws {
        let transport = ScriptedTransport(status: 401, body: #"{"error":{"message":"refused"}}"#)
        let client = SteleClient(host: try testHost(), transport: transport)

        #expect(try await client.redeemDeviceCode("device-code") == .refused)
    }

    /// The counterpart, and the one worth asserting as an inequality. A `500` means the server
    /// could not reach GitHub — an outage, on a sign-in that may well succeed in a minute — and
    /// folding it into `.refused` would tell a user their login was rejected and send them round
    /// the loop again. It throws, so the loop cannot mistake it for an answer.
    @Test("a 500 throws rather than reporting a refusal")
    func outage() async throws {
        let transport = ScriptedTransport(status: 500, body: #"{"error":{"message":"github"}}"#)
        let client = SteleClient(host: try testHost(), transport: transport)

        await #expect(throws: SteleError.self) {
            _ = try await client.redeemDeviceCode("device-code")
        }
    }
}

/// A clock and a sleep that cost no time.
///
/// The point of injecting them: "does `slow_down` actually slow the polling down" and "does this
/// give up when the code expires" are the two questions this feature has, and both are about
/// seconds. Answered against a real clock they would take fifteen minutes and answer nothing.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Date(timeIntervalSince1970: 0)
    private var slept: [TimeInterval] = []

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return moment
    }

    var intervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return slept
    }

    /// Advances the clock by exactly what was waited for, so the deadline arrives after the
    /// number of polls the interval says it should.
    func sleep(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        slept.append(seconds)
        moment = moment.addingTimeInterval(seconds)
    }
}

private func signIn(
    replying replies: [SteleResponse],
    clock: FakeClock
) throws -> (DeviceSignIn, ScriptedTransport) {
    let transport = ScriptedTransport(replies)
    let client = SteleClient(host: try testHost(), transport: transport)
    return (
        DeviceSignIn(
            client: client,
            now: { clock.now },
            sleep: { clock.sleep($0) }
        ),
        transport
    )
}

@Suite("waiting for a device sign-in")
struct DeviceSignInLoopTests {
    @Test("polls until the sign-in is approved")
    func approved() async throws {
        let clock = FakeClock()
        let (flow, transport) = try signIn(
            replying: [
                response(202, #"{"interval":5}"#),
                response(202, #"{"interval":5}"#),
                response(201, mintedJSON),
            ],
            clock: clock
        )

        guard case .minted(let minted) = try await flow.complete(testBundle()) else {
            Issue.record("expected a minted credential")
            return
        }
        #expect(minted.client.name == "projedi1234")
        #expect(await transport.count == 3)
    }

    /// The first request cannot be answered anything but `pending` — the code was printed a
    /// moment ago and nobody has had time to type it — so the loop waits first and spends no
    /// poll learning that.
    @Test("waits before the first poll, at the interval the start response named")
    func waitsFirst() async throws {
        let clock = FakeClock()
        let (flow, _) = try signIn(replying: [response(201, mintedJSON)], clock: clock)

        _ = try await flow.complete(testBundle(interval: 7))

        #expect(clock.intervals == [7])
    }

    /// `slow_down` is GitHub asking for more room, and it arrives as a larger number rather than
    /// as a case of its own. Nothing here needs to know which of the two pending answers it got.
    @Test("a bigger interval slows the polling down")
    func slowsDown() async throws {
        let clock = FakeClock()
        let (flow, _) = try signIn(
            replying: [
                response(202, #"{"interval":5}"#),
                response(202, #"{"interval":10}"#),
                response(202, #"{"interval":10}"#),
                response(201, mintedJSON),
            ],
            clock: clock
        )

        _ = try await flow.complete(testBundle(interval: 5))

        #expect(clock.intervals == [5, 5, 10, 10])
    }

    /// The other direction, which is the one that would be a mistake. An interval is a floor the
    /// server asks for, so a smaller number later in the flow is not permission to poll harder
    /// than the flow began with — and a `202` carrying no interval at all is not permission
    /// either, which is what the nil case pins.
    @Test("a smaller interval, or none, never speeds it up")
    func neverSpeedsUp() async throws {
        let clock = FakeClock()
        let (flow, _) = try signIn(
            replying: [
                response(202, #"{"interval":1}"#),
                response(202, "{}"),
                response(201, mintedJSON),
            ],
            clock: clock
        )

        _ = try await flow.complete(testBundle(interval: 10))

        #expect(clock.intervals == [10, 10, 10])
    }

    @Test("a refusal ends the wait at once")
    func refused() async throws {
        let clock = FakeClock()
        let (flow, transport) = try signIn(replying: [response(401)], clock: clock)

        guard case .refused = try await flow.complete(testBundle()) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(await transport.count == 1)
    }

    /// Giving up is what stops this command waiting for a person who has walked away. The
    /// arithmetic is the assertion: a thirty-second code polled every five seconds is six polls
    /// and then a verdict, not a seventh poll and not an endless loop.
    @Test("gives up when the code expires")
    func expires() async throws {
        let clock = FakeClock()
        let (flow, transport) = try signIn(
            replying: [response(202, #"{"interval":5}"#)], clock: clock
        )

        guard case .expired = try await flow.complete(testBundle(interval: 5, expiresIn: 30))
        else {
            Issue.record("expected the sign-in to expire")
            return
        }
        #expect(await transport.count == 6)
    }

    /// The expiry check is only as good as the sleeps it interrupts: one interval of a day would
    /// suspend the command until long after the code was dead, and the loop would then report an
    /// expiry it had spent a day arriving at. So a wait is clamped to what is left, and the
    /// ceiling on the interval itself is what keeps that from being the only guard.
    @Test("never waits past the deadline, whatever interval it is handed")
    func neverWaitsPastTheDeadline() async throws {
        let clock = FakeClock()
        let (flow, _) = try signIn(
            replying: [response(202, #"{"interval":86400}"#)], clock: clock
        )

        _ = try await flow.complete(testBundle(interval: 86400, expiresIn: 30))

        #expect(clock.intervals.reduce(0, +) <= 30)
    }

    /// Bounds rather than policy: an interval this side cannot validate should not become a hot
    /// loop against GitHub's rate limiter, nor a command parked until the deadline. Every value
    /// GitHub actually sends passes through untouched.
    @Test(
        "an absurd interval is bounded at both ends",
        arguments: [(0, 1), (-5, 1), (5, 5), (60, 60), (86400, 60)]
    )
    func bounds(_ asked: Int, _ used: Int) {
        #expect(DeviceSignIn.bounded(asked) == used)
    }

    @Test("every poll presents the device code from the start response")
    func carriesTheCode() async throws {
        let clock = FakeClock()
        let (flow, transport) = try signIn(
            replying: [response(202, #"{"interval":5}"#), response(201, mintedJSON)],
            clock: clock
        )

        _ = try await flow.complete(testBundle())

        let bodies = await transport.requests.compactMap(\.body)
        #expect(bodies.count == 2)
        for body in bodies {
            #expect(String(data: body, encoding: .utf8)?.contains("device-code") == true)
        }
    }
}

@Suite("device code custody")
struct DeviceCodeCustodyTests {
    /// The device code is not a stele token, so `Redaction` does not recognise it and would not
    /// scrub it out of anything this value were interpolated into. For the quarter of an hour it
    /// lives, whoever holds it can finish this sign-in and take the credential it mints — so the
    /// type declines to render it, and the poll loop passes it by hand instead.
    @Test("printing the bundle does not print the device code")
    func redacted() {
        let bundle = testBundle()
        let printed = "\(bundle)"

        #expect(!printed.contains("device-code"))
        #expect(printed.contains(Token.redaction))
        // The half that is meant to be shown, and the reason this is a redaction rather than a
        // refusal to print: the user code and the URL are what a person is asked to read.
        #expect(printed.contains("WDJB-MJHT"))
        #expect(printed.contains("https://github.com/login/device"))
    }
}
