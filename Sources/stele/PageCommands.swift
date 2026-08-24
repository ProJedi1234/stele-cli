import ArgumentParser
import Foundation
import SteleKit

/// What the three page-writing commands share: reading a file off disk, and printing where the
/// page landed.
///
/// `publish` and `update` do both chores; `amend` does only the second, because it sends no
/// bytes at all. `delete` does neither and is not routed through here at all — it ends with no
/// page to point at. What all three have in common is exactly one line of output a caller might
/// capture, so the rules about *what goes on stdout* are worth stating once. The URL, alone,
/// unstyled, is the whole of stdout on success — that is what makes
/// `url=$(stele publish page.html)` work and what an agent will do with it.
///
/// `report` printing the *response's* URL rather than one assembled from the arguments is what
/// makes it usable by `amend` at all: after a rename the address has changed, and the response
/// is the only thing that knows what it changed to.
enum PageIO {
    /// Reads the page, with an error that names the file rather than surfacing a Foundation
    /// description that begins "The file couldn't be opened".
    static func read(_ path: String) throws -> Data {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            throw Failure("no such file: \(path)")
        }
        guard !isDirectory.boolValue else {
            throw Failure("\(path) is a directory — pass the HTML file itself.")
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
            // The server answers an empty body with a 400; catching it here saves a round trip
            // and says which file was empty, which the server cannot know.
            guard !data.isEmpty else { throw Failure("\(path) is empty — there is nothing to publish.") }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure("could not read \(path): \(error.localizedDescription)")
        }
    }

    static func report(_ location: PageLocation, options: GlobalOptions) throws {
        if options.json {
            Terminal.out(try Format.json(location))
            return
        }
        // Deliberately bare. A prefix, a checkmark or a colour here would all have to be
        // stripped by whatever consumes it, and the URL is the answer.
        Terminal.out(location.url)
        // The deadline goes to stderr, because stdout is the URL and nothing else. Printed at
        // all because the server's default is *ephemeral* — a page published with no --ttl is
        // eventually unpublished, and a caller handed only a URL would find that out when the
        // link broke. The date comes from the response rather than from a default repeated
        // here, so this line stays true on the day the server changes its mind.
        Terminal.error(options.style.dim(lifetime(location)))
    }

    /// How a page's deadline reads under the URL.
    ///
    /// Absolute, never "in 7 days", for the reason `Format.moment` already gives: the follow-up
    /// question to a relative date is always "so what date is that".
    ///
    /// Not private, because `attach` prints its own stdout line and this one underneath it. One
    /// spelling of a deadline across every command that has one to report.
    static func lifetime(_ location: PageLocation) -> String {
        guard let expiry = location.expiresAt else { return "kept until deleted" }
        return "expires \(Format.moment(expiry))"
    }
}

