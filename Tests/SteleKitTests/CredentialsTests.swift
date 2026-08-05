import Foundation
import Testing

@testable import SteleKit

/// A real directory, because the rules under test are about `st_mode` and atomic renames —
/// things a mocked filesystem would model rather than exercise.
private struct FakeHome: ~Copyable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "stele-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: nil
        )
    }

    var store: CredentialStore { CredentialStore(home: path) }

    func mode(of path: String) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? NSNumber).uint16Value & 0o7777
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func credential(
    _ host: String, client: String = "claude-code", token: String = "stele_pat_abc"
) throws -> Credential {
    Credential(
        host: try SteleHost(host), clientName: client, token: try Token(token)
    )
}

@Suite("credential file")
struct CredentialFileTests {
    /// The mode is the feature, not an implementation detail: a credential another user on the
    /// machine can read is not a credential.
    @Test("the file is written 0600 inside a 0700 directory")
    func writesTightPermissions() throws {
        let home = try FakeHome()
        var credentials = Credentials()
        credentials.set(try credential("https://stele.example.com"))
        try home.store.save(credentials)

        #expect(try home.mode(of: home.store.path) == 0o600)
        #expect(try home.mode(of: home.store.directory) == 0o700)
    }

    /// The `.new` temp file must not survive the rename, or a second copy of the token sits on
    /// disk under a name nothing checks the permissions of.
    @Test("saving leaves no temporary file behind")
    func leavesNoTemporaryFile() throws {
        let home = try FakeHome()
        var credentials = Credentials()
        credentials.set(try credential("https://stele.example.com"))
        try home.store.save(credentials)

        #expect(!FileManager.default.fileExists(atPath: home.store.path + ".new"))
    }

