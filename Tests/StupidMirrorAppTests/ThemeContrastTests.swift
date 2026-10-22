import AppKit
import SwiftUI
import XCTest
@testable import StupidMirrorApp

final class ThemeContrastTests: XCTestCase {
    func testSemanticLabelColorsMeetNormalTextContrastInBothAppearances() throws {
        let colors: [(String, Color)] = [
            ("accent", Theme.Palette.accent),
            ("live", Theme.Palette.live),
            ("pending", Theme.Palette.pending),
            ("danger", Theme.Palette.danger),
            ("control", Theme.Palette.control),
        ]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let background = appearance == .darkAqua
                ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                : NSColor.white

            for (name, color) in colors {
                let ratio = try contrastRatio(
                    foreground: resolved(color, appearance: appearance),
                    background: background
                )
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    4.5,
                    "\(name) is only \(ratio):1 in \(appearance.rawValue)"
                )
            }
        }
    }

    func testOverlayLabelsMeetNormalTextContrastInBothAppearances() throws {
        let labels: [(String, Color)] = [
            ("primary", Theme.Overlay.primaryText),
            ("secondary", Theme.Overlay.secondaryText),
            ("tertiary", Theme.Overlay.tertiaryText),
        ]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let surface = resolved(Theme.Overlay.surface, appearance: appearance)
            for (name, color) in labels {
                let ratio = try contrastRatio(
                    foreground: resolved(color, appearance: appearance),
                    background: surface
                )
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    4.5,
                    "overlay \(name) is only \(ratio):1 in \(appearance.rawValue)"
                )
            }
        }
    }

    func testTextTokensMeetNormalTextContrastOnEverySurface() throws {
        let inks: [(String, Color)] = [
            ("primary", Theme.Ink.primary),
            ("secondary", Theme.Ink.secondary),
            ("tertiary", Theme.Ink.tertiary),
        ]
        let surfaces: [(String, Color)] = [
            ("ground", Theme.Surface.ground),
            ("panel", Theme.Surface.panel),
            ("well", Theme.Surface.well),
            ("raised", Theme.Surface.raised),
            ("selected", Theme.Surface.selected),
        ]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (surfaceName, surface) in surfaces {
                for (inkName, ink) in inks {
                    let ratio = try contrastRatio(
                        foreground: resolved(ink, appearance: appearance),
                        background: resolved(surface, appearance: appearance)
                    )
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        4.5,
                        "\(inkName) on \(surfaceName) is only \(ratio):1 in \(appearance.rawValue)"
                    )
                }
            }
            let buttonRatio = try contrastRatio(
                foreground: resolved(Theme.Ink.inverse, appearance: appearance),
                background: resolved(Theme.Ink.primaryFill, appearance: appearance)
            )
            XCTAssertGreaterThanOrEqual(buttonRatio, 4.5, "primary button label in \(appearance.rawValue)")
        }
    }

    private func resolved(_ color: Color, appearance: NSAppearance.Name) -> NSColor {
        let resolvedAppearance = NSAppearance(named: appearance)!
        var result = NSColor.clear
        resolvedAppearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return result
    }

    private func contrastRatio(foreground: NSColor, background: NSColor) throws -> Double {
        let foregroundLuminance = try relativeLuminance(foreground)
        let backgroundLuminance = try relativeLuminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) throws -> Double {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }
}
