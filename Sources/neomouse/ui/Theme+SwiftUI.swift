import AppKit
import SwiftUI

import neomouseConfig

// Bridges the pure-data theme model (`Sources/neomouseConfig/theme.swift`)
// into the SwiftUI / AppKit types every overlay actually consumes. Lives in
// the executable target so neomouseConfig stays UI-framework-free and
// reusable from non-UI targets / tests.

extension ThemeColor {
    /// SwiftUI Color in sRGB (the default color space) — matches what
    /// `Color(.sRGB, red:green:blue:opacity:)` produces.
    public var swiftUI: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// AppKit NSColor for places that take NSColor directly (panel
    /// backgrounds, border layers, NSAttributedString, etc.).
    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension ThemeFont {
    /// SwiftUI Font built per the spec. When `family` is set we use
    /// `Font.custom(...)`; weight applies on top via `.weight(_:)`. When
    /// `family` is empty (the default) we use `Font.system(size:weight:design:)`.
    public var swiftUI: Font {
        let w = swiftUIWeight
        let d = swiftUIDesign
        if !family.isEmpty {
            return Font.custom(family, size: size).weight(w)
        }
        return Font.system(size: size, weight: w, design: d)
    }

    /// AppKit NSFont equivalent. Family override falls back to system font
    /// when the family name isn't available on the host.
    public var nsFont: NSFont {
        if !family.isEmpty, let custom = NSFont(name: family, size: size) {
            return custom
        }
        return NSFont.systemFont(ofSize: size, weight: nsWeight)
    }

    private var swiftUIWeight: Font.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    private var swiftUIDesign: Font.Design {
        switch design {
        case .default: return .default
        case .monospaced: return .monospaced
        case .serif: return .serif
        case .rounded: return .rounded
        }
    }

    private var nsWeight: NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

extension ThemeMaterial {
    /// SwiftUI `Material` for `.background(...)`. Use this directly with
    /// SwiftUI views; for raw NSVisualEffectView (e.g. in `NSPanel`-based
    /// overlays) use `nsMaterial` instead.
    public var swiftUI: Material {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .ultraThick: return .ultraThickMaterial
        case .bar: return .bar
        case .hud: return .regularMaterial  // SwiftUI has no .hud — closest fit
        }
    }

    /// NSVisualEffectView material name.
    public var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .ultraThin: return .popover
        case .thin: return .menu
        case .regular: return .sidebar
        case .thick: return .windowBackground
        case .ultraThick: return .underWindowBackground
        case .bar: return .titlebar
        case .hud: return .hudWindow
        }
    }
}

extension ThemeAnchor {
    /// Compute the top-left origin (in AppKit/NSScreen coordinates — y from
    /// bottom of screen) for a panel of `size` anchored at this point on
    /// `frame` (typically `NSScreen.visibleFrame`), with the supplied
    /// `offsetX` / `offsetY` pushing the panel inward from the anchor edge.
    ///
    /// Convention: positive offsetX pushes RIGHTWARD from a left anchor and
    /// LEFTWARD from a right anchor; positive offsetY pushes DOWNWARD from
    /// a top anchor and UPWARD from a bottom anchor. So "20pt offset from
    /// the edge" always means "20pt of clearance between the panel and
    /// that edge of the screen," regardless of which anchor you pick.
    public func origin(in frame: CGRect, panelSize: CGSize, offsetX: Double, offsetY: Double)
        -> CGPoint
    {
        let ox = CGFloat(offsetX)
        let oy = CGFloat(offsetY)
        let w = panelSize.width
        let h = panelSize.height

        let left = frame.minX + ox
        let right = frame.maxX - w - ox
        let centerX = frame.minX + (frame.width - w) / 2 + ox

        // AppKit Y origin is at the bottom of the screen, so "top" anchor
        // means y closer to maxY, "bottom" means y closer to minY.
        let top = frame.maxY - h - oy
        let bottom = frame.minY + oy
        let centerY = frame.minY + (frame.height - h) / 2 + oy

        switch self {
        case .top: return CGPoint(x: centerX, y: top)
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .center: return CGPoint(x: centerX, y: centerY)
        case .centerLeft: return CGPoint(x: left, y: centerY)
        case .centerRight: return CGPoint(x: right, y: centerY)
        case .bottom: return CGPoint(x: centerX, y: bottom)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }
}
