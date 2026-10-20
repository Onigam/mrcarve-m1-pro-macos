import SwiftUI
import MRCarveKit

/// Window toolbar: tools, import, device status, Frame / Mark / Stop, inspector toggle.
struct MainToolbar: ToolbarContent {
    @Bindable var document: DocumentModel
    @Bindable var editor: EditorState
    private var device: DeviceViewModel { .shared }
    private var settings: AppSettings { .shared }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker(L("Tool"), selection: $editor.tool) {
                ForEach(CanvasTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbolName)
                        .help("\(tool.title) (\(String(tool.key).uppercased()))")
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help(L("Drawing tools"))
        }
        ToolbarItem(placement: .navigation) {
            Button { document.importWithPanel() } label: {
                Label(L("Import"), systemImage: "square.and.arrow.down")
            }
            .help(L("Import vector files or images (⌘I) — or drop them on the field"))
        }

        ToolbarItem(placement: .principal) {
            DeviceStatusPill(document: document)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker(L("Frame"), selection: Binding(get: { settings.frameMode }, set: { mode in
                    settings.frameMode = mode
                    if device.isFraming { document.refreshFraming() }
                })) {
                    ForEach(FrameMode.allCases) { Label($0.title, systemImage: $0.symbolName).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(device.isFraming ? L("Stop Framing") : L("Frame"),
                      systemImage: device.isFraming ? "light.max" : "viewfinder")
            } primaryAction: {
                document.toggleFraming()
            }
            .foregroundStyle(device.isFraming ? Color.red : Color.primary)
            .help(L("Trace the design with the red pointer (F1 or ⌘L). Click again to stop."))
            .disabled(device.isMarking)

            Button { document.requestMark() } label: {
                ProminentLabel(title: L("Mark"), systemImage: "bolt.fill", color: .orange, enabled: !device.isMarking)
            }
            .buttonStyle(.plain)
            .help(L("Start marking (F2 or ⌘↩)"))
            .accessibilityLabel(L("Mark"))
            .disabled(device.isMarking)

            Button { device.stop() } label: {
                if device.isBusy {
                    ProminentLabel(title: L("Stop"), systemImage: "stop.fill", color: .red, enabled: true)
                } else {
                    Label(L("Stop"), systemImage: "stop.fill")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Stop the laser immediately (Esc or ⌘.)"))
            .accessibilityLabel(L("Stop"))
            .disabled(!device.isBusy)
        }

        ToolbarItem(placement: .primaryAction) {
            Button { editor.isInspectorPresented.toggle() } label: {
                Label(L("Inspector"), systemImage: "sidebar.trailing")
            }
            .help(L("Show or hide the inspector (⌥⌘I)"))
        }
    }
}

/// Filled capsule used for the primary laser actions in the toolbar.
private struct ProminentLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    let enabled: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.gradient))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Toolbar pill showing the device state; click for connection details.
struct DeviceStatusPill: View {
    let document: DocumentModel
    @State private var showDetails = false
    private var device: DeviceViewModel { .shared }

    private var color: Color {
        switch device.activity {
        case .framing: return .red
        case .marking: return .orange
        case .idle: break
        }
        switch device.connection {
        case .connected: return device.mode == .simulator ? .blue : .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    var body: some View {
        Button { showDetails.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.7), radius: device.isBusy ? 3 : 0)
                Text(device.statusTitle)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                if device.mode == .simulator {
                    Image(systemName: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Device status — click for details"))
        .accessibilityLabel(L("Device status: %@", device.statusTitle))
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            DeviceDetails(document: document)
        }
    }
}

/// Popover with connection mode, device information and connect/disconnect.
private struct DeviceDetails: View {
    let document: DocumentModel
    private var device: DeviceViewModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Device"), selection: Binding(get: { device.mode }, set: { device.setMode($0) })) {
                ForEach(DeviceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text(L("Status")).foregroundStyle(.secondary)
                    Text(device.statusTitle)
                }
                if let info = device.deviceInfo {
                    GridRow { Text(L("FPGA")).foregroundStyle(.secondary); Text(info.fpgaVersion) }
                    if let serial = info.serial { GridRow { Text(L("Serial")).foregroundStyle(.secondary); Text(serial) } }
                    if let speed = info.usbSpeed { GridRow { Text(L("USB")).foregroundStyle(.secondary); Text(speed) } }
                }
                GridRow {
                    Text(L("Profile")).foregroundStyle(.secondary)
                    Text(document.machine.name)
                }
            }
            .font(.callout)

            if let error = device.lastConnectionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(device.connection.isConnected ? L("Disconnect") : L("Connect")) {
                    device.toggleConnection(owner: document.id)
                }
                .disabled(device.connection == .connecting || device.isBusy)
                Spacer()
                SettingsLink { Text(L("Settings…")) }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Bottom bar: cursor position, zoom, object count, estimate.
struct StatusBar: View {
    let document: DocumentModel
    let editor: EditorState
    private var settings: AppSettings { .shared }

    var body: some View {
        HStack(spacing: 16) {
            let units = settings.units
            Group {
                if let c = editor.cursor {
                    Text(verbatim: "X \(Format.number(units.display(c.x), digits: units.fractionDigits - 1))  Y \(Format.number(units.display(c.y), digits: units.fractionDigits - 1)) \(units.symbol)")
                } else {
                    Text(verbatim: "X –  Y –")
                }
            }
            .frame(minWidth: 150, alignment: .leading)
            Text(Format.percent(editor.zoom))
                .help(L("Zoom (100 % = actual size)"))
            Text(document.selection.isEmpty
                 ? L(count: document.project.objects.count, one: "%d object", other: "%d objects")
                 : L("%d of %d selected", document.selection.count, document.project.objects.count))
            Spacer()
            if !document.outsideField.isEmpty {
                Label(L("%d outside field", document.outsideField.count), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let e = document.estimate, e.polylineCount > 0 {
                Label("≈ " + Format.duration(e.duration), systemImage: "timer")
                    .help(L("Estimated mark time"))
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
