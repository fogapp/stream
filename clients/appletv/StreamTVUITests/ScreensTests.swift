import XCTest

/// Every screen of the showcase, reached with the Siri Remote as someone
/// would, with a screenshot of each (make ui → build/screenshots). The
/// assertions are what a screen must have; the pictures are for looking at.
final class ScreensTests: XCTestCase {
    private let remote = XCUIRemote.shared

    override func setUp() {
        continueAfterFailure = false
    }

    @discardableResult
    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StreamShowcase", "YES"] + extra
        app.launch()
        return app
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            usleep(250_000)
        }
    }

    /// Opens the sidebar and moves along it until `label` has focus.
    func sidebar(_ app: XCUIApplication, _ label: String, _ direction: XCUIRemote.Button = .down) {
        press(.menu)
        sleep(1)
        for _ in 0..<12 where !app.buttons[label].hasFocus { press(direction) }
        XCTAssertTrue(app.buttons[label].hasFocus, "The sidebar never reached \(label)")
        press(.select)
        sleep(2)
    }

    func testTheDesignGallery() {
        let app = launch(["-StreamGallery", "YES"])
        sleep(3)
        snap("t0-gallery")
        XCTAssertTrue(app.staticTexts["Display"].waitForExistence(timeout: 10), app.debugDescription)
        press(.down, times: 2)
        snap("t0-gallery-focus")
        press(.down, times: 2)
        sleep(1)
        snap("t0-gallery-artwork")
    }

    func testTheScreensBeforeHome() {
        let server = launch(["-StreamShowcaseStage", "server"])
        XCTAssertTrue(server.staticTexts["Where is your Stream?"].waitForExistence(timeout: 10))
        snap("t1-server")
        server.terminate()

        let pairing = launch(["-StreamShowcaseStage", "pairing"])
        XCTAssertTrue(pairing.staticTexts["Sign in this Apple TV"].waitForExistence(timeout: 10))
        sleep(1)
        snap("t1-pairing")
        pairing.terminate()

        let picker = launch(["-StreamShowcasePicker", "YES"])
        XCTAssertTrue(picker.staticTexts["Who's watching?"].waitForExistence(timeout: 10))
        press(.right)
        snap("t1-picker")
        press(.select)
        XCTAssertTrue(picker.staticTexts["Enter Sam's PIN"].waitForExistence(timeout: 5))
        snap("t1-pin")
    }

    func testTheSidebarGoesEverywhere() {
        let app = launch()
        sleep(3)
        snap("t1-home-sidebar-closed")
        press(.menu)
        sleep(1)
        XCTAssertTrue(app.buttons["Grid"].exists)
        snap("t1-sidebar-open")
        press(.down, times: 4)
        press(.select)
        sleep(2)
        XCTAssertTrue(app.staticTexts["Movies"].exists)
        snap("t1-library")
        press(.menu)
        press(.down, times: 4)
        press(.select)
        sleep(2)
        snap("t1-collections")
    }

    func testHome() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))
        sleep(1)
        snap("t2-home-hero")
        sleep(4)
        snap("t2-home-trailer")
        press(.down)
        sleep(1)
        snap("t2-home-continue-row")
        press(.down, times: 2)
        press(.right, times: 2)
        sleep(1)
        snap("t2-home-posters")
    }

    func testCardsAndTheirActions() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["On now"].waitForExistence(timeout: 10))
        press(.down)
        sleep(1)
        snap("t3-on-now")
        press(.down, times: 3)
        sleep(1)
        snap("t3-videos")
        press(.down)
        remote.press(.select, forDuration: 1.6)
        sleep(1)
        snap("t3-actions-menu")
        XCTAssertTrue(app.descendants(matching: .any)["Mark as watched"].exists)
        press(.down)
        press(.select)
        sleep(1)
        snap("t3-toast")
        press(.down, times: 3)
        sleep(1)
        snap("t3-clips")
    }

    func testTitlePages() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))
        press(.right, times: 2)
        press(.select)
        XCTAssertTrue(app.staticTexts["Some journeys only go one way."].waitForExistence(timeout: 10))
        sleep(2)
        snap("t4-movie")
        // Down from Resume lands on the middle star; one right is four stars.
        press(.down)
        press(.right)
        press(.select)
        sleep(1)
        snap("t4-movie-rating")
        XCTAssertTrue(app.staticTexts["Rated 4 of 5"].waitForExistence(timeout: 5))
        press(.down)
        sleep(1)
        snap("t4-movie-extras")
        press(.down)
        sleep(1)
        snap("t4-movie-cast")
        press(.select)
        sleep(2)
        snap("t4-person")
        press(.menu)
        sleep(2)
        press(.menu)
        sleep(2)
        // Home again: down to the TV Shows row, into Deep Field.
        press(.down, times: 6)
        sleep(1)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["Season 1"].waitForExistence(timeout: 10))
        sleep(2)
        snap("t4-show")
        press(.down, times: 3)
        sleep(1)
        snap("t4-show-episodes")
        press(.up)
        press(.right)
        sleep(2)
        snap("t4-show-season-2")
    }

    func testLibrariesAndSearch() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))

        // Films: focus starts on the first poster; up reaches the sort.
        sidebar(app, "Movies")
        XCTAssertTrue(app.staticTexts["8 films"].waitForExistence(timeout: 5))
        snap("t5-movies")
        XCTAssertFalse(app.buttons["A–Z"].hasFocus)
        press(.up)
        for _ in 0..<4 where !app.buttons["A–Z"].hasFocus { press(.left) }
        press(.right)
        press(.select)
        sleep(1)
        XCTAssertTrue(app.buttons["Recently added"].isSelected)
        snap("t5-movies-sorted")

        sidebar(app, "YouTube")
        XCTAssertTrue(app.staticTexts["5 channels"].waitForExistence(timeout: 5))
        snap("t5-channels")

        // Home videos: a person narrows the timeline; months head the clips.
        sidebar(app, "Home videos")
        XCTAssertTrue(app.staticTexts["August 2026"].waitForExistence(timeout: 5))
        snap("t5-home-videos")
        press(.down, times: 2)
        sleep(1)
        snap("t5-home-videos-clips")

        // Search: type, then move down into what it found.
        sidebar(app, "Search", .up)
        snap("t5-search-empty")
        app.typeText("north")
        XCTAssertTrue(app.staticTexts["Said in"].waitForExistence(timeout: 5))
        sleep(2)
        snap("t5-search-results")
        press(.down, times: 2)
        sleep(1)
        snap("t5-search-results-down")
        press(.down, times: 6)
        sleep(1)
        snap("t5-search-said")
    }

    /// Moves along a row until `label` has focus.
    func along(_ app: XCUIApplication, to label: String, _ direction: XCUIRemote.Button = .right) {
        for _ in 0..<8 where !app.buttons[label].hasFocus { press(direction) }
        XCTAssertTrue(app.buttons[label].hasFocus, "Never reached \(label)")
    }

    func testThePlayer() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))
        press(.select)  // the hero's Resume
        XCTAssertTrue(app.staticTexts["Deep Field"].waitForExistence(timeout: 10))
        sleep(1)
        snap("t6-player")

        // The intro: Skip intro takes focus; a click skips it.
        XCTAssertTrue(app.buttons["Skip intro"].waitForExistence(timeout: 6))
        sleep(1)
        snap("t6-skip-intro")
        XCTAssertTrue(app.buttons["Skip intro"].hasFocus)
        press(.select)
        sleep(1)
        XCTAssertFalse(app.buttons["Skip intro"].exists)

        // Down to the row; pause; the subtitles and speed sheets.
        press(.playPause)
        press(.down)
        sleep(1)
        snap("t6-paused-row")
        along(app, to: "Subtitles")
        press(.select)
        sleep(1)
        snap("t6-subtitles")
        press(.menu)
        sleep(1)
        XCTAssertTrue(app.buttons["Subtitles"].hasFocus)
        along(app, to: "Related")
        press(.select)
        sleep(2)
        snap("t6-related")
        press(.menu)
        sleep(1)

        // Back to the picture, playing on into the credits: Up next
        // counts down, and takes focus from the picture.
        press(.menu)
        press(.playPause)
        XCTAssertTrue(app.buttons["Watch credits"].waitForExistence(timeout: 15))
        sleep(1)
        snap("t6-up-next")
        XCTAssertTrue(app.buttons["Play now"].hasFocus)
        press(.right)
        press(.select)
        sleep(1)
        XCTAssertFalse(app.buttons["Watch credits"].exists)
    }

    func testScrubbing() {
        let app = launch(["-StreamShowcaseScrub", "11"])
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))
        press(.select)
        XCTAssertTrue(app.staticTexts["Deep Field"].waitForExistence(timeout: 10))
        sleep(4)
        snap("t6-scrub")
        press(.right)
        sleep(1)
        snap("t6-scrub-right")
    }

    func testLiveTV() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))
        sidebar(app, "Grid")
        XCTAssertTrue(app.staticTexts["Grid"].waitForExistence(timeout: 5))
        sleep(3)
        snap("t7-guide")

        // Along the row until the window slides, then down a channel.
        press(.right, times: 4)
        sleep(1)
        snap("t7-guide-later")
        press(.down)
        sleep(1)
        snap("t7-guide-down")

        // A long press: favourite, hide, remind.
        remote.press(.select, forDuration: 1.6)
        sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["Hide from my guide"].waitForExistence(timeout: 5))
        snap("t7-guide-menu")
        press(.menu)
        sleep(1)

        // Hidden channels.
        press(.up, times: 3)
        along(app, to: "Hidden")
        press(.select)
        XCTAssertTrue(app.staticTexts["Hidden channels"].waitForExistence(timeout: 5))
        sleep(1)
        snap("t7-hidden")
        press(.menu)
        sleep(1)

        // Back to now; tune in to what's on.
        along(app, to: "Now", .left)
        press(.select)
        sleep(1)
        press(.down, times: 2)
        press(.select)
        XCTAssertTrue(app.staticTexts["What's on"].waitForExistence(timeout: 2) == false)
        sleep(4)
        snap("t7-live")
        press(.select)
        sleep(1)
        snap("t7-live-controls")
        along(app, to: "Guide")
        press(.select)
        XCTAssertTrue(app.staticTexts["What's on"].waitForExistence(timeout: 5))
        sleep(2)
        snap("t7-mini-guide")
        press(.menu)
        sleep(1)
        XCTAssertFalse(app.staticTexts["What's on"].exists)
    }

    /// Baseball (PROPOSAL §7.8): the day's games, a long press for the other
    /// team's broadcast, and a game playing in the stream player.
    func testBaseball() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))
        sidebar(app, "Baseball")
        XCTAssertTrue(app.staticTexts["Baseball"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Gulls"].waitForExistence(timeout: 5))
        sleep(2)
        snap("t8-baseball")

        press(.down)
        sleep(1)
        snap("t8-baseball-live-focused")
        remote.press(.select, forDuration: 1.6)
        sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["Foxes broadcast · FOX 9"].waitForExistence(timeout: 5))
        snap("t8-baseball-broadcasts")
        press(.menu)
        sleep(1)

        press(.down, times: 2)
        sleep(1)
        snap("t8-baseball-final")
        press(.up, times: 2)
        press(.select)
        // The stream player (the showcase answers with its one film).
        XCTAssertTrue(app.buttons["Back 10 seconds"].waitForExistence(timeout: 10))
        sleep(3)
        snap("t8-baseball-playing")
    }

    /// The Top Shelf's links: a page, the player, a Grid channel.
    func testTheTopShelfsLinksOpenTheApp() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))
        XCUIDevice.shared.system.open(URL(string: "stream://open/movie/northbound")!)
        XCTAssertTrue(app.staticTexts["Some journeys only go one way."].waitForExistence(timeout: 10))
        snap("t9-link-page")
        XCUIDevice.shared.system.open(URL(string: "stream://play/episode/deep-field-s1e3")!)
        XCTAssertTrue(app.staticTexts["S01E03 · The Long Exposure"].waitForExistence(timeout: 10))
        snap("t9-link-play")
        press(.menu)
        press(.menu)
        sleep(1)
        XCUIDevice.shared.system.open(URL(string: "stream://live/5")!)
        XCTAssertTrue(app.staticTexts["Signal Fires"].waitForExistence(timeout: 10))
        sleep(2)
        snap("t9-link-live")
    }
}
