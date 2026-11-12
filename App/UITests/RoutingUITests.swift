import AppKit
import Carbon
import XCTest

final class RoutingUITests: XCTestCase {
    @MainActor
    func testAccessibleRoutingAndRoomLayouts() throws {
        for appearance in ["--light", "--dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--demo", appearance]
            app.launch()
            defer { app.terminate() }
            let source = app.buttons["connector-demo:input-main"]
            XCTAssertTrue(source.waitForExistence(timeout: 10))
            source.click()
            app.buttons["connector-demo:layer-main"].click()
            for room in ["Studio", "Desktop", "Glass", "Route List"] {
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
            app.buttons["[ + Save Current Setup ]"].click()
            XCTAssertTrue(app.buttons["create-preset"].waitForExistence(timeout: 5))
            app.buttons["create-preset"].click()
            XCTAssertTrue(app.staticTexts["New Setup"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["inspector-close"].exists)
            XCTAssertFalse(app.buttons["page-monitor"].exists)
            app.activate()
            app.menuBars.menuBarItems["View"].click()
            app.menuItems["MIDI Monitor"].click()
            XCTAssertTrue(app.textFields["monitor-filter"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Monitor Paused"].exists)
            app.buttons["panic"].click()
        }
    }

    @MainActor
    func testPointToPointDragAddsFanOutWithoutReplacingRoute() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        defer { app.terminate() }
        let source = app.buttons["connector-demo:input-main"]
        let target = app.buttons["connector-demo:layer-main"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(target.exists)
        source.click(forDuration: 0.2, thenDragTo: target)
        app.buttons["room-picker"].click()
        app.buttons["Route List"].click()
        XCTAssertEqual(app.buttons.matching(identifier: "Remove route").count, 2)
        XCTAssertTrue(app.staticTexts["Demo Keys  >  Demo Synth"].exists)
        XCTAssertTrue(app.staticTexts["Demo Keys  >  Demo Layer"].exists)
    }

    @MainActor
    func testCreateEditRemoveAndUndoRouteUsingControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["new-route"].waitForExistence(timeout: 10))
        app.buttons["new-route"].click()
        XCTAssertTrue(app.buttons["create-route"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["create-route"].click()
        closeInspector(in: app)
        app.buttons["room-picker"].click()
        app.buttons["Route List"].click()
        app.buttons["[ Edit ]"].firstMatch.click()
        let transpose = app.textFields["Transpose in semitones"]
        XCTAssertTrue(transpose.waitForExistence(timeout: 5))
        transpose.click()
        let routesBeforeTyping = app.buttons.matching(identifier: "Remove route").count
        try typeShortcut("a", in: transpose)
        transpose.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(transpose.value as? String, "")
        XCTAssertEqual(app.buttons.matching(identifier: "Remove route").count, routesBeforeTyping)
        transpose.typeText("7")
        XCTAssertEqual(transpose.value as? String, "7")
        transpose.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.sheets.count, 0)
        closeInspector(in: app)
        let remove = app.buttons.matching(identifier: "Remove route")
        let count = remove.count
        XCTAssertGreaterThan(count, 0)
        remove.firstMatch.click()
        waitForCount(remove, equals: count - 1)
        XCTAssertEqual(app.state, .runningForeground)
        try typeShortcut("z", in: app.windows["main"])
        XCTAssertEqual(app.state, .runningForeground)
        waitForCount(remove, equals: count)
        try typeShortcut("z", modifiers: [.command, .shift], in: app.windows["main"])
        waitForCount(remove, equals: count - 1)
        try typeShortcut("z", in: app.windows["main"])
        waitForCount(remove, equals: count)
    }

    @MainActor
    func testCommittedTransposePreservesRejectedDraftWithoutSavingIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        defer { app.terminate() }
        let route = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "route-label-")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        app.activate()
        route.click()
        let transpose = app.textFields["route-transpose"]
        XCTAssertTrue(transpose.waitForExistence(timeout: 5))
        XCTAssertEqual(transpose.label, "Transpose in semitones")
        transpose.click()
        try typeShortcut("a", in: transpose)
        transpose.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(transpose.value as? String, "")
        transpose.typeText("7")
        transpose.typeKey(.return, modifierFlags: [])
        closeInspector(in: app)
        route.click()
        XCTAssertTrue(transpose.waitForExistence(timeout: 5))
        XCTAssertEqual(transpose.value as? String, "7")
        transpose.click()
        try typeShortcut("a", in: transpose)
        transpose.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(transpose.value as? String, "")
        transpose.typeText("128")
        transpose.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Invalid Transpose in semitones"].waitForExistence(timeout: 5))
        XCTAssertEqual(transpose.value as? String, "128")
        closeInspector(in: app)
        route.click()
        XCTAssertTrue(transpose.waitForExistence(timeout: 5))
        XCTAssertEqual(transpose.value as? String, "7")
    }

