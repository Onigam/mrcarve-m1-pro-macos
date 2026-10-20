import Foundation
import AppKit
import MRCarveKit

/// Display unit for lengths. Everything is stored in millimetres.
enum LengthUnit: String, CaseIterable, Identifiable {
    case millimeters, inches

    var id: String { rawValue }
    var symbol: String { self == .millimeters ? "mm" : "in" }
    var title: String { self == .millimeters ? L("Millimetres") : L("Inches") }
    var fractionDigits: Int { self == .millimeters ? 2 : 4 }

    func display(_ mm: Double) -> Double { self == .millimeters ? mm : mm / 25.4 }
    func millimeters(_ value: Double) -> Double { self == .millimeters ? value : value * 25.4 }

    /// "12.35 mm"
    func format(_ mm: Double, digits: Int? = nil) -> String {
        let v = display(mm)
        return v.formatted(.number.precision(.fractionLength(0...(digits ?? fractionDigits)))) + " " + symbol
    }
}

enum Format {
    /// "0:42", "12:05", "1:02:03"
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let s = Int(seconds.rounded(.up))
        if s < 60 { return L("%d s", s) }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func number(_ v: Double, digits: Int = 2) -> String {
        v.formatted(.number.precision(.fractionLength(0...digits)))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

extension NSColor {
    /// Colour of a pen (`0xRRGGBB`).
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    /// `0xRRGGBB` of this colour in sRGB.
    var rgbValue: UInt32 {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        func b(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return b(c.redComponent) << 16 | b(c.greenComponent) << 8 | b(c.blueComponent)
    }

    /// Light/dark dynamic colour.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// Pen colours adjusted so that black stays visible in dark mode and yellow on white.
enum PenColor {
    static func display(_ rgb: UInt32, dark: Bool) -> NSColor {
        let r = Double((rgb >> 16) & 0xFF) / 255, g = Double((rgb >> 8) & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let base = NSColor(rgb: rgb)
        if dark && luminance < 0.3 {
            return base.blended(withFraction: 0.65 - luminance, of: .white) ?? base
        }
        if !dark && luminance > 0.8 {
            return base.blended(withFraction: 0.3, of: .black) ?? base
        }
        return base
    }

    /// Small filled circle used as a pen swatch in menus (where SwiftUI shapes are not rendered).
    @MainActor static func swatchImage(_ rgb: UInt32, size: CGFloat = 12) -> NSImage {
        if let cached = swatchCache[rgb] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor(rgb: rgb).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        swatchCache[rgb] = image
        return image
    }

    @MainActor private static var swatchCache: [UInt32: NSImage] = [:]
}

extension DesignObject {
    /// SF Symbol for the object kind.
    var symbolName: String {
        switch kind {
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .polygon(_, let star): star == nil ? "hexagon" : "star"
        case .line: "line.diagonal"
        case .vector: "scribble.variable"
        case .image: "photo"
        }
    }

    /// Localized name of the kind.
    var kindTitle: String {
        switch kind {
        case .text: L("Text")
        case .rectangle: L("Rectangle")
        case .ellipse: L("Ellipse")
        case .polygon(_, let star): star == nil ? L("Polygon") : L("Star")
        case .line: L("Line")
        case .vector: L("Vector")
        case .image: L("Image")
        }
    }
}

extension PenParameters {
    /// The pen's name; untouched default names ("Pen 3") are shown localized.
    var displayName: String { name == "Pen \(id)" ? L("Pen %d", id) : name }
}

extension DitherMode {
    var title: String {
        switch self {
        case .threshold: L("Threshold")
        case .floydSteinberg: L("Floyd–Steinberg")
        case .jarvis: L("Jarvis")
        case .stucki: L("Stucki")
        case .atkinson: L("Atkinson")
        case .ordered: L("Ordered (Bayer)")
        }
    }
}

extension LaserSource {
    var title: String { self == .fiber ? L("Fiber (1064 nm)") : L("Blue diode") }
    var shortTitle: String { self == .fiber ? L("Fiber") : L("Blue") }
}
