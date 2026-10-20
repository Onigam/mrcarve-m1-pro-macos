import Foundation
import MRCarveKit

/// Frame / Mark flow of a document window.
extension DocumentModel {
    private var device: DeviceViewModel { DeviceViewModel.shared }

    /// Objects the laser operations apply to: the selection when "selection only" is requested and something is selected.
    private func targetSelection(selectionOnly: Bool) -> Set<UUID>? {
        selectionOnly && !selection.isEmpty ? selection : nil
    }

    // MARK: Framing

    /// F1: starts or stops tracing the design with the red pointer.
    func toggleFraming() {
        if device.isFraming { device.stop(); return }
        guard !device.isMarking else { return }
        let job = JobCompiler.framingJob(project)
        guard !job.isEmpty else {
            alert = AlertInfo(title: L("Nothing to frame"), message: L("Add text, a shape or an image first."))
            return
        }
        device.toggleFraming(job, machine: machine, outlineOnly: AppSettings.shared.frameMode == .boundingBox, owner: id)
    }

    /// Re-traces after edits or a frame-mode change while framing.
    func refreshFraming() {
        let job = JobCompiler.framingJob(project)
        guard !job.isEmpty else { device.stop(); return }
        device.updateFraming(job, outlineOnly: AppSettings.shared.frameMode == .boundingBox)
    }

    // MARK: Marking

    /// F2: validates the job and either shows the safety sheet or starts marking.
    func requestMark(selectionOnly: Bool = false) {
        guard !device.isMarking else { return }
        let probe = JobCompiler.framingJob(project, selection: targetSelection(selectionOnly: selectionOnly))
        guard !probe.isEmpty else {
            alert = AlertInfo(title: L("Nothing to mark"), message: L("Add text, a shape or an image first."))
            return
        }
        let field = machine.field
        if let bounds = JobCompiler.fieldViolation(probe, field: field) {
            alert = AlertInfo(
                title: L("The design is outside the marking field"),
                message: L("The job spans %@ × %@ mm but the field is %@ × %@ mm, centred on the origin. Move or shrink the objects shown in red.",
                           Format.number(bounds.width, digits: 1), Format.number(bounds.height, digits: 1),
                           Format.number(field.width, digits: 0), Format.number(field.height, digits: 0)))
            return
        }
        pendingMarkSelectionOnly = selectionOnly
        if device.safetyAcknowledged || DebugFlags.noPrompts {
            startMark()
        } else {
            isSafetySheetPresented = true
        }
    }

    /// Called by the safety sheet's confirm button (or directly when already acknowledged).
    func startMark() {
        let project = self.project
        let selection = targetSelection(selectionOnly: pendingMarkSelectionOnly)
        let machine = self.machine
        let owner = id
        Task {
            let (job, estimate) = await Task.detached(priority: .userInitiated) {
                let job = JobCompiler.compile(project, options: .init(selection: selection))
                return (job, JobCompiler.estimate(job).duration)
            }.value
            guard !job.isEmpty else {
                alert = AlertInfo(title: L("Nothing to mark"),
                                  message: L("All pens used by these objects are disabled, or the objects produce no geometry."))
                return
            }
            device.mark(job, machine: machine, estimate: estimate, owner: owner)
        }
    }
}
