import ApplicationServices
import XCTest

final class RoutingUITests: XCTestCase {
    @MainActor
    func testAccessibleRoutingAndRoomLayouts() throws {
        for appearance in ["--light", "--dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--demo", appearance]
            app.launch()
            let source = app.buttons["connector-demo:input-main"]
            XCTAssertTrue(source.waitForExistence(timeout: 10))
            source.click()
            app.buttons["connector-demo:layer-main"].click()
            for room in ["Studio", "Desktop", "Glass", "Terminal"] {
                app.buttons["room-picker"].click()
                app.buttons[room].click()
                let shot = XCTAttachment(screenshot: app.windows["main"].screenshot())
                shot.name = "\(room.lowercased())-\(appearance.dropFirst(2))"
                shot.lifetime = .keepAlways
                add(shot)
            }
            XCTAssertEqual(app.buttons.matching(identifier: "Remove route").count, 2)
            app.buttons["page-devices"].click()
            XCTAssertTrue(app.staticTexts["Demo Keys"].exists)
            app.buttons["page-presets"].click()
            XCTAssertTrue(app.staticTexts["Demo Octave"].exists)
            app.buttons["page-monitor"].click()
            XCTAssertTrue(app.textFields["monitor-filter"].waitForExistence(timeout: 5))
            app.buttons["panic"].click()
            app.terminate()
        }
    }

    @MainActor
    func testPointToPointDragAddsFanOutWithoutReplacingRoute() throws {
        guard requireEventPermission() else { return }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        let source = app.buttons["connector-demo:input-main"]
        let target = app.buttons["connector-demo:layer-main"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(target.exists)
        source.press(forDuration: 0.2, thenDragTo: target)
        app.buttons["room-picker"].click()
        app.buttons["Terminal"].click()
        XCTAssertEqual(app.buttons.matching(identifier: "Remove route").count, 2)
        XCTAssertTrue(app.staticTexts["Demo Keys  >  Demo Synth"].exists)
        XCTAssertTrue(app.staticTexts["Demo Keys  >  Demo Layer"].exists)
        app.terminate()
    }

    @MainActor
    func testCreateEditRemoveAndUndoRouteUsingControls() throws {
        guard requireEventPermission() else { return }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["new-route"].waitForExistence(timeout: 10))
        app.buttons["new-route"].click()
        XCTAssertTrue(app.buttons["create-route"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["create-route"].click()
        app.buttons["inspector-close"].click()
        app.buttons["room-picker"].click()
        app.buttons["Terminal"].click()
        app.buttons["[ Edit ]"].firstMatch.click()
        let transpose = app.textFields["Transpose in semitones"]
        XCTAssertTrue(transpose.waitForExistence(timeout: 5))
        transpose.click()
        let routesBeforeTyping = app.buttons.matching(identifier: "Remove route").count
        transpose.typeKey("a", modifierFlags: .command)
        transpose.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(transpose.value as? String, "")
        XCTAssertEqual(app.buttons.matching(identifier: "Remove route").count, routesBeforeTyping)
        transpose.typeText("7")
        XCTAssertEqual(transpose.value as? String, "7")
        transpose.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["inspector-close"].click()
        let remove = app.buttons.matching(identifier: "Remove route")
        let count = remove.count
        XCTAssertGreaterThan(count, 0)
        remove.firstMatch.click()
        XCTAssertEqual(remove.count, count - 1)
        app.windows["main"].typeKey("z", modifierFlags: .command)
        XCTAssertEqual(remove.count, count)
        app.terminate()
    }

    @MainActor
    func testClickingCableSelectsItAndDeleteRemovesIt() throws {
        guard requireEventPermission() else { return }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        let source = app.buttons["connector-demo:input-main"]
        let destination = app.buttons["connector-demo:output-main"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let window = app.windows["main"]
        let sourceFrame = source.frame
        let destinationFrame = destination.frame
        let point = CGVector(
            dx: source.frame.maxX + (destination.frame.minX - source.frame.maxX) * 0.25 - window.frame.minX,
            dy: source.frame.midY - window.frame.minY)
        window.coordinate(withNormalizedOffset: .zero).withOffset(point).click()
        XCTAssertTrue(app.buttons["inspector-close"].waitForExistence(timeout: 5))
        XCTAssertEqual(source.frame, sourceFrame)
        XCTAssertEqual(destination.frame, destinationFrame)
        app.buttons["inspector-close"].click()
        XCTAssertEqual(source.frame, sourceFrame)
        XCTAssertEqual(destination.frame, destinationFrame)
        window.coordinate(withNormalizedOffset: .zero).withOffset(point).click()
        XCTAssertTrue(app.buttons["inspector-close"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0)
        window.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "route-label-")).count, 0)
        app.terminate()
    }

    @MainActor
    func testPopupKeyboardSelectionAndEscapeKeepInspectorOpen() throws {
        guard requireEventPermission() else { return }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["new-route"].waitForExistence(timeout: 10))
        app.buttons["new-route"].click()
        let window = app.windows["main"]
        let popup = app.descendants(matching: .any).matching(identifier: "popup-menu").firstMatch
        app.buttons["room-picker"].click()
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(popup.exists)
        XCTAssertEqual(app.buttons["room-picker"].value as? String, "Terminal")
        XCTAssertTrue(app.buttons["inspector-close"].exists)
        app.buttons["route-channel"].click()
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        window.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(popup.exists)
        XCTAssertTrue(app.buttons["inspector-close"].exists)
        app.buttons["route-channel"].click()
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.buttons["route-channel"].value as? String, "Channel 1")
        app.terminate()
    }

    private func requireEventPermission(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let permitted = CGPreflightPostEventAccess()
        XCTAssertTrue(
            permitted,
            "macOS has not authorized this UI-test runner to post input events. Grant Accessibility access to the runner before testing drag gestures and keyboard shortcuts.",
            file: file, line: line)
        return permitted
    }
}
