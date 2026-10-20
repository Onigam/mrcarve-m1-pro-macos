import SwiftUI
import MRCarveKit

/// Right column. Shows the selected object, several objects, a pen, or the project.
struct InspectorView: View {
    @Bindable var document: DocumentModel
    let editor: EditorState
    let cache: PreviewCache

    var body: some View {
        Group {
            if let penID = document.inspectedPenID, document.selection.isEmpty {
                Form { PenEditor(document: document, penID: penID, showsAssignment: false) }
            } else if let object = document.singleSelection {
                ObjectInspector(document: document, editor: editor, cache: cache, objectID: object.id)
                    .id(object.id)
            } else if document.selection.count > 1 {
                MultiSelectionInspector(document: document)
            } else {
                ProjectInspector(document: document, editor: editor)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Project

/// Shown when nothing is selected: quick start, job settings and estimate.
struct ProjectInspector: View {
    @Bindable var document: DocumentModel
    let editor: EditorState
    private var machines: MachineStore { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        Form {
            if document.project.objects.isEmpty {
                Section(L("Get started")) {
                    StepRow(number: 1, symbol: "textformat", title: L("Add text or an image"),
                            detail: L("Use the Text tool (T), or drop an image or SVG on the field."))
                    StepRow(number: 2, symbol: "viewfinder", title: L("Frame with the red light"),
                            detail: L("Press F1 to trace the design on the workpiece; adjust and press again to stop."))
                    StepRow(number: 3, symbol: "bolt.fill", title: L("Mark"),
                            detail: L("Press F2 to engrave. Stop with Esc or ⌘. at any time."))
                    HStack {
                        Button(L("Add Text")) { addText() }
                        Button(L("Import…")) { document.importWithPanel() }
                    }
                }
            }

            Section(L("Job")) {
                Stepper(value: document.projectBinding(\.repeatCount, L("Change Repeat Count")), in: 1...999) {
                    LabeledContent(L("Repeat"), value: L("%d×", document.project.repeatCount))
                }
                Picker(L("Machine profile"), selection: document.projectBinding(\.machineProfileName, L("Change Machine Profile"))) {
                    ForEach(machines.profileNames, id: \.self) { Text($0).tag($0) }
                    if !machines.profileNames.contains(document.project.machineProfileName) {
                        Text(L("%@ (missing)", document.project.machineProfileName)).tag(document.project.machineProfileName)
                    }
                }
                let field = document.machine.field
                LabeledContent(L("Marking field"), value: "\(Format.number(field.width, digits: 0)) × \(Format.number(field.height, digits: 0)) mm")
            }

            Section(L("Estimate")) {
                if let e = document.estimate, e.polylineCount > 0 {
                    LabeledContent(L("Mark time"), value: "≈ " + Format.duration(e.duration))
                    LabeledContent(L("Laser-on path"), value: settings.units.format(e.markLength, digits: 0))
                    LabeledContent(L("Paths"), value: "\(e.polylineCount)")
                } else {
                    Text(L("Nothing to mark yet.")).foregroundStyle(.secondary)
                }
                if !document.outsideField.isEmpty {
                    Label(L(count: document.outsideField.count, one: "%d object is outside the marking field", other: "%d objects are outside the marking field"),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func addText() {
        var object = DesignObject.text(L("Text"), content: TextContent(string: "", fontFamily: FontList.defaultFamily, height: 5))
        object.name = L("Text")
        document.add([object], actionName: L("Add Text"))
        editor.wantsTextFocus = true
    }
}

private struct StepRow: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                Image(systemName: symbol).foregroundStyle(Color.accentColor).font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number). \(title)").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Multiple selection

struct MultiSelectionInspector: View {
    @Bindable var document: DocumentModel

    var body: some View {
        let objects = document.selectedObjects
        Form {
            Section {
                LabeledContent(L("Selection"), value: L(count: objects.count, one: "%d object", other: "%d objects"))
                if let b = objects.map({ $0.fieldBounds() }).reduce(nil, { $0?.union($1) ?? $1 }) {
                    LabeledContent(L("Size"), value: AppSettings.shared.units.format(b.width) + " × " + AppSettings.shared.units.format(b.height))
                }
            }
            Section(L("Arrange")) {
                HStack {
                    alignButton("align.horizontal.left", L("Align Left"), .left)
                    alignButton("align.horizontal.center", L("Align Centers Horizontally"), .hCenter)
                    alignButton("align.horizontal.right", L("Align Right"), .right)
                    Divider().frame(height: 16)
                    alignButton("align.vertical.top", L("Align Top"), .top)
                    alignButton("align.vertical.center", L("Align Centers Vertically"), .vCenter)
                    alignButton("align.vertical.bottom", L("Align Bottom"), .bottom)
                }
                .buttonStyle(.borderless)
                Button(L("Center in Field")) { document.centerSelectionInField() }
            }
            Section(L("Pen")) {
                let common = Set(objects.map(\.penID)).count == 1 ? objects.first?.penID : nil
                Menu {
                    ForEach(document.project.pens) { pen in
                        Button { document.setPen(pen.id) } label: {
                            Label { Text(pen.displayName) } icon: { Image(nsImage: PenColor.swatchImage(pen.colorRGB)) }
                        }
                    }
                } label: {
                    Text(common.map { document.project.pen($0).displayName } ?? L("Mixed"))
                }
            }
            Section(L("Fill")) {
                let fillable = objects.filter(\.kind.supportsFill)
                HStack {
                    Button(L("Fill All")) {
                        document.updateObjects(fillable.map(\.id), L("Add Fill")) { if $0.fill == nil { $0.fill = FillSettings() } }
                    }
                    Button(L("Remove Fill")) {
                        document.updateObjects(fillable.map(\.id), L("Remove Fill")) { $0.fill = nil }
                    }
                }
                .disabled(fillable.isEmpty)
            }
        }
    }

    private func alignButton(_ symbol: String, _ help: String, _ alignment: DocumentModel.Alignment) -> some View {
        Button { document.alignSelection(alignment) } label: { Image(systemName: symbol) }
            .help(help)
            .accessibilityLabel(help)
    }
}
