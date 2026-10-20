import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MRCarveKit

/// Settings window: device, machine profiles, presets, canvas.
struct SettingsView: View {
    var body: some View {
        TabView {
            DeviceSettings()
                .tabItem { Label(L("Device"), systemImage: "cable.connector") }
            MachineSettings()
                .tabItem { Label(L("Machine"), systemImage: "scope") }
            PresetSettings()
                .tabItem { Label(L("Presets"), systemImage: "slider.horizontal.3") }
            CanvasSettings()
                .tabItem { Label(L("Canvas"), systemImage: "square.grid.3x3") }
        }
        .frame(width: 580)
        .frame(minHeight: 420)
    }
}

// MARK: - Device

private struct DeviceSettings: View {
    private var device: DeviceViewModel { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        Form {
            Section {
                Picker(L("Connect to"), selection: Binding(get: { device.mode }, set: { device.setMode($0) })) {
                    Text(L("Simulator (no hardware)")).tag(DeviceMode.simulator)
                    Text(L("MR Carve M1 Pro over USB")).tag(DeviceMode.usb)
                }
                .pickerStyle(.radioGroup)
                Toggle(L("Connect automatically at launch"), isOn: Binding(get: { settings.autoConnect }, set: { settings.autoConnect = $0 }))
            } footer: {
                Text(L("The simulator validates jobs and simulates timing so you can design and rehearse without the machine."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Status")) {
                LabeledContent(L("State"), value: device.statusTitle)
                if let info = device.deviceInfo {
                    LabeledContent(L("FPGA"), value: info.fpgaVersion)
                    if let serial = info.serial { LabeledContent(L("Serial"), value: serial) }
                    if let speed = info.usbSpeed { LabeledContent(L("USB"), value: speed) }
                }
                if let error = device.lastConnectionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button(device.connection.isConnected ? L("Disconnect") : L("Connect")) { device.toggleConnection() }
                        .disabled(device.isBusy || device.connection == .connecting)
                }
            }
            Section(L("Safety")) {
                Toggle(L("Skip the safety reminder until MR Carve quits"),
                       isOn: Binding(get: { device.safetyAcknowledged }, set: { device.safetyAcknowledged = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Machine

private struct MachineSettings: View {
    @State private var selectedName: String = MachineStore.shared.library.defaultProfileName
    @State private var error: String?
    private var store: MachineStore { .shared }

    private var profile: Binding<MachineProfile> {
        Binding(
            get: { store.profile(named: selectedName) },
            set: { new in
                var library = store.library
                if let i = library.profiles.firstIndex(where: { $0.name == selectedName }) {
                    let renamed = new.name != selectedName
                    if renamed && (new.name.isEmpty || library.profiles.contains { $0.name == new.name }) { return }
                    library.profiles[i] = new
                    if renamed {
                        if library.defaultProfileName == selectedName { library.defaultProfileName = new.name }
                        selectedName = new.name
                    }
                    store.library = library
                }
            })
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Profile"), selection: $selectedName) {
                    ForEach(store.profileNames, id: \.self) { name in
                        Text(name == store.library.defaultProfileName ? L("%@ (default)", name) : name).tag(name)
                    }
                }
                HStack {
                    Button(L("Import LmcPar .cfg…")) { importConfig() }
                    Button(L("Duplicate")) { duplicate() }
                    Button(L("Delete"), role: .destructive) { delete() }
                        .disabled(store.library.profiles.count <= 1)
                    Spacer()
                    Button(L("Use for New Projects")) { store.library.defaultProfileName = selectedName }
                        .disabled(store.library.defaultProfileName == selectedName)
                }
            } footer: {
                Text(L("Import the vendor calibration files (LmcPar_Fiber.cfg / LmcPar_Blue.cfg) from the original software's config folder. The imported calibration replaces the profile of the same name; use Duplicate first to keep a copy."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Laser source")) {
                TextField(L("Name"), text: profile.name)
                Picker(L("Source"), selection: profile.source) {
                    ForEach(LaserSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                NumberField(title: L("Min frequency"), value: profile.laser.minFrequency, unit: "kHz", digits: 1)
                NumberField(title: L("Max frequency"), value: profile.laser.maxFrequency, unit: "kHz", digits: 1)
            }

            Section(L("Field lens")) {
                NumberField(title: L("Field size"), value: profile.lens.workSize, unit: "mm", range: 1...300, digits: 1)
                NumberField(title: L("Scale X"), value: profile.lens.scaleX, digits: 4)
                NumberField(title: L("Scale Y"), value: profile.lens.scaleY, digits: 4)
                NumberField(title: L("Barrel X"), value: profile.lens.bucketX, digits: 4)
                NumberField(title: L("Barrel Y"), value: profile.lens.bucketY, digits: 4)
                NumberField(title: L("Trapezoid X"), value: profile.lens.trapezoidX, digits: 4)
                NumberField(title: L("Trapezoid Y"), value: profile.lens.trapezoidY, digits: 4)
                NumberField(title: L("Parallelogram X"), value: profile.lens.parallelogramX, digits: 4)
                NumberField(title: L("Parallelogram Y"), value: profile.lens.parallelogramY, digits: 4)
                NumberField(title: L("Offset X"), value: profile.lens.fieldOffsetX, unit: "mm", digits: 3)
                NumberField(title: L("Offset Y"), value: profile.lens.fieldOffsetY, unit: "mm", digits: 3)
                NumberField(title: L("Rotation"), value: profile.lens.rotateAngle, unit: "°", digits: 3)
                Toggle(L("Invert X"), isOn: profile.lens.invertX)
                Toggle(L("Invert Y"), isOn: profile.lens.invertY)
                Toggle(L("Swap X and Y"), isOn: profile.lens.swapXY)
                NumberField(title: L("Max speed"), value: profile.lens.maxSpeed, unit: "mm/s", digits: 0)
            }

            Section(L("Red light")) {
                NumberField(title: L("Speed"), value: profile.redLight.speed, unit: "mm/s", digits: 0)
                NumberField(title: L("Offset X"), value: profile.redLight.offsetX, unit: "mm", digits: 3)
                NumberField(title: L("Offset Y"), value: profile.redLight.offsetY, unit: "mm", digits: 3)
                NumberField(title: L("Scale X"), value: profile.redLight.scaleX, digits: 4)
                NumberField(title: L("Scale Y"), value: profile.redLight.scaleY, digits: 4)
            }
        }
        .formStyle(.grouped)
        .alert(L("Import failed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("OK")) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onAppear {
            if !store.profileNames.contains(selectedName) { selectedName = store.library.defaultProfileName }
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cfg") ?? .data]
        panel.message = L("Choose LmcPar_Fiber.cfg or LmcPar_Blue.cfg")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            selectedName = try store.importVendorConfig(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func duplicate() {
        var copy = store.profile(named: selectedName)
        copy.name = store.library.uniqueName(copy.name)
        store.library.upsert(copy)
        selectedName = copy.name
    }

    private func delete() {
        var library = store.library
        library.profiles.removeAll { $0.name == selectedName }
        if library.defaultProfileName == selectedName { library.defaultProfileName = library.profiles.first?.name ?? "" }
        store.library = library
        selectedName = library.defaultProfileName
    }
}

// MARK: - Presets

private struct PresetSettings: View {
    private var store: PresetStore { .shared }

    var body: some View {
        Form {
            Section(L("My presets")) {
                if store.library.userPresets.isEmpty {
                    Text(L("Save a pen's parameters as a preset from the inspector (Presets ▸ Save as Preset…)."))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.library.userPresets) { preset in
                    PresetRow(preset: preset) { store.remove(preset.id) }
                }
            }
            Section {
                ForEach(PenPresetLibrary.startingPoints) { preset in
                    PresetRow(preset: preset, onDelete: nil)
                }
            } header: {
                Text(L("Material starting points"))
            } footer: {
                Text(L("Starting points from the M1 manual (fiber) and rough guesses (blue). Always test on scrap material first."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PresetRow: View {
    let preset: PenPreset
    let onDelete: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                Text("\(preset.source?.shortTitle ?? L("Any")) · \(Format.number(preset.parameters.markSpeed, digits: 0)) mm/s · \(Format.number(preset.parameters.power, digits: 0)) % · \(Format.number(preset.parameters.frequency, digits: 0)) kHz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !preset.notes.isEmpty {
                    Text(preset.notes).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let onDelete {
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L("Delete preset"))
                    .accessibilityLabel(L("Delete preset"))
            }
        }
    }
}

// MARK: - Canvas

private struct CanvasSettings: View {
    private var settings: AppSettings { .shared }

    var body: some View {
        Form {
            Section(L("Units")) {
                Picker(L("Lengths"), selection: Binding(get: { settings.units }, set: { settings.units = $0 })) {
                    ForEach(LengthUnit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(L("Grid")) {
                Toggle(L("Show grid (1, 5 and 10 mm)"), isOn: Binding(get: { settings.showGrid }, set: { settings.showGrid = $0 }))
                Toggle(L("Show ruler labels"), isOn: Binding(get: { settings.showRulers }, set: { settings.showRulers = $0 }))
                Toggle(L("Snap to grid"), isOn: Binding(get: { settings.snapToGrid }, set: { settings.snapToGrid = $0 }))
                Picker(L("Snap step"), selection: Binding(get: { settings.snapStep }, set: { settings.snapStep = $0 })) {
                    ForEach([0.1, 0.25, 0.5, 1, 2, 5], id: \.self) { Text("\(Format.number($0)) mm").tag($0) }
                }
                .disabled(!settings.snapToGrid)
            }
            Section(L("Preview")) {
                Toggle(L("Show hatch and dithered raster preview"),
                       isOn: Binding(get: { settings.showFillPreview }, set: { settings.showFillPreview = $0 }))
            }
            Section(L("Keyboard")) {
                LabeledContent(L("Frame with red light"), value: "F1  ·  ⌘L")
                LabeledContent(L("Mark"), value: "F2  ·  ⌘↩")
                LabeledContent(L("Stop"), value: "Esc  ·  ⌘.")
                LabeledContent(L("Tools"), value: "V  T  R  E  P  L")
                LabeledContent(L("Nudge"), value: L("Arrows 0.1 mm · ⇧ 1 mm"))
                LabeledContent(L("Pan / zoom"), value: L("Space-drag · pinch or ⌘-scroll"))
            }
        }
        .formStyle(.grouped)
    }
}
