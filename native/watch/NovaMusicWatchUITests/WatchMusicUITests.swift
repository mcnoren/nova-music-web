import XCTest
final class WatchMusicUITests: XCTestCase {
    func testIndependentMusicMenuAndLibraryNavigation() {
        let app = XCUIApplication(); app.launchArguments = ["-nova-watch-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["watch.library"].waitForExistence(timeout: 15))
        app.buttons["watch.library"].tap()
        XCTAssertTrue(app.staticTexts["Playlists"].waitForExistence(timeout: 5))
        app.staticTexts["Playlists"].tap()
        XCTAssertTrue(app.buttons["New Playlist"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Watch Playlists"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testPlayerFitsWatchScreenAndOpensOptions() {
        let app = XCUIApplication(); app.launchArguments = ["-nova-watch-ui-testing", "-nova-watch-preview-player"]; app.launch()
        XCTAssertTrue(app.buttons["watch.playPause"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.playPause"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Watch Now Playing"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.buttons["Playback Device"].waitForExistence(timeout: 5))
    }
    func testLargeTextKeepsPlaybackOptionsReachable() {
        let app = XCUIApplication(); app.launchArguments = ["-nova-watch-ui-testing", "-nova-watch-preview-player", "-nova-watch-large-type"]; app.launch()
        let options = app.buttons["Playback options"]
        for _ in 0..<4 where !options.isHittable { app.swipeUp() }
        XCTAssertTrue(options.waitForExistence(timeout: 5)); XCTAssertTrue(options.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Watch Large Text"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testSettingsDoesNotRequirePhoneOrAccount() {
        let app = XCUIApplication(); app.launchArguments = ["-nova-watch-ui-testing"]; app.launch()
        for _ in 0..<4 where !app.buttons["watch.settings"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["watch.settings"].exists); app.buttons["watch.settings"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Settings Screen"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(app.buttons["iCloud Sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Cellular Downloads"].exists)
    }
}

extension WatchMusicUITests {
    func testArtworkCanBePresentedWithoutObstructingControls() {
        let app = XCUIApplication(); app.launchArguments = ["-nova-watch-ui-testing", "-nova-watch-preview-player"]; app.launch()
        let artwork = app.buttons["watch.fullArtwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["watch.playPause"].isHittable)
        artwork.tap()
        XCTAssertFalse(app.buttons["watch.playPause"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Full Album Artwork"; screenshot.lifetime = .keepAlways; add(screenshot)
        artwork.tap()
        XCTAssertTrue(app.buttons["watch.playPause"].isHittable)
    }
}