    @Test("a saved file loads back as the same credentials")
    func roundTrips() throws {
        let home = try FakeHome()
        var credentials = Credentials()
        credentials.set(try credential("https://one.example.com", client: "one"))
        credentials.set(try credential("https://two.example.com", client: "two"))
        try home.store.save(credentials)

        let loaded = try home.store.load()
        #expect(loaded.hosts == [try SteleHost("https://one.example.com"),
                                 try SteleHost("https://two.example.com")])
        #expect(loaded.clientName(for: try SteleHost("https://two.example.com")) == "two")
        let two = try SteleHost("https://two.example.com")
        #expect(loaded.defaultHost == two)
    }

    /// ssh's rule, and ssh's reasoning: refuse, do not warn and continue.
    @Test("a group- or world-readable file is refused, naming the fix")
    func refusesLoosePermissions() throws {
        let home = try FakeHome()
        var credentials = Credentials()
        credentials.set(try credential("https://stele.example.com"))
        try home.store.save(credentials)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: home.store.path
        )

        let store = home.store
        #expect(throws: CredentialsError.fileTooOpen(path: store.path, mode: 0o644)) {
            try store.load()
        }
        let message = CredentialsError.fileTooOpen(path: store.path, mode: 0o644).description
        #expect(message.contains("0644"))
        #expect(message.contains("chmod 600"))
    }

    /// Every bit outside the owner's, not only the read bits: a file another user can *write*
    /// lets them choose the token this client then presents.
    @Test("a group-writable file is refused too")
    func refusesGroupWritable() throws {
        let home = try FakeHome()
        var credentials = Credentials()
        credentials.set(try credential("https://stele.example.com"))
        try home.store.save(credentials)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o620], ofItemAtPath: home.store.path
        )

        let store = home.store
        #expect(throws: CredentialsError.self) { try store.load() }
    }

    /// Symlinking the credential file out of a dotfiles repository is an ordinary thing to do,
    /// and `attributesOfItem` does not follow symlinks — it reports the *link's* mode, which is
    /// `0777` by construction. So the check refused the file every time, and the remedy it
    /// printed could not fix it: `chmod` follows the link and changes the target, which was
    /// already `0600`, leaving the link at `0777` and the advice in a loop.
    @Test("a symlinked credential file is judged by the real file's mode")
    func followsSymlinkForThePermissionCheck() throws {
        let home = try FakeHome()
        let store = home.store
        var credentials = Credentials()
        credentials.set(try credential("https://stele.example.com"))
        try store.save(credentials)

        // The real file moves aside, the credential path becomes a link to it — the shape a
        // dotfiles manager leaves behind.
        let real = (home.path as NSString).appendingPathComponent("credentials.json")
        try FileManager.default.moveItem(atPath: store.path, toPath: real)
        try FileManager.default.createSymbolicLink(
            atPath: store.path, withDestinationPath: real
        )
        #expect(try home.mode(of: store.path) == 0o777)

        #expect(try store.load().hosts == [try SteleHost("https://stele.example.com")])
    }

    /// And the rule still bites through a link: what is checked is the real file, not the fact
    /// that a link was involved.
    @Test("a symlink to a loose file is still refused, naming the file to chmod")
    func refusesLooseTargetThroughSymlink() throws {
        let home = try FakeHome()
        let store = home.store
        var credentials = Credentials()
        credentials.set(try credential("https://stele.example.com"))
        try store.save(credentials)

        let real = (home.path as NSString).appendingPathComponent("credentials.json")
        try FileManager.default.moveItem(atPath: store.path, toPath: real)
        try FileManager.default.createSymbolicLink(atPath: store.path, withDestinationPath: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: real)

        let thrown = #expect(throws: CredentialsError.self) { try store.load() }
        guard case .fileTooOpen(let path, let mode) = try #require(thrown) else {
            Issue.record("expected fileTooOpen, got \(String(describing: thrown))")
            return
        }
        #expect(mode == 0o644)
        // The path a `chmod` has to be pointed at is the target, not the link.
        #expect(path == (real as NSString).resolvingSymlinksInPath)
    }

    /// A fresh machine is not an error state; `resolve` produces the message worth reading.
    @Test("an absent file loads as empty credentials")
    func absentFileIsEmpty() throws {
        let home = try FakeHome()
        #expect(try home.store.load().isEmpty)
    }

    /// The literal shape from the plan, including the `default` marker sitting alongside the
    /// host keys rather than under a wrapper.
    @Test("the on-disk shape is host keys plus an optional default marker")
    func fileShape() throws {
        let home = try FakeHome()
        var credentials = Credentials()
        credentials.set(try credential("https://one.example.com", client: "one"), makeDefault: false)
        credentials.set(try credential("https://two.example.com", client: "two"))
        try home.store.save(credentials)

        let data = try Data(contentsOf: URL(fileURLWithPath: home.store.path))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["default"] as? String == "https://two.example.com")
        let entry = try #require(object["https://one.example.com"] as? [String: String])
        #expect(entry["client"] == "one")
        #expect(entry["token"] == "stele_pat_abc")
    }
}

@Suite("host resolution")
struct HostResolutionTests {
    @Test("one stored host needs no marker and no flag")
    func singleHostIsImplicit() throws {
        var credentials = Credentials()
        credentials.set(try credential("https://only.example.com", client: "solo"))
        #expect(try credentials.resolve().clientName == "solo")
    }

    @Test("the default marker breaks the tie when several are stored")
    func defaultBreaksTheTie() throws {
        var credentials = Credentials()
        credentials.set(try credential("https://one.example.com", client: "one"), makeDefault: false)
        credentials.set(try credential("https://two.example.com", client: "two"))
        #expect(try credentials.resolve().clientName == "two")
    }

    /// Guessing here would make the destination of `stele publish` depend on something the
    /// user cannot see. Only reachable from a hand-edited file — `set` always leaves a default
    /// behind — which is exactly why it has to be handled rather than assumed away.
    @Test("several hosts with no default is an error, not a guess")
    func ambiguityIsAnError() throws {
        let json = """
            {
              "https://one.example.com": {"client": "one", "token": "stele_pat_a"},
              "https://two.example.com": {"client": "two", "token": "stele_pat_b"}
            }
            """
        let credentials = try CredentialStore.decode(Data(json.utf8), path: "test")
        #expect(throws: CredentialsError.self) { try credentials.resolve() }
    }

