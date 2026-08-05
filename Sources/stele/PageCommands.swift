import ArgumentParser
import Foundation
import SteleKit

/// What `publish` and `update` share: reading a file off disk and printing where it landed.
///
/// Both commands are one API call around the same two chores, and both have exactly one line of
/// output that a caller might capture, so the rules about *what goes on stdout* are worth
/// stating once. The URL, alone, unstyled, is the whole of stdout on success — that is what
/// makes `url=$(stele publish page.html)` work and what an agent will do with it.
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

    func execute() async throws {
        let page = try PageIO.read(file)
        let credential = try options.credential()
        let location = try await SteleClient(credential: credential).publish(
            page: page,
            contentType: contentType ?? ContentType.inferred(fromPath: file),
            slug: slug,
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
