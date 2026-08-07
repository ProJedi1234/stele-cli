import ArgumentParser
import Foundation
import SteleKit

/// What the three page-writing commands share: reading a file off disk, and printing where the
/// page landed.
///
/// `publish` and `update` do both chores; `amend` does only the second, because it sends no
/// bytes at all. What all three have in common is exactly one line of output a caller might
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
    private static func lifetime(_ location: PageLocation) -> String {
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