struct PublishCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Publish a file as a new page. Prints the URL.",
        discussion: """
            Prints nothing but the URL on stdout, so `url=$(stele publish page.html)` works.

            The content type is taken from the file's extension and can be overridden with \
            --content-type. That decision belonging to the CLI is the point: the `curl` recipe \
            this replaces needed an explicit header, and sending the wrong one earned a 415.

            Pages are ephemeral unless you say otherwise. With no --ttl the server applies its \
            own default lifetime and the page eventually stops being served; --ttl never keeps \
            it. Whichever it is, the deadline is printed on stderr under the URL.

            Exits 5 if --slug is already taken — choose another, or omit it and let the server \
            allocate a three-word one.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(
        help: ArgumentHelp("The file to publish.", valueName: "file"),
        completion: .file()
    )
    var file: String

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Publish at this slug instead of a generated one.",
            discussion: "Lowercase letters, digits and hyphens. The server has the last word.",
            valueName: "name"
        )
    )
    var slug: String?

    @Option(
        name: .long,
        help: ArgumentHelp("Override the type inferred from the file extension.", valueName: "type"),
        completion: .list(ContentType.known)
    )
    var contentType: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "How long the page lives: a number of days, or 'never'.",
            discussion: """
                30 and 30d both mean thirty days; 2w means fourteen. Omit it to take the \
                server's default, which is a matter of days — pass 'never' for a link you \
                expect to keep. The server has the last word on the maximum.
                """,
            valueName: "days"
        ),
        completion: .list([PageTTL.neverKeyword, "7", "30", "90"])
    )
    var ttl: String?

    func execute() async throws {
        let page = try PageIO.read(file)
        // Parsed before the file is sent rather than after: a lifetime this side can already
        // tell is unusable should not cost an upload, and the message it earns here names the
        // spelling to use instead.
        let lifetime = try ttl.map { raw -> PageTTL in
            do { return try PageTTL.parse(raw) } catch { throw Failure("\(error)") }
        }
        let credential = try options.credential()
        let location = try await SteleClient(credential: credential).publish(
            page: page,
            contentType: contentType ?? ContentType.inferred(fromPath: file),
            slug: slug,
            ttl: lifetime,
            using: credential
        )
        try PageIO.report(location, options: options)
    }
}

/// Publishes bytes — an image, a video, a PDF — rather than a page.
///
/// The same route as `publish`, because on the server an attachment *is* a page whose body is
/// bytes. What makes this a separate command is not the request but the answer: an attachment
/// has two URLs, and which one a caller gets handed decides whether the page they write works.
struct AttachCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Publish an image, video or file. Prints the URL of the bytes.",
        discussion: """
            For the things a page links to rather than the page itself. Publish the file first, \
            then put the URL you get back into the page you write:

              src=$(stele attach screenshot.png)

            Prints nothing but that URL on stdout, so the capture above works. It is \
            deliberately the URL of the *bytes* — the one that belongs in an <img src> or a \
            <video src>. The attachment has a second URL, a page about the file with its name, \
            size and deadline, and that is the one to send a person; it goes to stderr under \
            the deadline, and --json names both. Getting them the wrong way round fails \
            silently — an <img> pointed at the viewer renders nothing, and both answer 200.

            The type comes from the file's extension, and an extension this tool does not \
            recognise is refused here rather than uploaded: use --content-type when the \
            extension is missing or lying. The server keeps the real list and has the last word.

            Attachments expire like pages, and this is the thing to get right because nothing \
            will warn you: a page and the images inside it are separate publications with \
            separate deadlines. A permanent page whose screenshots took the default becomes a \
            page of broken images a week later, with no request failing at the time. Ask for \
            the same --ttl on both.

            `stele update`, `stele amend` and `stele delete` reach an attachment at its slug \
            exactly as they reach a page.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(
        help: ArgumentHelp("The file to publish.", valueName: "file"),
        completion: .file()
    )
    var file: String

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Publish at this slug instead of a generated one.",
            discussion: "Lowercase letters, digits and hyphens. The server has the last word.",
            valueName: "name"
        )
    )
    var slug: String?

    @Option(
        name: .long,
        help: ArgumentHelp("Override the type inferred from the file extension.", valueName: "type"),
        completion: .list(ContentType.knownAttachments)
    )
    var contentType: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "How long the file lives: a number of days, or 'never'.",
            discussion: """
                Means exactly what it means on `stele publish`, including the default — a file \
                you say nothing about expires on the server's own schedule. Match it to the \
                lifetime of the page that embeds it.
                """,
            valueName: "days"
        ),
        completion: .list([PageTTL.neverKeyword, "7", "30", "90"])
    )
    var ttl: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "The name a browser saves the file under.",
            discussion: """
                Defaults to the name of the file you uploaded. Worth setting when that name is \
                a temporary one: a slug is a name for a URL, and a download called \
                quiet-cedar-otter opens in nothing.
                """,
            valueName: "name"
        )
    )
    var filename: String?

    func execute() async throws {
        let bytes = try PageIO.read(file)
        // Refused before the credential is read and long before the bytes travel. The server
        // would answer this with a 415 of its own, but it would be answering about a type this
        // side chose by defaulting — and `text/html` on a JPEG is not a disagreement with the
        // server, it is a guess nobody made. Naming the flag is the whole value of catching it
        // here; the same bargain `amend` strikes over having nothing to amend.
        let type = try contentType ?? ContentType.attachmentInferred(fromPath: file)
            .orThrow(Failure("""
                cannot tell what kind of file \(file) is from its extension. Pass \
                --content-type <type>, or use a file this tool recognises: \
                \(ContentType.knownAttachmentExtensions.joined(separator: ", ")).
                """))
        let lifetime = try ttl.map { raw -> PageTTL in
            do { return try PageTTL.parse(raw) } catch { throw Failure("\(error)") }
        }
        let credential = try options.credential()
        let location = try await SteleClient(credential: credential).publish(
            page: bytes,
            contentType: type,
            slug: slug,
            ttl: lifetime,
            filename: filename ?? Self.derivedFilename(from: file),
            using: credential
        )
        try report(location)
    }

    /// The name to save the upload under when the caller did not choose one.
    ///
    /// The file's own basename, which is what the skill promises and is nearly always the name
    /// the person meant. Nil when that name is one the server would refuse: those rules exist
    /// because the value ends up in a `Content-Disposition`, and a filename with a quote in it
    /// can close the header's quoted string early.
    ///
    /// Omitting beats failing here, and only here. This name was *derived* — the caller never
    /// typed it — so refusing the upload over it would be a 400 about a parameter they did not
    /// pass, when the server's own fallback (the slug) is a working download. An explicit
    /// `--filename` skips this entirely and travels untouched, whatever it says, because there
    /// the caller has an opinion and the server is the one that gets to answer it. The check is
    /// a hint, not a copy of the rule — the same arrangement `ContentType` runs on.
    static func derivedFilename(from path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name.count <= 255 else { return nil }
        let refused: Set<Character> = ["\"", "\\", "/", "\r", "\n", "\0"]
        guard !name.contains(where: { refused.contains($0) || $0.isASCIIControl }) else {
            return nil
        }
        return name
    }

    /// The report `PageIO.report` cannot make, because the URL an attachment answers with is
    /// not the URL an attachment is used by.
    private func report(_ location: PageLocation) throws {
        // A viewer URL this client cannot turn into a bytes URL is a server answering
        // strangely. Reported rather than papered over with the viewer: printing that on stdout
        // would put the wrong URL into a page, which is the one outcome this command exists to
        // prevent, and it would do it silently.
        guard let bytes = SteleClient.bytesURL(for: location) else {
            throw SteleError.malformedResponse(
                "the server's URL for the attachment was not one this client could read"
            )
        }
        if options.json {
            Terminal.out(try Format.json(AttachmentReport(location: location, bytes: bytes)))
            return
        }
        // Bare, and the bytes rather than the viewer: this is the value that gets captured and
        // pasted into an `<img src>`.
        Terminal.out(bytes)
        Terminal.error(options.style.dim(PageIO.lifetime(location)))
        Terminal.error(options.style.dim("page about it: \(location.url)"))
    }
}

