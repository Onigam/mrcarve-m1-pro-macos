import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MRCarveKit

/// Hatch fill: on/off, outline options and up to four hatch layers.
struct FillSection: View {
    let document: DocumentModel
    let object: DesignObject

    var body: some View {
        Section {
            Toggle(L("Fill"), isOn: Binding(get: { object.fill != nil }, set: { on in
                document.updateObjects([object.id], on ? L("Add Fill") : L("Remove Fill")) { $0.fill = on ? FillSettings() : nil }
            }))
            if let settings = object.fill {
                Toggle(L("Mark outline"), isOn: setting(\.markOutline))
                Toggle(L("Outline first"), isOn: setting(\.outlineFirst))
                    .disabled(!settings.markOutline)
            }
        } header: {
            HStack {
                Text(L("Fill"))
                Spacer()
                Button(L("Load fillPara.cfg…")) { loadVendorFill() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(L("Use the hatch settings of the original software (config/fillPara.cfg)"))
            }
        } footer: {
            if object.fill == nil {
                Text(L("Without fill only the outline is marked.")).font(.caption).foregroundStyle(.secondary)
            }
        }

        if let settings = object.fill {
            ForEach(Array(settings.layers.prefix(FillSettings.maxLayers).enumerated()), id: \.offset) { index, _ in
                HatchLayerSection(document: document, objectID: object.id, index: index,
                                  canRemove: settings.layers.count > 1)
            }
            if settings.layers.count < FillSettings.maxLayers {
                Section {
                    Button {
                        document.updateObjects([object.id], L("Add Hatch Layer")) { o in
                            var layer = o.fill?.layers.last ?? HatchLayer()
                            layer.angle = (layer.angle + 90).truncatingRemainder(dividingBy: 180)
                            o.fill?.layers.append(layer)
                        }
                    } label: {
                        Label(L("Add Hatch Layer"), systemImage: "plus")
                    }
                }
            }
        }
    }

    private func loadVendorFill() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cfg") ?? .data]
        panel.message = L("Choose fillPara.cfg from the original software's config folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let settings = try VendorConfig.fillSettings(fromFillPara: url)
            document.updateObjects([object.id], L("Load Fill Settings")) { $0.fill = settings }
        } catch {
            document.alert = AlertInfo(title: L("Could not read the fill settings"), message: error.localizedDescription)
        }
    }

    private func setting(_ keyPath: WritableKeyPath<FillSettings, Bool>) -> Binding<Bool> {
        Binding(get: { object.fill?[keyPath: keyPath] ?? false },
                set: { v in document.updateObjects([object.id], L("Change Fill")) { $0.fill?[keyPath: keyPath] = v } })
    }
}

/// Parameters of one hatch layer.
private struct HatchLayerSection: View {
    let document: DocumentModel
    let objectID: UUID
    let index: Int
    let canRemove: Bool
    @State private var showMore = false

    private var layer: HatchLayer? {
        guard let fill = document.project.object(objectID)?.fill, fill.layers.indices.contains(index) else { return nil }
        return fill.layers[index]
    }

    private func value<T>(_ keyPath: WritableKeyPath<HatchLayer, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { layer?[keyPath: keyPath] ?? fallback },
            set: { v in
                document.updateObjects([objectID], L("Change Hatch"), coalesce: "hatch\(objectID)\(index)\(keyPath)") { o in
                    guard var fill = o.fill, fill.layers.indices.contains(index) else { return }
                    fill.layers[index][keyPath: keyPath] = v
                    o.fill = fill
                }
            })
    }

    var body: some View {
        if let layer {
            Section {
                Toggle(L("Enabled"), isOn: value(\.isEnabled, true))
                Picker(L("Pattern"), selection: value(\.pattern, .lines)) {
                    Text(L("Lines")).tag(HatchPattern.lines)
                    Text(L("Concentric")).tag(HatchPattern.concentric)
                }
                .pickerStyle(.segmented)
                if layer.pattern == .lines {
                    NumberField(title: L("Angle"), value: value(\.angle, 0), unit: "°", range: -360...360, step: 15)
                }
                LengthField(title: L("Line spacing"), millimeters: value(\.spacing, 0.05), range: 0.001...10, step: 0.01)
                if layer.pattern == .lines {
                    Toggle(L("Cross-hatch"), isOn: value(\.crossHatch, false))
                    Toggle(L("Bidirectional"), isOn: value(\.bidirectional, true))
                }
                Picker(L("Pen"), selection: Binding(get: { layer.penID ?? -1 },
                                                    set: { v in value(\.penID, nil).wrappedValue = v < 0 ? nil : v })) {
                    Text(L("Same as object")).tag(-1)
                    Divider()
                    ForEach(document.project.pens) { pen in
                        Label { Text(pen.displayName) } icon: { Image(nsImage: PenColor.swatchImage(pen.colorRGB)) }
                            .tag(pen.id)
                    }
                }
                DisclosureGroup(L("More"), isExpanded: $showMore) {
                    LengthField(title: L("Border offset"), millimeters: value(\.borderOffset, 0), range: -10...10, step: 0.01)
                    LengthField(title: L("Start offset"), millimeters: value(\.startOffset, 0), range: -10...10, step: 0.01)
                    LengthField(title: L("End offset"), millimeters: value(\.endOffset, 0), range: -10...10, step: 0.01)
                    Toggle(L("Evenly distribute lines"), isOn: value(\.evenDistribution, false))
                        .help(L("Adjusts the spacing slightly so the first and last lines sit half a spacing from the outline."))
                    NumberField(title: L("Auto-rotate per pass"), value: value(\.autoRotateAngle, 0), unit: "°",
                                range: -180...180, step: 5,
                                help: L("Adds this angle on every loop of the pen (needs loops > 1)."))
                }
            } header: {
                HStack {
                    Text(L("Hatch %d", index + 1))
                    Spacer()
                    if canRemove {
                        Button {
                            document.updateObjects([objectID], L("Remove Hatch Layer")) { o in
                                if o.fill?.layers.indices.contains(index) == true { o.fill?.layers.remove(at: index) }
                            }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(L("Remove Hatch Layer"))
                            .accessibilityLabel(L("Remove Hatch Layer"))
                    }
                }
            }
        }
    }
}
