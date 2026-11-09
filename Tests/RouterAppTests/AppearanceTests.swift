import AppKit
import XCTest

@testable import MIDIRouterApp

@MainActor
final class AppearanceTests: XCTestCase {
    func testSecondaryTextMeetsContrastInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let foreground = RouterStyle.secondaryColor.usingColorSpace(.sRGB)!
                let background = NSColor.controlBackgroundColor.usingColorSpace(.sRGB)!
                let alpha = Double(foreground.alphaComponent) * RouterStyle.secondaryOpacity
                let fg = [foreground.redComponent, foreground.greenComponent, foreground.blueComponent].map(Double.init)
                let bg = [background.redComponent, background.greenComponent, background.blueComponent].map(Double.init)
                let composed = zip(fg, bg).map { $0 * alpha + $1 * (1 - alpha) }
                let first = luminance(composed)
                let second = luminance(bg)
                let ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "Secondary text in \(name.rawValue)")
            }
        }
    }
    private func luminance(_ values: [Double]) -> Double {
        let linear = values.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}
