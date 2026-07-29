//
//  SentTabRecipientsUITests.swift
//  Dot GridUITests
//
//  Regression coverage for the sent-tab recipient display (2026-07-29): a
//  two-person send names both people (no "+1" collapse), and a larger group
//  shows the first two plus a tappable "& N more" that opens the full
//  recipients list. Seeds fixture sends via SeedSentDemo (-SeedSentDemo
//  launch arg) since there's no live iCloud pairing in the simulator.
//

import XCTest

final class SentTabRecipientsUITests: XCTestCase {

    @MainActor
    func testSentTabShowsNamesAndExpandsGroup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-SeedSentDemo"]
        app.launch()

        let inbox = app.buttons["dotdot inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), "wordmark missing")
        inbox.tap()

        let sentTab = app.buttons["sent"]
        XCTAssertTrue(sentTab.waitForExistence(timeout: 5), "inbox tabs missing")
        sentTab.tap()

        // Single recipient: plain "to alice", no chevron/button.
        XCTAssertTrue(app.staticTexts["to alice"].waitForExistence(timeout: 5),
                      "single-recipient title missing")

        // Two recipients: BOTH named, no "+1" collapse.
        XCTAssertTrue(app.staticTexts["to alice & ben"].waitForExistence(timeout: 5),
                      "two-recipient send collapsed instead of naming both")

        // Group of 4: first two named + "& 2 more", exposed as one tappable button.
        let group = app.buttons["sent to 4 people"]
        XCTAssertTrue(group.waitForExistence(timeout: 5), "group send row missing/not tappable")

        let sentTabShot = XCTAttachment(screenshot: app.screenshot())
        sentTabShot.name = "sent-tab"
        sentTabShot.lifetime = .keepAlways
        add(sentTabShot)

        group.tap()

        // The full-list sheet names everyone, including the two hidden behind "& 2 more".
        XCTAssertTrue(app.staticTexts["cara"].waitForExistence(timeout: 5),
                      "recipients sheet missing 'cara'")
        XCTAssertTrue(app.staticTexts["dev"].waitForExistence(timeout: 5),
                      "recipients sheet missing 'dev'")

        let sheetShot = XCTAttachment(screenshot: app.screenshot())
        sheetShot.name = "recipients-sheet"
        sheetShot.lifetime = .keepAlways
        add(sheetShot)
    }
}
