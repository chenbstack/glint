import XCTest
@testable import Glint

final class DevinHookInstallerTests: XCTestCase {

    /// Verify the installer reports not-installed when no config exists.
    func testIsInstalledReturnsFalseByDefault() {
        XCTAssertFalse(DevinHookInstaller.isInstalled())
    }

    /// Verify presence detection checks for the ~/.config/devin directory
    /// or the `devin` command. We can't mock the filesystem here, so just
    /// ensure the function returns a Bool without crashing.
    func testIsAgentPresentReturnsBool() {
        let _ = DevinHookInstaller.isAgentPresent()
    }
}