    @MainActor
    func testClickingCableSelectsItAndDeleteRemovesIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        defer { app.terminate() }
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
        closeInspector(in: app)
        XCTAssertEqual(source.frame, sourceFrame)
        XCTAssertEqual(destination.frame, destinationFrame)
        window.coordinate(withNormalizedOffset: .zero).withOffset(point).click()
        XCTAssertTrue(app.buttons["inspector-close"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0)
        window.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "route-label-")).count, 0)
    }

    @MainActor
    func testPopupKeyboardSelectionAndEscapeKeepInspectorOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["new-route"].waitForExistence(timeout: 10))
        app.buttons["new-route"].click()
        let window = app.windows["main"]
        let popup = app.descendants(matching: .any).matching(identifier: "popup-menu").firstMatch
        app.buttons["room-picker"].click()
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(popup.exists)
        XCTAssertEqual(app.buttons["room-picker"].value as? String, "Route List")
        XCTAssertTrue(app.buttons["inspector-close"].exists)
        app.buttons["route-channel"].click()
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        window.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(popup.exists)
        XCTAssertTrue(app.buttons["inspector-close"].exists)
        window.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.buttons["route-channel"].value as? String, "Channel 1")
    }

    @MainActor
    func testConnectionHintTracksRoutesAndSourceCanCancel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        defer { app.terminate() }
        let source = app.buttons["connector-demo:input-main"]
        let destination = app.buttons["connector-demo:output-main"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(source.isHittable)
        let ready = XCTAttachment(screenshot: app.windows["main"].screenshot())
        ready.name = "connection-before-selection"
        ready.lifetime = .keepAlways
        add(ready)
        let frame = source.frame
        source.click()
        XCTAssertFalse(app.buttons["Cancel"].exists)
        XCTAssertEqual(source.frame, frame)
        source.click()
        app.buttons["connector-demo:layer-main"].click()
        XCTAssertTrue(app.buttons["create-route"].waitForExistence(timeout: 5))
        closeInspector(in: app)
        app.buttons["room-picker"].click()
        app.buttons["Route List"].click()
        let routes = app.buttons.matching(identifier: "Remove route")
        XCTAssertEqual(routes.count, 1)
        routes.firstMatch.click()
        app.buttons["room-picker"].click()
        app.buttons["Studio"].click()
        source.click()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        destination.click()
        XCTAssertFalse(app.buttons["Cancel"].exists)
        source.click()
        XCTAssertFalse(app.buttons["Cancel"].exists)
        source.click()
    }

    @MainActor
    func testMenuAndPatchbayOmitPerimeterFocusRings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        defer { app.terminate() }
        let source = app.buttons["connector-demo:input-main"]
        let destination = app.buttons["connector-demo:output-main"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let window = app.windows["main"]
        app.buttons["room-picker"].click()
        let popup = app.descendants(matching: .any).matching(identifier: "popup-menu").firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        XCTAssertFalse(try hasFocusRingAbove(popup.frame, in: window))
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.buttons["room-picker"].value as? String, "Route List")
        app.buttons["room-picker"].click()
        window.typeKey(.upArrow, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.buttons["room-picker"].value as? String, "Studio")
        let point = CGVector(
            dx: source.frame.maxX + (destination.frame.minX - source.frame.maxX) * 0.25 - window.frame.minX,
            dy: source.frame.midY - window.frame.minY)
        window.coordinate(withNormalizedOffset: .zero).withOffset(point).click()
        XCTAssertTrue(app.buttons["inspector-close"].waitForExistence(timeout: 5))
        let patchbay = app.scrollViews["MIDI Patchbay"]
        XCTAssertTrue(patchbay.exists)
        XCTAssertFalse(try hasFocusRingAbove(patchbay.frame, in: window))
        window.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "route-label-")).count, 0)
    }

    @MainActor
    private func typeShortcut(
        _ key: String, modifiers: XCUIElement.KeyModifierFlags = .command, in element: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let original = try XCTUnwrap(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), file: file, line: line)
        let ascii = try XCTUnwrap(
            TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(), file: file, line: line)
        defer { XCTAssertEqual(TISSelectInputSource(original), noErr, file: file, line: line) }
        let selected = TISSelectInputSource(ascii)
        XCTAssertEqual(selected, noErr, file: file, line: line)
        guard selected == noErr else { return }
        element.typeKey(key, modifierFlags: modifiers)
    }

    @MainActor
    private func closeInspector(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["inspector-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), file: file, line: line)
        close.click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor
    private func waitForCount(
        _ query: XCUIElementQuery, equals count: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %ld", count), object: query)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 5), .completed, file: file, line: line)
        XCTAssertEqual(query.count, count, file: file, line: line)
    }

    @MainActor
    private func hasFocusRingAbove(_ frame: CGRect, in window: XCUIElement) throws -> Bool {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
        let focus = try XCTUnwrap(NSColor.keyboardFocusIndicatorColor.usingColorSpace(.sRGB))
        let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
        let left = frame.minX - window.frame.minX + 8
        let width = frame.width - 16
        let top = frame.minY - window.frame.minY
        XCTAssertGreaterThan(width, 0)
        for offset in -6...6 {
            let y = Int((top + CGFloat(offset)) * scale)
            guard (0..<bitmap.pixelsHigh).contains(y) else { continue }
            var matches = 0
            for sample in 0..<100 {
                let x = Int((left + width * CGFloat(sample) / 100) * scale)
                guard (0..<bitmap.pixelsWide).contains(x),
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let hue = abs(color.hueComponent - focus.hueComponent)
                if min(hue, 1 - hue) < 0.06 && color.saturationComponent > 0.2 {
                    matches += 1
                }
            }
            if matches > 80 { return true }
        }
        return false
    }

}