/// `stele attach --json`.
///
/// Hand-written rather than an encoding of `PageLocation`, and neither URL is called `url` —
/// which is the decision worth keeping. `PageLocation.url` means "the viewer" everywhere else
/// in this tool, and stdout here is the bytes, so whichever meaning `url` took would be wrong
/// half the time and wrong *silently*: a caller reaching for `.url` would get a working URL of
/// the wrong kind. Absent, they get nothing, and nothing is a failure they can see.
private struct AttachmentReport: Encodable {
    let slug: String
    /// The file itself. What goes in an `<img src>`.
    let bytes: String
    /// The page about the file. What you send a person.
    let viewer: String
    /// Explicitly null for an attachment kept until it is deleted, never absent — a missing key
    /// and a null one read the same to a careless caller, and `PageLocation` hand-writes its
    /// encoder for this reason.
    let expires: Date?

    init(location: PageLocation, bytes: String) {
        self.slug = location.slug
        self.bytes = bytes
        self.viewer = location.url
        self.expires = location.expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case slug, bytes, viewer, expires
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(viewer, forKey: .viewer)
        try container.encode(expires, forKey: .expires)
    }
}

extension Character {
    /// The C0 controls, which cannot appear in a header value.
    var isASCIIControl: Bool { isASCII && (asciiValue ?? 0x20) < 0x20 }
}

