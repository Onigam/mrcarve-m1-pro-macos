import SwiftUI
import MRCarveKit

/// Selection in the sidebar: objects or one pen.
enum SidebarItem: Hashable {
    case object(UUID)
    case pen(Int)
}

/// Left column: objects in mark order, then the pen table.
struct Sidebar: View {
    @Bindable var document: DocumentModel
    @State private var renaming: DesignObject?
    @State private var newName = ""

    private var selection: Binding<Set<SidebarItem>> {
        Binding(
            get: {
                var s = Set(document.selection.map(SidebarItem.object))
                if let pen = document.inspectedPenID { s.insert(.pen(pen)) }
                return s
            },
            set: { items in
                let objects = Set(items.compactMap { if case .object(let id) = $0 { id } else { nil } })
                let pens = items.compactMap { if case .pen(let id) = $0 { id } else { nil } }
                if !objects.isEmpty || pens.isEmpty {
                    document.select(objects)
                    document.inspectedPenID = nil
                } else {
                    document.selection = []
                    // Prefer the newly clicked pen when several are in the set.
                    document.inspectedPenID = pens.first { $0 != document.inspectedPenID } ?? pens.first
                }
            })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                if document.project.objects.isEmpty {
                    Text(L("No objects yet. Use the toolbar to add text or shapes, or drop an image on the field."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                }
                ForEach(Array(document.project.objects.enumerated()), id: \.element.id) { index, object in
                    ObjectRow(document: document, object: object, index: index + 1)
                        .tag(SidebarItem.object(object.id))
                }
                .onMove { document.moveObjects(from: $0, to: $1) }
            } header: {
                Text(L("Objects · mark order"))
            }

            Section(L("Pens")) {
                ForEach(document.project.pens) { pen in
                    PenRow(pen: pen, usage: document.project.usageCount(ofPen: pen.id))
                        .tag(SidebarItem.pen(pen.id))
                        .contextMenu { penMenu(pen) }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            objectMenu(items)
        }
        .onDeleteCommand { document.deleteSelection() }
        .alert(L("Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name"), text: $newName)
            Button(L("Rename")) {
                if let id = renaming?.id {
                    let name = newName
                    document.updateObjects([id], L("Rename")) { $0.name = name }
                }
                renaming = nil
            }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func objectMenu(_ items: Set<SidebarItem>) -> some View {
        let ids = Set(items.compactMap { if case .object(let id) = $0 { id } else { nil } })
        if !ids.isEmpty {
            let objects = document.project.objects.filter { ids.contains($0.id) }
            if objects.count == 1, let o = objects.first {
                Button(L("Rename…")) { newName = o.name; renaming = o }
            }
            Button(L("Duplicate")) { document.select(ids); document.duplicateSelection() }
            Button(L("Center in Field")) { document.select(ids); document.centerSelectionInField() }
            Divider()
            Menu(L("Pen")) {
                ForEach(document.project.pens) { pen in
                    Button { document.setPen(pen.id, for: ids) } label: {
                        Label { Text(pen.displayName) } icon: { Image(nsImage: PenColor.swatchImage(pen.colorRGB)) }
                    }
                }
            }
            Menu(L("Mark Order")) {
                Button(L("Mark First")) { document.select(ids); document.reorderSelection(.first) }
                Button(L("Mark Earlier")) { document.select(ids); document.reorderSelection(.earlier) }
                Button(L("Mark Later")) { document.select(ids); document.reorderSelection(.later) }
                Button(L("Mark Last")) { document.select(ids); document.reorderSelection(.last) }
            }
            Divider()
            let hidden = objects.allSatisfy { !$0.isVisible }
            Button(hidden ? L("Show") : L("Hide")) {
                document.updateObjects(ids, hidden ? L("Show") : L("Hide")) { $0.isVisible = hidden }
            }
            let locked = objects.allSatisfy(\.isLocked)
            Button(locked ? L("Unlock") : L("Lock")) {
                document.updateObjects(ids, locked ? L("Unlock") : L("Lock")) { $0.isLocked = !locked }
            }
            Divider()
            Button(L("Delete"), role: .destructive) { document.select(ids); document.deleteSelection() }
        }
    }

    @ViewBuilder
    private func penMenu(_ pen: PenParameters) -> some View {
        Button(L("Assign to Selected Objects")) { document.setPen(pen.id) }
            .disabled(document.selection.isEmpty)
        Button(pen.isEnabled ? L("Disable Pen") : L("Enable Pen")) {
            document.perform(pen.isEnabled ? L("Disable Pen") : L("Enable Pen")) { $0.updatePen(pen.id) { $0.isEnabled.toggle() } }
        }
        Divider()
        Button(L("Reset to Defaults")) {
            document.perform(L("Reset Pen")) { p in
                p.updatePen(pen.id) { current in
                    var fresh = PenParameters(id: pen.id, name: current.name, colorRGB: current.colorRGB)
                    fresh.isEnabled = current.isEnabled
                    current = fresh
                }
            }
        }
    }
}

/// One object row: pen swatch, kind icon, name, visibility and lock toggles.
private struct ObjectRow: View {
    let document: DocumentModel
    let object: DesignObject
    let index: Int
    @State private var hovering = false

    var body: some View {
        let pen = document.project.pen(object.penID)
        HStack(spacing: 6) {
            Text("\(index)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 14, alignment: .trailing)
            PenSwatch(rgb: pen.colorRGB, enabled: pen.isEnabled)
            Image(systemName: object.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(object.name.isEmpty ? object.kindTitle : object.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(object.isVisible ? .primary : .secondary)
            if document.outsideField.contains(object.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(L("Outside the marking field"))
            }
            Spacer(minLength: 4)
            if hovering || object.isLocked {
                rowButton(object.isLocked ? "lock.fill" : "lock.open", help: object.isLocked ? L("Unlock") : L("Lock")) {
                    document.toggleLock(object.id)
                }
            }
            if hovering || !object.isVisible {
                rowButton(object.isVisible ? "eye" : "eye.slash", help: object.isVisible ? L("Hide") : L("Show")) {
                    document.toggleVisibility(object.id)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(object.kindTitle) \(object.name)")
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One pen row: swatch, name, short parameter summary and usage count.
private struct PenRow: View {
    let pen: PenParameters
    let usage: Int

    var body: some View {
        HStack(spacing: 6) {
            PenSwatch(rgb: pen.colorRGB, enabled: pen.isEnabled)
            Text(pen.displayName).lineLimit(1)
                .foregroundStyle(pen.isEnabled ? .primary : .secondary)
            Spacer(minLength: 4)
            Text(pen.isEnabled
                 ? "\(Format.number(pen.markSpeed, digits: 0)) mm/s · \(Format.number(pen.power, digits: 0)) %"
                 : L("Off"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .badge(usage)
        .help(L(count: usage, one: "%d object uses this pen", other: "%d objects use this pen"))
    }
}
