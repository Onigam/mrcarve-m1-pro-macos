import SwiftUI
import AppKit
import MRCarveKit

/// Installed font families for the font picker (engine list, falling back to AppKit's).
@MainActor
enum FontList {
    static let families: [String] = {
        let engine = TextOutliner.availableFontFamilies()
        return engine.isEmpty ? NSFontManager.shared.availableFontFamilies.sorted() : engine
    }()

    static var defaultFamily: String {
        families.contains("Helvetica Neue") ? "Helvetica Neue" : (families.first ?? "Helvetica")
    }
}

/// A labelled numeric text field with optional unit, range clamp and stepper.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit: String? = nil
    var range: ClosedRange<Double>? = nil
    var step: Double? = nil
    var digits: Int = 2
    var help: String? = nil

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { v in
            guard v.isFinite else { return }
            if let range { value = min(max(v, range.lowerBound), range.upperBound) } else { value = v }
        })
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: clamped, format: .number.precision(.fractionLength(0...digits)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 56, maxWidth: 84)
                if let step {
                    Stepper(title, value: clamped, step: step).labelsHidden()
                }
                if let unit {
                    Text(unit).foregroundStyle(.secondary).font(.callout).frame(minWidth: 30, alignment: .leading)
                }
            }
        }
        .help(help ?? title)
    }
}

/// A length field in the user's display unit (values are stored in mm).
struct LengthField: View {
    let title: String
    @Binding var millimeters: Double
    var range: ClosedRange<Double>? = nil
    var step: Double? = nil
    private var settings: AppSettings { .shared }

    var body: some View {
        let unit = settings.units
        NumberField(title: title,
                    value: Binding(get: { unit.display(millimeters) }, set: { millimeters = unit.millimeters($0) }),
                    unit: unit.symbol,
                    range: range.map { unit.display($0.lowerBound)...unit.display($0.upperBound) },
                    step: step.map { unit.display($0) },
                    digits: unit.fractionDigits)
    }
}

/// Short inline length field ("X [ 12.5 ] mm") for two-column rows such as X/Y and W/H.
struct CompactLengthField: View {
    let label: String
    @Binding var millimeters: Double
    var range: ClosedRange<Double>? = nil
    var help: String? = nil
    private var settings: AppSettings { .shared }

    var body: some View {
        let unit = settings.units
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .leading)
            TextField(label, value: Binding(get: { unit.display(millimeters) }, set: { v in
                guard v.isFinite else { return }
                let mm = unit.millimeters(v)
                if let range { millimeters = min(max(mm, range.lowerBound), range.upperBound) } else { millimeters = mm }
            }), format: .number.precision(.fractionLength(0...unit.fractionDigits)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
            Text(unit.symbol).foregroundStyle(.secondary).font(.callout)
        }
        .help(help ?? label)
    }
}

/// Slider with a numeric field, for percentages and other bounded values.
struct SliderField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String? = nil
    var digits: Int = 0

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Slider(value: $value, in: range).labelsHidden().controlSize(.small).frame(minWidth: 90)
                TextField(title, value: Binding(get: { value }, set: { if $0.isFinite { value = min(max($0, range.lowerBound), range.upperBound) } }),
                          format: .number.precision(.fractionLength(0...digits)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                if let unit { Text(unit).foregroundStyle(.secondary).font(.callout).frame(minWidth: 30, alignment: .leading) }
            }
        }
    }
}

/// Coloured dot for a pen.
struct PenSwatch: View {
    let rgb: UInt32
    var size: CGFloat = 10
    var enabled = true

    var body: some View {
        Circle()
            .fill(Color(nsColor: NSColor(rgb: rgb)))
            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
            .frame(width: size, height: size)
            .opacity(enabled ? 1 : 0.35)
            .accessibilityHidden(true)
    }
}

/// Pen picker showing swatches (as images so they render inside menus).
struct PenPicker: View {
    let title: String
    let pens: [PenParameters]
    @Binding var penID: Int

    var body: some View {
        Picker(title, selection: $penID) {
            ForEach(pens) { pen in
                Label {
                    Text(pen.isEnabled ? pen.displayName : L("%@ (off)", pen.displayName))
                } icon: {
                    Image(nsImage: PenColor.swatchImage(pen.colorRGB))
                }
                .tag(pen.id)
            }
        }
    }
}

/// Small icon toggle button used in rows and toolbars of the inspector.
struct IconToggle: View {
    let systemImage: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Image(systemName: systemImage) }
            .toggleStyle(.button)
            .help(help)
            .accessibilityLabel(help)
    }
}
