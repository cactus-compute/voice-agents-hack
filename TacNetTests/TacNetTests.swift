import XCTest
@testable import TacNet

final class TacNetTests: XCTestCase {
    func testCactusFunctionsAreCallableViaSwiftBindings() {
        XCTAssertTrue(CactusFunctionProbe.verifyCallableSymbols())
    }

    func testFrameworkImportsProbeCompiles() {
        FrameworkImportsProbe.touchFrameworkSymbols()
        XCTAssertTrue(true)
    }
}
