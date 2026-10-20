import SwiftUI
import MRCarveKit

/// Inspector for a single object: name, placement, kind-specific parameters, fill and pen.
struct ObjectInspector: View {
    @Bindable var document: DocumentModel
    @Bindable var editor: EditorState
    let cache: PreviewCache
    let objectID: UUID

    var body: some View {
        if let object = document.project.object(objectID) {
            Form {
                header(object)
                PlacementSection(document: document, editor: editor, object: object)
                kindSection(object)
                if object.kind.supportsFill {
                    FillSection(document: document, object: object)
                }
                PenEditor(document: document, penID: object.penID, objectID: object.id, showsAssignment: true)
            }
        }
    }

    private func header(_ object: DesignObject) -> some View {
        Section {
            TextField(L("Name"), text: document.binding(object.id, \.name, L("Rename")))
            HStack {
                Label(object.kindTitle, systemImage: object.symbolName)
                    .foregroundStyle(.secondary)
                Spacer()
                IconToggle(systemImage: object.isVisible ? "eye" : "eye.slash",
                           help: object.isVisible ? L("Hide") : L("Show"),
                           isOn: Binding(get: { !object.isVisible }, set: { _ in document.toggleVisibility(object.id) }))
                IconToggle(systemImage: object.isLocked ? "lock.fill" : "lock.open",
                           help: object.isLocked ? L("Unlock") : L("Lock"),
                           isOn: Binding(get: { object.isLocked }, set: { _ in document.toggleLock(object.id) }))
            }
            if document.outsideField.contains(object.id) {
                Label(L("Outside the marking field"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func kindSection(_ object: DesignObject) -> some View {
        switch object.kind {
        case .text:
            TextSection(document: document, editor: editor, objectID: object.id)
        case .rectangle(let radius):
            Section(L("Rectangle")) {
                LengthField(title: L("Corner radius"),
                            millimeters: Binding(get: { radius }, set: { r in
                                document.updateObjects([object.id], L("Change Corner Radius"), coalesce: "radius\(object.id)") {
                                    $0.kind = .rectangle(cornerRadius: max(0, r))
                                }
                            }),
                            range: 0...max(0, min(object.placement.width, object.placement.height) / 2), step: 0.5)
            }
        case .ellipse:
            Section(L("Ellipse")) {
                Button(L("Make Circle")) {
                    document.updateObjects([object.id], L("Make Circle")) {
                        let d = max($0.placement.width, $0.placement.height)
                        $0.placement.width = d
                        $0.placement.height = d
                    }
                }
            }
        case .polygon(let sides, let star):
            Section(object.kindTitle) {
                Stepper(value: Binding(get: { sides }, set: { n in
                    document.updateObjects([object.id], L("Change Sides"), coalesce: "sides\(object.id)") {
                        $0.kind = .polygon(sides: n, starRatio: star)
                    }
                }), in: 3...64) {
                    LabeledContent(star == nil ? L("Sides") : L("Points"), value: "\(sides)")
                }
                Toggle(L("Star"), isOn: Binding(get: { star != nil }, set: { on in
                    document.updateObjects([object.id], L("Change Polygon")) { $0.kind = .polygon(sides: sides, starRatio: on ? 0.5 : nil) }
                }))
                if let star {
                    SliderField(title: L("Inner radius"), value: Binding(get: { star * 100 }, set: { v in
                        document.updateObjects([object.id], L("Change Polygon"), coalesce: "star\(object.id)") {
                            $0.kind = .polygon(sides: sides, starRatio: max(0.05, min(0.95, v / 100)))
                        }
                    }), range: 5...95, unit: "%")
                }
            }
        case .line:
            EmptyView()
        case .vector(let v):
            Section(L("Vector")) {
                LabeledContent(L("Source"), value: v.sourceName)
                LabeledContent(L("Paths"), value: "\(v.polylines.count)")
                LabeledContent(L("Points"), value: "\(v.polylines.reduce(0) { $0 + $1.points.count })")
                Button(L("Reset to Original Size")) {
                    document.updateObjects([object.id], L("Reset Size")) { o in
                        let c = o.placement.center
                        o.fitToContent()
                        o.placement.center = c
                    }
                }
            }
        case .image:
            ImageSection(document: document, cache: cache, object: object)
        }
    }
}

// MARK: - Placement

struct PlacementSection: View {
    let document: DocumentModel
    @Bindable var editor: EditorState
    let object: DesignObject

    var body: some View {
        let id = object.id
        let p = object.placement
        Section(L("Placement")) {
            HStack(spacing: 14) {
                CompactLengthField(label: "X", millimeters: document.binding(id, \.placement.center.x, L("Move")),
                                   help: L("Horizontal position of the centre"))
                CompactLengthField(label: "Y", millimeters: document.binding(id, \.placement.center.y, L("Move")),
                                   help: L("Vertical position of the centre"))
            }
            HStack(spacing: 14) {
                CompactLengthField(label: object.kind.isLine ? L("L") : L("W"), millimeters: sizeBinding(width: true),
                                   range: 0.01...1000, help: object.kind.isLine ? L("Length") : L("Width"))
                if object.kind.isLine {
                    Spacer().frame(maxWidth: .infinity)
                } else {
                    CompactLengthField(label: L("H"), millimeters: sizeBinding(width: false), range: 0.01...1000, help: L("Height"))
                }
            }
            HStack {
                if !object.kind.isLine {
                    IconToggle(systemImage: editor.aspectLocked ? "lock" : "lock.open",
                               help: L("Keep proportions"), isOn: $editor.aspectLocked)
                    Text(L("Keep proportions")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Center")) { document.centerSelectionInField() }
                    .help(L("Center in Field"))
            }
            HStack {
                NumberField(title: L("Rotation"),
                            value: Binding(get: { p.normalizedRotation },
                                           set: { v in document.updateObjects([id], L("Rotate"), coalesce: "rot\(id)") { $0.placement.rotation = v } }),
                            unit: "°", digits: 2)
                Button { rotate(by: -90) } label: { Image(systemName: "rotate.left") }
                    .help(L("Rotate 90° counter-clockwise"))
                    .accessibilityLabel(L("Rotate 90° counter-clockwise"))
                Button { rotate(by: 90) } label: { Image(systemName: "rotate.right") }
                    .help(L("Rotate 90° clockwise"))
                    .accessibilityLabel(L("Rotate 90° clockwise"))
            }
            .buttonStyle(.borderless)
            HStack {
                Text(L("Mirror")).foregroundStyle(.secondary)
                Spacer()
                IconToggle(systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                           help: L("Mirror horizontally"), isOn: document.binding(id, \.placement.mirrorX, L("Mirror")))
                IconToggle(systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                           help: L("Mirror vertically"), isOn: document.binding(id, \.placement.mirrorY, L("Mirror")))
            }
        }
    }

    private func rotate(by degrees: Double) {
        // Clockwise on screen is negative in field coordinates (+Y up).
        document.updateObjects([object.id], L("Rotate")) {
            $0.placement.rotation = Placement(width: 0, height: 0, rotation: $0.placement.rotation - degrees).normalizedRotation
        }
    }

    private func sizeBinding(width: Bool) -> Binding<Double> {
        let id = object.id
        return Binding(
            get: { [document] in
                let p = document.project.object(id)?.placement ?? object.placement
                return width ? p.width : p.height
            },
            set: { [document, editor] value in
                let locked = editor.aspectLocked && !object.kind.isLine
                document.updateObjects([id], L("Resize"), coalesce: "size\(id)") { o in
                    let v = max(0.01, value)
                    let p = o.placement
                    if width {
                        if locked, p.width > 0 { o.placement.height = p.height * v / p.width }
                        o.placement.width = v
                    } else {
                        if locked, p.height > 0 { o.placement.width = p.width * v / p.height }
                        o.placement.height = v
                    }
                }
            })
    }
}

// MARK: - Text

struct TextSection: View {
    let document: DocumentModel
    let editor: EditorState
    let objectID: UUID
    @FocusState private var textFocused: Bool

    var body: some View {
        Section(L("Text")) {
            TextField(L("Text"), text: document.textBinding(objectID, \.string), axis: .vertical)
                .lineLimit(1...6)
                .focused($textFocused)
                .labelsHidden()
                .font(.body)
            Picker(L("Font"), selection: document.textBinding(objectID, \.fontFamily)) {
                ForEach(fontChoices, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            LengthField(title: L("Height"), millimeters: document.textBinding(objectID, \.height), range: 0.1...70, step: 0.5)
            LengthField(title: L("Letter spacing"), millimeters: document.textBinding(objectID, \.letterSpacing), range: -10...50, step: 0.1)
            NumberField(title: L("Line spacing"), value: document.textBinding(objectID, \.lineSpacing), unit: "×",
                        range: 0.5...5, step: 0.1)
            Picker(L("Alignment"), selection: document.textBinding(objectID, \.alignment)) {
                Image(systemName: "text.alignleft").help(L("Left")).tag(MRCarveKit.TextAlignment.left)
                Image(systemName: "text.aligncenter").help(L("Center")).tag(MRCarveKit.TextAlignment.center)
                Image(systemName: "text.alignright").help(L("Right")).tag(MRCarveKit.TextAlignment.right)
            }
            .pickerStyle(.segmented)
        }
        .onAppear(perform: consumeFocusRequest)
        .onChange(of: editor.wantsTextFocus) { consumeFocusRequest() }
    }

    /// Installed families, plus the current one if it is not installed.
    private var fontChoices: [String] {
        var families = FontList.families
        if case .text(let t) = document.project.object(objectID)?.kind, !families.contains(t.fontFamily) {
            families.insert(t.fontFamily, at: 0)
        }
        return families
    }

    private func consumeFocusRequest() {
        guard editor.wantsTextFocus else { return }
        editor.wantsTextFocus = false
        DispatchQueue.main.async { textFocused = true }
    }
}
