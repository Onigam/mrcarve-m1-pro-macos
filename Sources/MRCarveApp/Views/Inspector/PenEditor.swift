import SwiftUI
import AppKit
import MRCarveKit

/// Pen assignment (for an object) and the pen's laser parameters, with presets.
struct PenEditor: View {
    let document: DocumentModel
    let penID: Int
    var objectID: UUID? = nil
    let showsAssignment: Bool
    @State private var showAdvanced = false
    @State private var presetName = ""
    @State private var askingPresetName = false
    private var presets: PresetStore { .shared }

    var body: some View {
        let pen = document.project.pen(penID)
        let machine = document.machine
        Section {
            if showsAssignment, let objectID {
                PenPicker(title: L("Pen"), pens: document.project.pens,
                          penID: document.binding(objectID, \.penID, L("Change Pen")))
            } else {
                TextField(L("Name"), text: Binding(get: { document.project.pen(penID).displayName },
                                                   set: { document.penBinding(penID, \.name, L("Rename Pen")).wrappedValue = $0 }))
            }
            HStack {
                ColorPicker(L("Colour"), selection: colorBinding, supportsOpacity: false)
                Spacer()
                Toggle(L("Enabled"), isOn: document.penBinding(penID, \.isEnabled, L("Enable Pen")))
            }
            let usage = document.project.usageCount(ofPen: penID)
            if usage > 1 {
                Text(L("Shared by %d objects — changes apply to all of them.", usage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !pen.isEnabled {
                Label(L("This pen is disabled and will not be marked."), systemImage: "nosign")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            NumberField(title: L("Speed"), value: document.penBinding(penID, \.markSpeed), unit: "mm/s",
                        range: max(1, machine.lens.minSpeed)...max(2, machine.lens.maxSpeed), digits: 0)
            SliderField(title: L("Power"), value: document.penBinding(penID, \.power), range: 0...100, unit: "%")
            NumberField(title: L("Frequency"), value: document.penBinding(penID, \.frequency), unit: "kHz",
                        range: machine.laser.minFrequency...max(machine.laser.minFrequency + 1, machine.laser.maxFrequency), digits: 1)
            NumberField(title: L("Q pulse width"), value: document.penBinding(penID, \.pulseWidth), unit: "ns",
                        range: machine.laser.minPulseWidth...max(machine.laser.minPulseWidth + 1, machine.laser.maxPulseWidth), digits: 0)
            Stepper(value: document.penBinding(penID, \.loopCount, L("Change Loops")), in: 1...999) {
                LabeledContent(L("Loops"), value: "\(pen.loopCount)")
            }

            DisclosureGroup(L("Advanced"), isExpanded: $showAdvanced) {
                advanced
            }
        } header: {
            HStack {
                Label { Text(pen.displayName).lineLimit(1) } icon: { PenSwatch(rgb: pen.colorRGB, enabled: pen.isEnabled) }
                Spacer()
                presetMenu(pen, source: machine.source)
            }
        }
        .alert(L("Save Preset"), isPresented: $askingPresetName) {
            TextField(L("Preset name"), text: $presetName)
            Button(L("Save")) {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { presets.add(name: name, pen: document.project.pen(penID), source: machine.source) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Saves speed, power, frequency, pulse width, loops and delays of this pen."))
        }
    }

    @ViewBuilder
    private var advanced: some View {
        NumberField(title: L("Jump speed"), value: document.penBinding(penID, \.jumpSpeed), unit: "mm/s", range: 1...20000, digits: 0)
        NumberField(title: L("Laser on delay"), value: document.penBinding(penID, \.laserOnDelay), unit: "µs", range: -1000...10000, digits: 0)
        NumberField(title: L("Laser off delay"), value: document.penBinding(penID, \.laserOffDelay), unit: "µs", range: -1000...10000, digits: 0)
        NumberField(title: L("End mark delay"), value: document.penBinding(penID, \.endMarkDelay), unit: "µs", range: 0...10000, digits: 0)
        NumberField(title: L("Corner delay"), value: document.penBinding(penID, \.cornerDelay), unit: "µs", range: 0...10000, digits: 0)
        NumberField(title: L("Jump position delay"), value: document.penBinding(penID, \.jumpPositionDelay), unit: "µs", range: 0...10000, digits: 0)
        NumberField(title: L("Jump distance delay"), value: document.penBinding(penID, \.jumpDistanceDelay), unit: "µs", range: 0...10000, digits: 0)
        NumberField(title: L("Min jump delay"), value: document.penBinding(penID, \.minJumpDelay), unit: "µs", range: 0...10000, digits: 0)
        NumberField(title: L("Max jump delay"), value: document.penBinding(penID, \.maxJumpDelay), unit: "µs", range: 0...10000, digits: 0)
        NumberField(title: L("Max jump distance"), value: document.penBinding(penID, \.maxJumpDistance), unit: "mm", range: 0...100, digits: 2)
        NumberField(title: L("End compensation"), value: document.penBinding(penID, \.endCompensate), unit: "mm", range: -10...10, digits: 3)
        NumberField(title: L("Acceleration distance"), value: document.penBinding(penID, \.accelerationDistance), unit: "mm", range: -10...10, digits: 3)
        NumberField(title: L("Dot dwell"), value: document.penBinding(penID, \.pointDwell), unit: "ms", range: 0...100, digits: 2)
    }

    private func presetMenu(_ pen: PenParameters, source: LaserSource) -> some View {
        Menu {
            let starting = presets.all.filter { $0.isStartingPoint && ($0.source == nil || $0.source == source) }
            Section(L("Starting points — test on scrap first")) {
                ForEach(starting) { preset in
                    Button(preset.name) { apply(preset) }
                        .help(preset.notes)
                }
            }
            let mine = presets.library.userPresets
            if !mine.isEmpty {
                Section(L("My presets")) {
                    ForEach(mine) { preset in Button(preset.name) { apply(preset) } }
                }
            }
            Divider()
            Button(L("Save as Preset…")) {
                presetName = ""
                askingPresetName = true
            }
        } label: {
            Label(L("Presets"), systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Apply or save laser parameter presets"))
    }

    private func apply(_ preset: PenPreset) {
        document.perform(L("Apply Preset")) { p in p.updatePen(penID) { $0 = preset.applied(to: $0) } }
        // Starting points also suggest a hatch spacing for the selected object.
        if let spacing = preset.suggestedLineSpacing, let objectID, document.project.object(objectID)?.fill != nil {
            document.updateObjects([objectID], L("Apply Preset")) { o in
                guard var fill = o.fill else { return }
                for i in fill.layers.indices { fill.layers[i].spacing = spacing }
                o.fill = fill
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(rgb: document.project.pen(penID).colorRGB)) },
            set: { color in
                let rgb = NSColor(color).rgbValue
                document.perform(L("Change Pen Colour"), coalesce: "color\(penID)") { $0.updatePen(penID) { $0.colorRGB = rgb } }
            })
    }
}
