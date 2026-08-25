/// The client's own version, and the identity it presents to a stele server.
///
/// It lives in the library rather than in the executable's `CommandConfiguration` because two
/// things need it and they must agree: `stele --version`, and the `User-Agent` on every write.
/// The server compares that header against its own `minimumCLIVersion` and answers `426 Upgrade
/// Required` to an older build, so a version the binary reports but does not send — or sends but
/// does not report — turns a loud version mismatch back into a confusing one.
public enum SteleVersion {
    /// Bumped by hand. Nothing derives it from git: a release built from a tarball or an
    /// unclean tree must still report a version the server can compare.
    public static let current = "0.4.0"

    /// Sent on every request. The `stele-cli/` product token is what the server matches on.
    public static var userAgent: String { "stele-cli/\(current)" }
}
