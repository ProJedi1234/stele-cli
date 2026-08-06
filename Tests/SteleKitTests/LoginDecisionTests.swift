import Foundation
import Testing

@testable import SteleKit

/// The rule that decides what `auth login` puts on disk.
///
/// Worth testing at this altitude rather than through the command, because the command is in the
/// executable target and the executable target has no tests — and because the property being
/// asserted is not "the right message was printed" but "the credential that reaches the file is
/// the weakest one that does the job".
@Suite("login decisions")
struct LoginDecisionTests {
    private func summary(
        name: String = "claude-code",
        scopes: [String],
        shared: Bool? = nil
    ) -> ClientSummary {
        ClientSummary(name: name, scopes: scopes, shared: shared)
    }

    @Test("a publish-only credential is stored as it stands")
    func publishOnlyIsStored() {
        let decision = LoginDecision.decide(
            summary: summary(scopes: ["publish"]), keepAdmin: false, machineName: "argos"
        )
        #expect(decision == .store)
    }

    /// The path a machine takes today and must keep taking: nothing about this change may add a
    /// round trip to the login every agent machine already does.
    @Test("--admin does not disturb a publish-only credential")
    func publishOnlyIgnoresTheFlag() {
        let decision = LoginDecision.decide(
            summary: summary(scopes: ["publish"]), keepAdmin: true, machineName: "argos"
        )
        #expect(decision == .store)
    }

    @Test("an admin credential is spent, not stored")
    func adminIsMinted() {
        let decision = LoginDecision.decide(
            summary: summary(name: "shared-upload-token", scopes: ["admin"]),
            keepAdmin: false,
            machineName: "argos.olympus.lan"
        )
        #expect(decision == .mint(suggestedName: "argos", shared: true))
    }

    /// The case the README's claim rests on — "No agent holds `admin`" — and the one a rule
    /// keyed on the shared token's *name* would have missed entirely.
    @Test("a minted admin credential is spent too, whatever it is called")
    func namedAdminIsMinted() {
        let decision = LoginDecision.decide(
            summary: summary(name: "aditya-laptop", scopes: ["admin"]),
            keepAdmin: false,
            machineName: "argos"
        )
        #expect(decision == .mint(suggestedName: "argos", shared: false))
    }

    @Test("a credential carrying both scopes is still spent")
    func adminAndPublishIsMinted() {
        let decision = LoginDecision.decide(
            summary: summary(scopes: ["publish", "admin"]),
            keepAdmin: false,
            machineName: "argos"
        )
        #expect(decision == .mint(suggestedName: "argos", shared: false))
    }

    /// A scope this build has not heard of must not read as `admin`. `ClientSummary.scopes` is
    /// `[String]` precisely so the server can grow one without a coordinated release.
    @Test("an unknown scope is not admin")
    func unknownScopeIsNotAdmin() {
        let decision = LoginDecision.decide(
            summary: summary(scopes: ["publish", "delete"]),
            keepAdmin: false,
            machineName: "argos"
        )
        #expect(decision == .store)
    }

    @Test("--admin stores the admin credential, and says which kind it is")
    func keepAdminStores() {
        let shared = LoginDecision.decide(
            summary: summary(name: "shared-upload-token", scopes: ["admin"]),
            keepAdmin: true,
            machineName: "argos"
        )
        #expect(shared == .storeAdmin(shared: true))

        let minted = LoginDecision.decide(
            summary: summary(name: "aditya-laptop", scopes: ["admin"]),
            keepAdmin: true,
            machineName: "argos"
        )
        #expect(minted == .storeAdmin(shared: false))
    }

    /// The server's answer outranks the name, so a real client minted under that name is not
    /// described to the operator as configuration that vanishes on the next redeploy.
    @Test("the server's own shared flag wins over the name")
    func serverFlagWins() {
        let impostor = LoginDecision.decide(
            summary: summary(name: "shared-upload-token", scopes: ["admin"], shared: false),
            keepAdmin: true,
            machineName: "argos"
        )
        #expect(impostor == .storeAdmin(shared: false))

        let renamed = LoginDecision.decide(
            summary: summary(name: "bootstrap", scopes: ["admin"], shared: true),
            keepAdmin: true,
            machineName: "argos"
        )
        #expect(renamed == .storeAdmin(shared: true))
    }
}

/// Turning a hostname into a name the server accepts.
///
/// Every case here is one the server's `Client.validated(name:)` would answer with a `400`, and
/// the point of the suite is that a *suggestion this library invented* never earns one: the
/// prompt has to be answerable by pressing Return.
@Suite("suggested credential names")
struct SuggestedNameTests {
    @Test("the first label is the name")
    func firstLabelOnly() {
        #expect(LoginDecision.suggestedName(from: "argos.olympus.lan") == "argos")
        #expect(LoginDecision.suggestedName(from: "argos") == "argos")
    }

    @Test("case is folded and the alphabet is enforced")
    func alphabet() {
        #expect(LoginDecision.suggestedName(from: "Argos") == "argos")
        #expect(LoginDecision.suggestedName(from: "MacBook-Pro") == "macbook-pro")
        #expect(LoginDecision.suggestedName(from: "adityas_mbp") == "adityas-mbp")
    }

    /// Substituted rather than dropped, so two words do not silently become one.
    @Test("characters outside the alphabet become a hyphen, and runs collapse")
    func substitution() {
        #expect(LoginDecision.suggestedName(from: "aditya's mbp") == "aditya-s-mbp")
        #expect(LoginDecision.suggestedName(from: "a___b") == "a-b")
        #expect(LoginDecision.suggestedName(from: "héllo") == "h-llo")
    }

    @Test("leading and trailing hyphens are trimmed")
    func trimmed() {
        #expect(LoginDecision.suggestedName(from: "-argos-") == "argos")
        #expect(LoginDecision.suggestedName(from: "_argos_") == "argos")
    }

    @Test("a name is truncated to the server's limit, and never ends on the cut hyphen")
    func truncation() {
        let long = String(repeating: "a", count: 100)
        #expect(LoginDecision.suggestedName(from: long).count == 64)

        // 63 characters, then a hyphen at exactly the boundary: truncating alone would leave it
        // trailing, which is legal but reads as a slip.
        let awkward = String(repeating: "a", count: 63) + "-bcd"
        let name = LoginDecision.suggestedName(from: awkward)
        #expect(name == String(repeating: "a", count: 63))
    }

    /// A hostname with nothing usable in it still has to produce a name, because the alternative
    /// is a prompt whose default is the empty string.
    @Test("a hostname with nothing usable falls back")
    func fallback() {
        #expect(LoginDecision.suggestedName(from: "") == "agent")
        #expect(LoginDecision.suggestedName(from: "...") == "agent")
        #expect(LoginDecision.suggestedName(from: "___") == "agent")
    }

    /// The whole point, stated as the property rather than as examples: whatever comes out is
    /// something the server's rule accepts.
    @Test("every suggestion satisfies the server's alphabet and bounds")
    func suggestionsAreAlwaysValid() {
        let hostnames = [
            "argos.olympus.lan", "ARGOS", "aditya's mbp", "", "...", "-x-",
            String(repeating: "z", count: 200), "héllo.wörld", "1", "a-b_c.d.e",
        ]
        for hostname in hostnames {
            let name = LoginDecision.suggestedName(from: hostname)
            #expect(!name.isEmpty)
            #expect(name.count <= 64)
            #expect(name.first != "-")
            #expect(name.last != "-")
            #expect(name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        }
    }
}