extension Optional {
    /// `??` for a value that has an error rather than a fallback behind it.
    func orThrow(_ error: @autoclosure () -> some Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}

struct UpdateCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Replace an existing page's content. Prints the URL.",
        discussion: """
            Never creates a page: an update to a slug that does not exist exits 7 rather than \
            quietly publishing at a URL nobody has seen. Publish it with `stele publish --slug \
            <name>` first if that is what you meant.

            There is no --ttl here, deliberately: replacing a body cannot buy the link more \
            time, and a lifetime quietly reset by every edit would be a deadline nobody could \
            predict. The deadline the page already has is printed under the URL, unchanged. \
            `stele amend --ttl` is how you move it, without touching the contents.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: ArgumentHelp("The slug to replace, as it appears in the URL.", valueName: "slug"))
    var slug: String

    @Argument(
        help: ArgumentHelp("The file to publish in its place.", valueName: "file"),
        completion: .file()
    )
    var file: String

    @Option(
        name: .long,
        help: ArgumentHelp("Override the type inferred from the file extension.", valueName: "type"),
        completion: .list(ContentType.known)
    )
    var contentType: String?

    func execute() async throws {
        let page = try PageIO.read(file)
        let credential = try options.credential()
        let location = try await SteleClient(credential: credential).update(
            slug: slug,
            page: page,
            contentType: contentType ?? ContentType.inferred(fromPath: file),
            using: credential
        )
        try PageIO.report(location, options: options)
    }
}

struct AmendCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "amend",
        abstract: "Rename a page or change its deadline. Prints the URL.",
        discussion: """
            Amends a page's name, its deadline, or both, and nothing else. The contents, the \
            content type and the record of who published them survive untouched — an amendment \
            writes no bytes, so it does not claim to have written them.

            Omitting --ttl leaves the existing deadline exactly where it is; it does not \
            reapply the default lifetime a new page would get. Passing one counts from now \
            rather than from publication, so --ttl 30 grants thirty fresh days rather than \
            whatever is left of the original thirty.

            A rename is a hard move. The old name is freed the moment it commits — it serves an \
            ordinary 404 and returns to the pool for anybody's next page to claim, with no \
            redirect and no tombstone left behind. Every link already in circulation breaks. If \
            the URL is already out in the world and what you want is for it to say something \
            else, that is `stele update`.

            Never creates and never revives: amending a slug with no live page behind it exits \
            7, and a page that has already expired counts as none, so --ttl never cannot bring \
            one back. Exits 5 if the name you asked for is held by another page.

            The URL on stdout is the page's URL after the amendment, which may not be the one \
            you passed in. Read it from here rather than assembling it yourself.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: ArgumentHelp("The page to amend, as its slug appears in the URL.", valueName: "slug"))
    var slug: String

