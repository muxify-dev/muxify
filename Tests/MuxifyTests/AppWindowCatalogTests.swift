import XCTest
@testable import MuxifyCore

final class AppWindowCatalogTests: XCTestCase {
    func testRegistrationIsIdempotentAndUnknownFocusIsIgnored() {
        var catalog = AppWindowCatalog()
        let local = catalog.newLocalWindow()
        catalog.register(local)
        catalog.focus(local.id)
        catalog.focus(UUID())
        XCTAssertEqual(catalog.requests, [local])
        XCTAssertEqual(catalog.focusedID, local.id)
    }

    func testSceneRequestRoundTripsAndHashesOnlyItsStableIdentity() throws {
        let request = AppWindowRequest(environmentName: "Home")
        let restored = try JSONDecoder().decode(AppWindowRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.id, request.id)
        XCTAssertEqual(restored.environmentName, request.environmentName)
        XCTAssertEqual(Set([request, AppWindowRequest(id: request.id)]).count, 1)
    }
}
