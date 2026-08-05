import Testing

@testable import SteleKit

@Suite("version")
struct VersionTests {
    /// The server matches on the `stele-cli/` product token and parses the version after it, so
    /// the header's shape is a contract with another repository rather than cosmetic.
    @Test("the user agent carries the current version behind the stele-cli product token")
    func userAgentIsTheProductTokenAndVersion() {
        #expect(SteleVersion.userAgent == "stele-cli/\(SteleVersion.current)")
    }
}
