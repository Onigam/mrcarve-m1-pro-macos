import SwiftUI
import MRCarveKit

/// Safety confirmation shown before marking until acknowledged for the session.
struct SafetySheet: View {
    let document: DocumentModel
    @Environment(\.dismiss) private var dismiss
    @State private var dontShowAgain = false
    private var device: DeviceViewModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Ready to fire the laser?")).font(.title2.weight(.semibold))
                    Text(L("%@ · %@", document.machine.name, document.machine.source.title))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                item("eyeglasses", L("Wear laser safety goggles"),
                     L("Rated for the wavelength of the active laser source. Make sure everyone nearby does too."))
                item("shield.lefthalf.filled", L("Close the enclosure"),
                     L("Keep hands and reflective objects out of the field while marking."))
                item("scope", L("Check the focus"),
                     L("Set the working distance for this workpiece and frame it with the red light first."))
                item("flame", L("Stay with the machine"),
                     L("Never leave a running job unattended; keep ventilation on."))
            }
            Toggle(L("Don't show again until MR Carve quits"), isOn: $dontShowAgain)
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    if dontShowAgain { device.safetyAcknowledged = true }
                    dismiss()
                    document.startMark()
                } label: {
                    Label(L("Start Marking"), systemImage: "bolt.fill")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Progress while marking, with a big Stop button; shows the outcome afterwards.
struct MarkProgressSheet: View {
    let document: DocumentModel
    @Environment(\.dismiss) private var dismiss
    private var device: DeviceViewModel { .shared }

    var body: some View {
        VStack(spacing: 20) {
            if device.isMarking {
                running
            } else {
                finished
            }
        }
        .padding(28)
        .frame(width: 400)
        .interactiveDismissDisabled(device.isMarking)
    }

    private var running: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange).symbolEffect(.pulse)
                Text(L("Marking…")).font(.title2.weight(.semibold))
                Spacer()
                Text(Format.percent(device.progress)).font(.title2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: device.progress)
                .progressViewStyle(.linear)
                .tint(.orange)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let elapsed = Date().timeIntervalSince(device.markStartedAt ?? Date())
                let remaining = device.progress > 0.02
                    ? elapsed * (1 - device.progress) / device.progress
                    : max(0, device.markEstimate - elapsed)
                HStack {
                    Text(L("Elapsed %@", Format.duration(elapsed)))
                    Spacer()
                    Text(L("Remaining ≈ %@", Format.duration(remaining)))
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Button(role: .destructive) { device.stop() } label: {
                Label(L("Stop"), systemImage: "stop.fill")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.extraLarge)
            .keyboardShortcut(.cancelAction)
            Text(L("Esc or ⌘. stops the laser immediately."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var finished: some View {
        switch device.outcome {
        case .completed(let seconds):
            outcomeView(symbol: "checkmark.circle.fill", color: .green, title: L("Done"),
                        detail: L("Marked in %@.", Format.duration(seconds)))
            HStack {
                Button(L("Mark Again")) { device.markAgain(machine: document.machine, owner: document.id) }
                    .disabled(!device.canRepeatLastJob)
                Spacer()
                Button(L("Done")) { close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        case .stopped:
            outcomeView(symbol: "stop.circle.fill", color: .orange, title: L("Stopped"),
                        detail: L("Marking was stopped before the end of the job."))
            HStack {
                Spacer()
                Button(L("OK")) { close() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            outcomeView(symbol: "xmark.octagon.fill", color: .red, title: L("Marking failed"), detail: message)
            HStack {
                Spacer()
                Button(L("OK")) { close() }.keyboardShortcut(.defaultAction)
            }
        case nil:
            ProgressView()
        }
    }

    private func outcomeView(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func close() {
        device.outcome = nil
        dismiss()
    }
}