    /// The new name, spelled `--slug` on the command line to match `publish --slug`, but held in
    /// a differently named property because the positional above has already taken `slug`. The
    /// flag is the part users and agents type, so it is the part that stays consistent.
    @Option(
        name: .customLong("slug"),
        help: ArgumentHelp(
            "Rename the page to this slug.",
            discussion: """
                Lowercase letters, digits and hyphens; the server has the last word. Renaming a \
                page to the name it already has succeeds and changes nothing.
                """,
            valueName: "name"
        )
    )
    var newSlug: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Give the page a new lifetime: a number of days, or 'never'.",
            discussion: """
                30 and 30d both mean thirty days; 2w means fourteen. Counted from now rather \
                than from when the page was published, so 30 grants thirty fresh days. Omit it \
                and the deadline the page already has is left alone — unlike `publish`, this is \
                not a way to fall back to the default lifetime. The server has the last word on \
                the maximum.
                """,
            valueName: "days"
        ),
        completion: .list([PageTTL.neverKeyword, "7", "30", "90"])
    )
    var ttl: String?

    func execute() async throws {
        // Refused here, before a credential is read or a byte is sent. The server answers this
        // with a 400 of its own, but an amendment naming nothing to amend is a mistake in the
        // invocation rather than a disagreement with the server, and this side can name the two
        // flags that would fix it — the same bargain `PageIO.read` strikes over an empty file.
        guard newSlug != nil || ttl != nil else {
            throw Failure("""
                nothing to amend — pass --slug <name> to rename the page, --ttl <days> to change \
                its deadline, or both.
                """)
        }
        // Parsed before the request rather than after, for `publish`'s reason: a lifetime this
        // side can already tell is unusable should not cost a round trip. Note that it stays nil
        // when --ttl was not given, and must — a defaulted value here would put a deadline on a
        // page the caller only asked to rename.
        let lifetime = try ttl.map { raw -> PageTTL in
            do { return try PageTTL.parse(raw) } catch { throw Failure("\(error)") }
        }
        let credential = try options.credential()
        let location = try await SteleClient(credential: credential).amend(
            slug: slug,
            newSlug: newSlug,
            ttl: lifetime,
            using: credential
        )
        // The usual report, and it matters more here than anywhere else: after a rename the
        // response is the only thing that knows where the page now lives.
        try PageIO.report(location, options: options)
    }
}

struct DeleteCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a published page. Prints nothing.",
        discussion: """
            Permanent and immediate. No tombstone, no redirect: the slug is freed the moment it \
            commits and returns to the pool for anybody's next page to claim. Every link already \
            in circulation breaks as an ordinary 404 — and may one day answer with somebody \
            else's page, which is the part worth saying out loud before you type this. \
            Republishing the same file afterwards is a new page, not the old one back.

            Never a silent success: deleting a slug with no live page behind it exits 7, and a \
            page that has already expired counts as none. The server refuses to claim work it \
            never did, so a typo'd slug is an error you can branch on rather than a 0 that means \
            nothing happened.

            Stdout stays empty on success, deliberately. The other page commands print a URL \
            because there is a page to point at; here there is not. The confirmation goes to \
            stderr, and --json prints the slug on stdout for a caller that needs to tie the \
            outcome back to the request.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: ArgumentHelp("The page to delete, as its slug appears in the URL.", valueName: "slug"))
    var slug: String

    func execute() async throws {
        let credential = try options.credential()
        // The route needs only `publish`, so this is the agent's own credential and not an
        // operator's — deleting a page is part of publishing one, not an administrative act.
        try await SteleClient(credential: credential).delete(slug: slug, using: credential)
        if options.json {
            // The slug echoed back rather than an empty object: the page is gone, so there is
            // nothing left for a caller batching deletes to match this result against except
            // the name it asked for.
            Terminal.out(try Format.json(["slug": slug]))
            return
        }
        // Nothing goes to stdout here, and the emptiness is the contract. Every other page
        // command's stdout is a URL, which is why `url=$(stele publish page.html)` works —
        // a confirmation line printed on this one would be captured by the same idiom and
        // handed onward as if it were an address. So the only thing said on success is said on
        // stderr, where `PageIO` already puts the deadline: legible to a human watching, absent
        // from anything reading.
        Terminal.error(options.style.dim("deleted \(slug)"))
    }
}

struct SkillCommand: SteleCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Print the server's own publishing instructions, as Markdown.",
        discussion: """
            Proxied straight from GET /skill rather than baked in, so the document you read is \
            the one the running server generates — this binary keeps zero copies of the \
            contract and cannot drift from it.

            The read itself needs no credential. The stored one is consulted only to work out \
            which deployment you meant; pass --host to ask a server you have never logged in to.
            """
    )

    @OptionGroup var options: GlobalOptions

    func execute() async throws {
        let markdown = try await SteleClient(host: try options.readHost()).fetchSkill()
        if options.json {
            Terminal.out(try Format.json(["skill": markdown]))
            return
        }
        // Straight to stdout, unstyled and unwrapped: this is a document to be piped into a
        // file or a pager, and anything added to it would end up in whatever it was piped into.
        Terminal.out(markdown)
    }
}
