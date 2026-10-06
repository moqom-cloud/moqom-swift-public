import XCTest

@MainActor
final class JoinFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--loopback",
            "-username", "",
            "-roomName", "demo",
            "-pairingCode", "",
        ]
        app.launch()
        return app
    }

    private func joinButton(in app: XCUIApplication) -> XCUIElement {
        let join = app.buttons["Join"]
        var swipes = 0
        while !join.exists, swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        return join
    }

    private func tapJoin(in app: XCUIApplication) {
        let join = joinButton(in: app)
        XCTAssertTrue(join.waitForExistence(timeout: 5), "Join never came into view")
        join.tap()
    }

    private func menuItem(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let item = app.buttons[name]
        var swipes = 0
        while !item.exists, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        return item
    }

    private func usernameField(in app: XCUIApplication) -> XCUIElement {
        let username = app.textFields["Username"]
        var swipes = 0
        while !username.exists, swipes < 8 {
            app.swipeDown()
            swipes += 1
        }
        return username
    }

    func testJoiningARoomReachesTheRoomScreen() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10), "join screen never appeared")

        username.tap()
        username.typeText("alice")

        tapJoin(in: app)

        XCTAssertTrue(
            app.navigationBars["demo"].waitForExistence(timeout: 15),
            "never reached the room screen"
        )

        XCTAssertTrue(app.staticTexts["Nobody on stage"].waitForExistence(timeout: 5))

        app.buttons["Room"].tap()
        XCTAssertTrue(menuItem("Leave", in: app).exists, "Leave never came into view")
        XCTAssertTrue(app.buttons["Record session"].exists)
    }

    func testGoingLiveAndPublishingAudio() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("alice")
        tapJoin(in: app)
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        app.buttons["Go live"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 5) {
            XCTFail("go live failed: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Nobody on stage"].exists)

        XCTAssertTrue(app.buttons["End audio"].waitForExistence(timeout: 10))

        app.buttons["End audio"].tap()
        XCTAssertTrue(app.buttons["Audio"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Stop"].exists, "ending audio ended the broadcast")
        app.buttons["Audio"].tap()
        XCTAssertTrue(app.buttons["End audio"].waitForExistence(timeout: 10))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
    }

    func testMutingTheMicrophoneAndCameraWithoutEndingEither() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("alice")
        tapJoin(in: app)
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        XCTAssertFalse(app.buttons["Camera off"].isEnabled)
        XCTAssertFalse(app.buttons["Mute"].isEnabled)

        app.buttons["Go live"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["End audio"].waitForExistence(timeout: 10))

        app.buttons["Mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5))

        app.buttons["Camera off"].tap()
        XCTAssertTrue(app.buttons["Camera on"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["Stop"].exists, "muting the camera ended the broadcast")
        XCTAssertTrue(app.buttons["End audio"].exists, "muting the mic ended the publication")
        XCTAssertFalse(app.staticTexts["Nobody on stage"].exists, "muting took us off stage")

        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 3),
            "muting raised: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))"
        )

        app.buttons["Unmute"].tap()
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 5))
        app.buttons["Camera on"].tap()
        XCTAssertTrue(app.buttons["Camera off"].waitForExistence(timeout: 5))
    }

    func testFlippingIsOfferedOnlyForARealCamera() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("alice")
        tapJoin(in: app)
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        app.buttons["Go live"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.buttons["Flip"].exists)
        XCTAssertFalse(app.buttons["Flip"].isEnabled)

        app.buttons["Input"].tap()
        let video = app.buttons["Camera"]
        XCTAssertTrue(video.waitForExistence(timeout: 5), "no video input picker in the menu")
    }

    func testSwitchingToTheAudioRoomLayout() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("alice")
        tapJoin(in: app)
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        app.buttons["Room"].tap()
        let audioRoom = app.buttons["Audio room"]
        XCTAssertTrue(audioRoom.waitForExistence(timeout: 5))
        audioRoom.tap()

        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 3),
            "switching layout raised: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        XCTAssertTrue(app.navigationBars["demo"].exists)
    }

    func testChoosingWhoStaysInTheSmallWindow() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("alice")
        tapJoin(in: app)
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        app.buttons["Room"].tap()
        let cast = app.buttons["Cohosts and guests"]
        XCTAssertTrue(cast.waitForExistence(timeout: 5), "the cast picker is not in the menu")
        cast.tap()

        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 3),
            "choosing a cast raised: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        XCTAssertTrue(app.navigationBars["demo"].exists)
    }

    func testJoinIsRefusedUntilThereIsAName() {
        let app = launch()

        XCTAssertTrue(
            app.textFields["Username"].waitForExistence(timeout: 10),
            "join screen never appeared"
        )
        XCTAssertTrue(joinButton(in: app).exists, "Join never came into view")
        XCTAssertFalse(joinButton(in: app).isEnabled, "Join was enabled with no username")

        let username = usernameField(in: app)
        username.tap()
        username.typeText("   ")
        XCTAssertFalse(joinButton(in: app).isEnabled, "Join was enabled with only whitespace")

        usernameField(in: app).typeText("alice")
        XCTAssertTrue(joinButton(in: app).isEnabled)
    }

    func testLeavingReturnsToTheJoinScreen() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("alice")
        tapJoin(in: app)

        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        app.buttons["Room"].tap()
        let leave = menuItem("Leave", in: app)
        XCTAssertTrue(leave.exists, "Leave never came into view")
        leave.tap()

        XCTAssertTrue(
            app.textFields["Username"].waitForExistence(timeout: 10),
            "leaving did not return to the join screen"
        )
    }
}