    /// A marker naming a host that is not in the file is dropped rather than obeyed or
    /// rejected: the credentials in it are still good, and the resulting message tells the
    /// user what to do.
    @Test("a default pointing at an absent host degrades to ambiguity")
    func staleDefaultIsDropped() throws {
        let json = """
            {
              "default": "https://gone.example.com",
              "https://one.example.com": {"client": "one", "token": "stele_pat_a"},
              "https://two.example.com": {"client": "two", "token": "stele_pat_b"}
            }
            """
        let credentials = try CredentialStore.decode(Data(json.utf8), path: "test")
        #expect(credentials.defaultHost == nil)
        #expect(throws: CredentialsError.self) { try credentials.resolve() }
    }

    /// The regression this suite exists for on the write side. A one-host file carries no
    /// `default` marker — nothing needs one — so the host that has been answering every bare
    /// command reloads with `defaultHost == nil`. Reading that nil as "no default yet" is how
    /// `--no-default` used to hand the default to the very host that declined it, quietly
    /// repointing the next `stele publish` at the deployment just added.
    @Test("--no-default leaves the incumbent default alone, marker on disk or not")
    func decliningKeepsTheIncumbent() throws {
        let home = try FakeHome()
        var first = Credentials()
        first.set(try credential("https://one.example.com", client: "one"))
        try home.store.save(first)

        var reloaded = try home.store.load()
        #expect(reloaded.defaultHost == nil)  // one host: the file says nothing, and need not
        reloaded.set(try credential("https://two.example.com", client: "two"), makeDefault: false)

        let one = try SteleHost("https://one.example.com")
        #expect(reloaded.defaultHost == one)
        #expect(try reloaded.resolve().host == one)
        try home.store.save(reloaded)
        #expect(try home.store.load().resolve().clientName == "one")
    }

    /// Declining when there is genuinely nothing to decline in favour of. A hand-edited file
    /// with several hosts and no marker has no incumbent — `resolve` refuses to guess between
    /// them — and adding a third with `--no-default` must not resolve that by promoting the new
    /// one. The ambiguity is the user's to settle, and the error names the command that does it.
    @Test("--no-default into an ambiguous file leaves it ambiguous")
    func decliningWithNoIncumbent() throws {
        let json = """
            {
              "https://one.example.com": {"client": "one", "token": "stele_pat_a"},
              "https://two.example.com": {"client": "two", "token": "stele_pat_b"}
            }
            """
        var credentials = try CredentialStore.decode(Data(json.utf8), path: "test")
        credentials.set(try credential("https://three.example.com", client: "three"), makeDefault: false)

        #expect(credentials.defaultHost == nil)
        #expect(throws: CredentialsError.self) { try credentials.resolve() }
    }

    /// The first login is the exception that keeps the rest simple: with nothing stored, the
    /// host being added is the only one there is, so it takes the default even when asked not
    /// to. Anything else would make `auth login --no-default` on a fresh machine store a
    /// credential that no bare command can reach.
    @Test("--no-default on a fresh file still leaves a default behind")
    func decliningOnAFreshFile() throws {
        var credentials = Credentials()
        credentials.set(try credential("https://only.example.com", client: "solo"), makeDefault: false)

        #expect(credentials.defaultHost == (try SteleHost("https://only.example.com")))
        #expect(try credentials.resolve().clientName == "solo")
    }

    @Test("an explicit host wins over the default")
    func overrideWins() throws {
        var credentials = Credentials()
        credentials.set(try credential("https://one.example.com", client: "one"), makeDefault: false)
        credentials.set(try credential("https://two.example.com", client: "two"))
        let resolved = try credentials.resolve(host: try SteleHost("https://one.example.com"))
        #expect(resolved.clientName == "one")
    }

