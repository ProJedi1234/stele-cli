import Foundation

/// What `auth login` should do with a credential the server has just vouched for.
///
/// A value rather than a branch inside the command, for the reason every other decision in this
/// tool lives in `SteleKit`: the executable target has no tests. `LoginCommand` is where the
/// prompting and the printing happen, and a rule about *which credential ends up on disk* is not
/// a rule that should only be exercised by running the binary by hand.
///
/// The rule itself is one sentence: an `admin` token is not a credential to store, it is the one
/// thing that can mint credentials. Storing it puts the credential that revokes every other
/// credential on a machine whose whole purpose is to hold the weakest one — and if it is the
/// server's shared `STELE_UPLOAD_TOKEN`, it is not even durable, since that value is
/// configuration and changes the next time the deployment is redeployed.
public enum LoginDecision: Sendable, Equatable {
    /// A publish-only credential. File it as it stands.
    case store

    /// An `admin` credential, with no instruction to keep it. Spend it: mint a publish-only
    /// credential for this machine and store that instead. The name is a suggestion for the
    /// prompt, not a decision — the person at the terminal gets the last word on it.
    ///
    /// `shared` rides along for the same reason it does on `storeAdmin`: the command has to
    /// explain what was pasted before it acts on it, and only the bootstrap token gets the
    /// sentence about not surviving a redeploy. Carried here rather than re-derived at the call
    /// site so there is one answer to "which kind of credential is this" and not two.
    case mint(suggestedName: String, shared: Bool)

    /// An `admin` credential, and `--admin` says that is deliberate. `shared` distinguishes the
    /// server's bootstrap token from a minted admin credential, because only one of the two
    /// stops working on the next redeploy and the warning should not claim otherwise.
    case storeAdmin(shared: Bool)

    /// The name the server reports for `STELE_UPLOAD_TOKEN`.
    ///
    /// A string contract with another repository, which is what makes it worth naming here
    /// rather than spelling inline: it is `Client.sharedToken` in the server's
    /// `BearerTokenMiddleware`, a credential synthesised at request time with no row behind it.
    /// `ClientSummary.shared` supersedes it the day the server ships that field — see
    /// `isShared(_:)`.
    public static let sharedClientName = "shared-upload-token"

    /// The longest name the server will accept, mirrored from its `Client.maxNameLength`.
    ///
    /// A copy of a server rule, which this codebase otherwise refuses to keep — the slug rules
    /// and the maximum page lifetime both live on the server precisely so a stale copy here
    /// cannot drift. The difference is who typed the value. A name the *user* types is sent as
    /// they wrote it and earns a `400` naming the real limit; this constant only bounds a
    /// default this library invented, and offering a suggestion we already know the server will
    /// reject would be a prompt that cannot be answered by pressing Return.
    static let suggestedNameLimit = 64

    /// The name a machine with nothing usable in its hostname gets.
    static let fallbackName = "agent"

    /// - Parameters:
    ///   - keepAdmin: `--admin`. Storing an admin credential stays possible — the operator's own
    ///     workstation is where `stele admin clients …` is run from, and `Credentials` is keyed
    ///     by host, so that machine holds admin *or* publish for a deployment and never both.
    ///     It is opt-in rather than the default because the machine that most often runs this
    ///     command is the one an agent publishes from.
    ///   - machineName: this machine's hostname, passed in rather than read here for the same
    ///     reason `CredentialStore` takes `home` — a decision that reads the environment is a
    ///     decision that can only be tested on the machine it was written on.
    public static func decide(
        summary: ClientSummary,
        keepAdmin: Bool,
        machineName: String
    ) -> LoginDecision {
        // Keyed on the scope and not on the name. `admin` is the property that matters — it is
        // what makes the credential able to mint and revoke — and a minted admin credential
        // carries it under a name chosen by whoever minted it. Recognising only the shared
        // token would leave the case this tool's own README calls out ("No agent holds `admin`")
        // entirely unguarded.
        guard summary.has(.admin) else { return .store }
        guard !keepAdmin else { return .storeAdmin(shared: isShared(summary)) }
        return .mint(
            suggestedName: suggestedName(from: machineName), shared: isShared(summary)
        )
    }

    /// Whether this is the server's shared bootstrap credential rather than a minted one.
    ///
    /// The server's own answer wins where there is one. The name match is the fallback for a
    /// deployment that predates that field, and it is a fallback rather than the rule because a
    /// real client could be minted under that name — at which point the honest answer is the
    /// server's, not a string comparison here.
    public static func isShared(_ summary: ClientSummary) -> Bool {
        if let shared = summary.shared { return shared }
        return summary.name == sharedClientName
    }

    /// A hostname, reduced to something the server's `Client.validated(name:)` will accept.
    ///
    /// Only the first label survives: `argos.olympus.lan` is `argos`, because the domain is a
    /// fact about the network and the name is meant to answer "which machine is this?" in a
    /// listing. Two machines with the same short name in different domains would collide — and
    /// would collide visibly, at a prompt, with the person who can type a better name standing
    /// in front of it.
    ///
    /// Everything outside the server's alphabet becomes a hyphen rather than being dropped, so
    /// `aditya's-mbp` reads as `aditya-s-mbp` instead of `adityas-mbp`; runs collapse and the
    /// ends are trimmed, since a leading or trailing hyphen is legal there but reads as a typo.
    public static func suggestedName(from raw: String) -> String {
        let label = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""

        var name = ""
        for character in label.lowercased() {
            // ASCII explicitly: `isLetter` and `isNumber` are true for scripts and digits the
            // server's rule does not accept, so trusting them would build a suggestion that
            // earns a `400` on characters that looked fine here.
            let keep = character.isASCII
                && (character.isLowercase || character.isNumber || character == "-")
            let next = keep ? character : "-"
            // Collapse as we go rather than in a second pass over the string.
            if next == "-", name.last == "-" { continue }
            name.append(next)
        }

        name = String(name.prefix(suggestedNameLimit))
        while name.first == "-" { name.removeFirst() }
        // After the truncation as well as before it: a name cut at the limit can end on the
        // hyphen that was legal in the middle of it.
        while name.last == "-" { name.removeLast() }

        return name.isEmpty ? fallbackName : name
    }
}
