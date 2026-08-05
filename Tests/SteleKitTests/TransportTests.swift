import Foundation
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import SteleKit

/// The one canary in this file. Distinctive enough that finding it in a socket's bytes cannot be
/// a coincidence, and shaped like a real credential so nothing under test can be excused by
/// "that is not what a token looks like".
private let canary = "stele_pat_WIRE-canary_0000000000000000000000"

/// A real HTTP server on a loopback port, one connection at a time.
///
/// The only test in the suite that speaks TCP, and it has to: `URLSessionTransport` is the one
/// component whose behaviour lives entirely in `URLSession`'s own request handling, so a fake
/// transport — which is how every other test reaches the client — tests the seam and not the
/// thing. Redirect following in particular is a decision `URLSession` makes without asking, and
/// the only way to observe what it did with the `Authorization` header is to be the host it
/// handed it to.
private final class StubServer: @unchecked Sendable {
    /// The loopback port this ended up bound to.
    let port: Int

    private let descriptor: Int32
    private let lock = NSLock()
    private var received: [String] = []

    struct StartupError: Error { let step: String }

    /// - Parameter reply: the request head that was read, in; the raw response to write, out.
    init(reply: @escaping @Sendable (String) -> String) throws {
        // Writing to a socket the client has already closed raises SIGPIPE, which by default
        // takes the whole test process with it.
        signal(SIGPIPE, SIG_IGN)

        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        // A local until the whole thing is set up: the pointer dances below are closures, and a
        // closure that reads `self.descriptor` is a closure capturing a half-initialised `self`.
        let listener = socket(AF_INET, stream, 0)
        guard listener >= 0 else { throw StartupError(step: "socket") }

        var reuse: Int32 = 1
        setsockopt(
            listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // Port 0: the kernel picks a free one, which is the only way several of these can run in
        // the same test run without a hard-coded port to collide on.
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0 else { close(listener); throw StartupError(step: "bind") }
        guard listen(listener, 8) == 0 else { close(listener); throw StartupError(step: "listen") }

        var actual = sockaddr_in()
        var length = size
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        descriptor = listener
        port = Int(UInt16(bigEndian: actual.sin_port))

        let thread = Thread { [self] in accept(reply) }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Every request head this server has read, in the order it read them. The assertion that
    /// matters is usually that this is *empty*.
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func stop() {
        // Closing the listening socket is what ends the accept loop.
        close(descriptor)
    }

    deinit { stop() }

    private func accept(_ reply: @escaping @Sendable (String) -> String) {
        while true {
            let connection = Glibc_accept(descriptor)
            guard connection >= 0 else { return }

            var head = ""
            var buffer = [UInt8](repeating: 0, count: 4096)
            // Only as far as the end of the headers. This never needs a body, and stopping there
            // avoids having to parse a length to know when a request is over.
            while !head.contains("\r\n\r\n") {
                let count = recv(connection, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                head += String(decoding: buffer[0..<count], as: UTF8.self)
            }
            lock.lock()
            received.append(head)
            lock.unlock()

            var response = Array(reply(head).utf8)
            _ = send(connection, &response, response.count, 0)
            close(connection)
        }
    }

    /// `accept(2)` under a name that does not collide with the method above it.
    private func Glibc_accept(_ descriptor: Int32) -> Int32 {
        #if canImport(Glibc)
        return Glibc.accept(descriptor, nil, nil)
        #else
        return Darwin.accept(descriptor, nil, nil)
        #endif
    }
}

private func response(status: String, headers: [String: String] = [:], body: String = "") -> String {
    var lines = ["HTTP/1.1 \(status)"]
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
    lines.append("Content-Length: \(body.utf8.count)")
    lines.append("Connection: close")
    return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
}

private let whoami = response(
    status: "200 OK",
    headers: ["Content-Type": "application/json"],
    body: #"{"name":"claude-code","scopes":["publish"]}"#
)

@Suite("the real transport")
struct TransportTests {
    private func credential(port: Int) throws -> Credential {
        Credential(
            host: try SteleHost("http://127.0.0.1:\(port)"),
            clientName: "claude-code",
            token: try Token(canary)
        )
    }

    /// The finding this file was written for.
    ///
    /// `SteleClient` documents that "a token is only ever sent to the deployment it was filed
    /// under", and before the redirect policy existed that was true of how URLs were *built* and
    /// false of what went out on the wire: `URLSession` follows a 3xx by itself and copies the
    /// request's headers onto the redirected request, `Authorization` included. So anything able
    /// to answer for the configured host — a compromised proxy, an `http://` deployment on an
    /// untrusted network, a name someone else now owns — could collect the credential by
    /// replying `302`, while the caller saw an ordinary success.
    ///
    /// The two servers differ only in port, which is deliberate: a policy that compared hostnames
    /// alone would pass this test while leaving the same hole open on any host with two ports.
    @Test("a redirect to another origin is refused, and the credential does not follow")
    func refusesCrossOriginRedirect() async throws {
        let target = try StubServer { _ in whoami }
        defer { target.stop() }
        let redirector = try StubServer { [port = target.port] _ in
            response(
                status: "302 Found",
                headers: ["Location": "http://127.0.0.1:\(port)/admin/whoami"]
            )
        }
        defer { redirector.stop() }

        let credential = try credential(port: redirector.port)
        let client = SteleClient(credential: credential, transport: URLSessionTransport())

        var caught: (any Error)?
        do {
            _ = try await client.verifyCredential(credential)
        } catch {
            caught = error
        }

        // The redirect is reported as itself, not as "the server answered 302, which this client
        // has no advice for" — the operator needs to know something is answering for their host.
        guard case .redirected(let host, let destination)? = caught as? SteleError else {
            Issue.record("expected a redirected error, got \(String(describing: caught))")
            return
        }
        #expect(host.value == "http://127.0.0.1:\(redirector.port)")
        #expect(destination.contains("\(target.port)"))

        // The assertion the rest of it exists for.
        #expect(target.requests.isEmpty)
        for request in target.requests { #expect(!request.contains(canary)) }

        // And the counter-assertion: the token really was on the wire to the host it was filed
        // under, so "the other server saw nothing" is a fact about the policy and not about a
        // request that never carried a credential in the first place.
        let sent = try #require(redirector.requests.first)
        #expect(sent.contains("Authorization: Bearer \(canary)"))
    }

    /// The other half of the rule. Refusing every redirect would also have passed the test above,
    /// and would have made the client brittle against a deployment that redirects within itself.
    @Test("a redirect within the same origin is followed, credential and all")
    func followsSameOriginRedirect() async throws {
        let server = try StubServer { request in
            request.contains("GET /moved")
                ? whoami
                : response(status: "302 Found", headers: ["Location": "/moved"])
        }
        defer { server.stop() }

        let credential = try credential(port: server.port)
        let client = SteleClient(credential: credential, transport: URLSessionTransport())

        let summary = try await client.verifyCredential(credential)

        #expect(summary.name == "claude-code")
        #expect(server.requests.count == 2)
        #expect(try #require(server.requests.last).contains("Authorization: Bearer \(canary)"))
    }

    /// A server that answers normally still works through the same session — the policy is a
    /// delegate on the shared session, and a delegate that mishandled a non-redirect callback
    /// would break every request rather than only the redirecting ones.
    @Test("an ordinary answer is unaffected")
    func ordinaryRequestSucceeds() async throws {
        let server = try StubServer { _ in whoami }
        defer { server.stop() }

        let credential = try credential(port: server.port)
        let client = SteleClient(credential: credential, transport: URLSessionTransport())

        #expect(try await client.verifyCredential(credential).scopes == ["publish"])
    }
}