    /// Falling back to another host would publish to a deployment nobody asked for.
    @Test("an explicit host with no credential does not fall back")
    func overrideWithoutCredentialFails() throws {
        var credentials = Credentials()
        credentials.set(try credential("https://one.example.com"))
        #expect(throws: CredentialsError.noCredentialForHost(try SteleHost("https://other.example.com"))) {
            try credentials.resolve(host: try SteleHost("https://other.example.com"))
        }
    }

    @Test("no credentials at all points at auth login")
    func emptyPointsAtLogin() throws {
        #expect(throws: CredentialsError.notAuthenticated) { try Credentials().resolve() }
        #expect(CredentialsError.notAuthenticated.description.contains("stele auth login"))
    }

    /// Removing the host the default pointed at must not leave a marker aimed at nothing —
    /// that would turn every later command into "no credential for a host you never named".
    @Test("removing the default host repoints the marker")
    func removeRepointsDefault() throws {
        var credentials = Credentials()
        credentials.set(try credential("https://one.example.com"), makeDefault: false)
        credentials.set(try credential("https://two.example.com"))
        #expect(credentials.remove(host: try SteleHost("https://two.example.com")))
        #expect(credentials.defaultHost == (try SteleHost("https://one.example.com")))
        #expect(try credentials.resolve().host == (try SteleHost("https://one.example.com")))
        // Nothing stored for it, so the caller can tell "removed" from "was not there".
        #expect(!credentials.remove(host: try SteleHost("https://two.example.com")))
    }
}

@Suite("host normalisation")
struct SteleHostTests {
    /// Each of these would otherwise file one deployment under two keys, and the second
    /// command would report "no credential" for a host the file plainly contains.
    @Test(
        "equivalent spellings normalise to one key",
        arguments: [
            ("https://Stele.Example.com", "https://stele.example.com"),
            ("https://stele.example.com/", "https://stele.example.com"),
            ("https://stele.example.com/pages", "https://stele.example.com"),
            ("https://stele.example.com:443", "https://stele.example.com"),
            ("http://stele.example.com:80", "http://stele.example.com"),
            ("http://stele.example.com:8080", "http://stele.example.com:8080"),
            ("  https://stele.example.com  ", "https://stele.example.com"),
        ]
    )
    func normalises(_ raw: String, _ expected: String) throws {
        #expect(try SteleHost(raw).value == expected)
    }

    /// Defaulting the scheme would decide, invisibly, which of `http` and `https` the token
    /// gets sent over.
    @Test("a host without a scheme is refused", arguments: ["stele.example.com", "", "ftp://x", "https://"])
    func requiresAScheme(_ raw: String) {
        #expect(throws: CredentialsError.self) { try SteleHost(raw) }
    }

    /// The other side of the normalisation rule. Two spellings of one deployment are one key,
    /// and `[String: Any]` has no order — so a file holding both used to resolve to whichever
    /// the dictionary iteration happened to reach last, which is a credential that can differ
    /// between two runs over identical bytes. The file is documented as something a human
    /// edits, so this is reachable, and "which token gets used" is not a question to answer by
    /// iteration order.
    @Test(
        "two keys naming one deployment are refused rather than resolved arbitrarily",
        arguments: [
            ("https://stele.example.com", "https://stele.example.com:443"),
            ("https://stele.example.com", "https://Stele.Example.com"),
            ("http://stele.example.com", "http://stele.example.com/"),
        ]
    )
    func refusesCollidingKeys(_ first: String, _ second: String) throws {
        let data = Data(
            #"""
            {"\#(first)": {"client": "one", "token": "stele_pat_one"},
             "\#(second)": {"client": "two", "token": "stele_pat_two"}}
            """#.utf8
        )
        let thrown = #expect(throws: CredentialsError.self) {
            try CredentialStore.decode(data, path: "credentials.json")
        }
        guard case .malformed(_, let reason) = try #require(thrown) else {
            Issue.record("expected malformed, got \(String(describing: thrown))")
            return
        }
        // Both spellings, so the person editing the file knows which two lines to look at.
        #expect(reason.contains(first))
        #expect(reason.contains(second))
    }

    /// Two genuinely different deployments still load, which is the case the check must not
    /// catch.
    @Test("two distinct hosts are not a collision")
    func distinctHostsLoad() throws {
        let loaded = try CredentialStore.decode(
            Data(
                #"""
                {"https://one.example.com": {"client": "one", "token": "stele_pat_one"},
                 "https://one.example.com:8443": {"client": "two", "token": "stele_pat_two"}}
                """#.utf8
            ),
            path: "credentials.json"
        )
        #expect(loaded.hosts.count == 2)
    }
}
