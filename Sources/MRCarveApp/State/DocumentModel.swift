import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers
import MRCarveKit

/// Alert shown in a document window.
struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// State of one document window: the project, the selection, undo, file I/O and editing operations.
///
/// Every edit goes through `perform(_:coalesce:_:)`, which snapshots the project for undo. Continuous edits
/// (slider drags, typing in a field) pass a `coalesce` key so that a burst of changes becomes one undo step;
/// canvas drags use `beginInteraction()` / `endInteraction(_:)`.
@MainActor @Observable
final class DocumentModel {
    let id = UUID()
    var project: Project
    var selection: Set<UUID> = []
    /// Pen shown in the inspector when a pen row is selected in the sidebar.
    var inspectedPenID: Int?
    private(set) var fileURL: URL?
    private(set) var isDirty = false
    var alert: AlertInfo?
    var isSafetySheetPresented = false
    @ObservationIgnored var pendingMarkSelectionOnly = false

    /// Result of the background analysis (time estimate, field check).
    private(set) var estimate: JobEstimate?
    private(set) var outsideField: Set<UUID> = []

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var lastCoalesceKey: String?
    @ObservationIgnored private var lastCoalesceTime = Date.distantPast
    @ObservationIgnored private var interactionSnapshot: Snapshot?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var analysisRunning = false
    @ObservationIgnored private var analysisPending = false
    @ObservationIgnored private var framingTask: Task<Void, Never>?

    private struct Snapshot {
        var project: Project
        var selection: Set<UUID>
    }

    init(project: Project? = nil) {
        self.project = project ?? Project(machineProfileName: MachineStore.shared.library.defaultProfileName)
        scheduleAnalysis()
    }

    // MARK: Derived state

    var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? L("Untitled")
    }

    /// Untitled, unchanged and empty: safe to replace when opening a file.
    var isPristine: Bool { fileURL == nil && !isDirty && project.objects.isEmpty }

    var selectedObjects: [DesignObject] { project.objects.filter { selection.contains($0.id) } }

    var singleSelection: DesignObject? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return project.object(id)
    }

    var machine: MachineProfile { MachineStore.shared.profile(named: project.machineProfileName) }

    // MARK: Undoable edits

    /// Applies `change` to the project and registers an undo step named `actionName`.
    func perform(_ actionName: String, coalesce key: String? = nil, _ change: (inout Project) -> Void) {
        let before = Snapshot(project: project, selection: selection)
        var updated = project
        change(&updated)
        guard updated != project else { return }
        project = updated
        changed()
        if interactionSnapshot != nil { return }
        let now = Date()
        if let key, key == lastCoalesceKey, now.timeIntervalSince(lastCoalesceTime) < 1.5 {
            lastCoalesceTime = now
            return
        }
        registerUndo(before, actionName)
        lastCoalesceKey = key
        lastCoalesceTime = now
    }

    /// Mutates the objects with `ids` (one undo step).
    func updateObjects(_ ids: some Sequence<UUID>, _ actionName: String, coalesce key: String? = nil,
                       _ body: (inout DesignObject) -> Void) {
        let set = Set(ids)
        perform(actionName, coalesce: key) { p in
            for i in p.objects.indices where set.contains(p.objects[i].id) { body(&p.objects[i]) }
        }
    }

    /// Starts a continuous canvas interaction; changes until `endInteraction` form a single undo step.
    func beginInteraction() {
        interactionSnapshot = Snapshot(project: project, selection: selection)
    }

    /// Ends the interaction started with `beginInteraction`, registering one undo step if anything changed.
    func endInteraction(_ actionName: String) {
        guard let snapshot = interactionSnapshot else { return }
        interactionSnapshot = nil
        if snapshot.project != project {
            registerUndo(snapshot, actionName)
            lastCoalesceKey = nil
        }
    }

    /// Reverts the current interaction (Esc during a drag).
    func cancelInteraction() {
        guard let snapshot = interactionSnapshot else { return }
        interactionSnapshot = nil
        project = snapshot.project
        selection = snapshot.selection
        changed()
    }

    var isInteracting: Bool { interactionSnapshot != nil }

    /// Directly sets placements during an interaction (no undo registration of its own).
    func setPlacements(_ placements: [UUID: Placement]) {
        var p = project
        for i in p.objects.indices {
            if let placement = placements[p.objects[i].id] { p.objects[i].placement = placement }
        }
        guard p != project else { return }
        project = p
        changed()
    }

    private func registerUndo(_ snapshot: Snapshot, _ actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(snapshot, actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ snapshot: Snapshot, _ actionName: String) {
        let current = Snapshot(project: project, selection: selection)
        project = snapshot.project
        selection = snapshot.selection.filter { id in project.objects.contains { $0.id == id } }
        lastCoalesceKey = nil
        registerUndo(current, actionName)
        changed()
    }

    private func changed() {
        isDirty = true
        scheduleAnalysis()
        if DeviceViewModel.shared.isFraming, DeviceViewModel.shared.ownerID == id { scheduleFramingRefresh() }
    }

    // MARK: Selection

    func select(_ ids: Set<UUID>) {
        selection = ids
        if !ids.isEmpty { inspectedPenID = nil }
    }

    func selectAll() {
        select(Set(project.objects.filter { $0.isVisible && !$0.isLocked }.map(\.id)))
    }

    func clearSelection() { selection = [] }

    // MARK: Object operations

    /// Adds objects at the end of the mark order and selects them.
    func add(_ objects: [DesignObject], actionName: String? = nil) {
        guard !objects.isEmpty else { return }
        let before = Snapshot(project: project, selection: selection)
        project.objects.append(contentsOf: objects)
        selection = Set(objects.map(\.id))
        inspectedPenID = nil
        registerUndo(before, actionName ?? (objects.count == 1 ? L("Add %@", objects[0].kindTitle) : L("Add Objects")))
        lastCoalesceKey = nil
        changed()
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform(L("Delete")) { $0.objects.removeAll { ids.contains($0.id) } }
        selection = []
    }

    /// Duplicates the selection, offset by 2 mm, and selects the copies.
    func duplicateSelection(offset: Vec2 = Vec2(2, -2)) {
        let copies = selectedObjects.map { $0.duplicated(offsetBy: offset) }
        add(copies, actionName: L("Duplicate"))
    }

    /// Inserts copies of the selection right after their originals (Option-drag); returns the new ids.
    func duplicateInPlace() -> Set<UUID> {
        var ids = Set<UUID>()
        var p = project
        var i = 0
        while i < p.objects.count {
            if selection.contains(p.objects[i].id) {
                let copy = p.objects[i].duplicated()
                ids.insert(copy.id)
                p.objects.insert(copy, at: i + 1)
                i += 1
            }
            i += 1
        }
        project = p
        selection = ids
        changed()
        return ids
    }

    func nudge(_ delta: Vec2) {
        let ids = selectedObjects.filter { !$0.isLocked }.map(\.id)
        guard !ids.isEmpty else { return }
        updateObjects(ids, L("Move"), coalesce: "nudge") { $0.placement.center = $0.placement.center + delta }
    }

    func moveObjects(from source: IndexSet, to destination: Int) {
        perform(L("Change Mark Order")) { $0.objects.move(fromOffsets: source, toOffset: destination) }
    }

    enum OrderMove { case first, earlier, later, last }

    /// Moves the selection within the mark order.
    func reorderSelection(_ move: OrderMove) {
        let ids = selection
        guard !ids.isEmpty else { return }
        perform(L("Change Mark Order")) { p in
            let picked = p.objects.filter { ids.contains($0.id) }
            switch move {
            case .first:
                p.objects.removeAll { ids.contains($0.id) }
                p.objects.insert(contentsOf: picked, at: 0)
            case .last:
                p.objects.removeAll { ids.contains($0.id) }
                p.objects.append(contentsOf: picked)
            case .earlier:
                for i in p.objects.indices.dropFirst() where ids.contains(p.objects[i].id) && !ids.contains(p.objects[i - 1].id) {
                    p.objects.swapAt(i, i - 1)
                }
            case .later:
                for i in p.objects.indices.dropLast().reversed() where ids.contains(p.objects[i].id) && !ids.contains(p.objects[i + 1].id) {
                    p.objects.swapAt(i, i + 1)
                }
            }
        }
    }

    func setPen(_ penID: Int, for ids: Set<UUID>? = nil) {
        updateObjects(ids ?? selection, L("Change Pen")) { $0.penID = penID }
    }

    func toggleVisibility(_ id: UUID) {
        updateObjects([id], L("Show/Hide")) { $0.isVisible.toggle() }
    }

    func toggleLock(_ id: UUID) {
        updateObjects([id], L("Lock/Unlock")) { $0.isLocked.toggle() }
    }

    /// Centres the selection (as a group) on the field origin.
    func centerSelectionInField() {
        let objects = selectedObjects.filter { !$0.isLocked }
        guard let bounds = objects.map({ $0.fieldBounds() }).reduce(nil, { $0?.union($1) ?? $1 }) else { return }
        let delta = Vec2.zero - bounds.center
        updateObjects(objects.map(\.id), L("Center in Field")) { $0.placement.center = $0.placement.center + delta }
    }

    enum Alignment { case left, hCenter, right, top, vCenter, bottom }

    /// Aligns selected objects to the selection bounds.
    func alignSelection(_ alignment: Alignment) {
        let objects = selectedObjects.filter { !$0.isLocked }
        guard objects.count > 1,
              let all = objects.map({ $0.fieldBounds() }).reduce(nil, { $0?.union($1) ?? $1 }) else { return }
        let bounds = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0.fieldBounds()) })
        updateObjects(objects.map(\.id), L("Align")) { o in
            guard let b = bounds[o.id] else { return }
            var d = Vec2.zero
            switch alignment {
            case .left: d.x = all.minX - b.minX
            case .hCenter: d.x = all.center.x - b.center.x
            case .right: d.x = all.maxX - b.maxX
            case .top: d.y = all.maxY - b.maxY
            case .vCenter: d.y = all.center.y - b.center.y
            case .bottom: d.y = all.minY - b.minY
            }
            o.placement.center = o.placement.center + d
        }
    }

    /// Pen to use for new objects: the pen of the selection, else pen 0.
    var currentPenID: Int { singleSelection?.penID ?? inspectedPenID ?? 0 }

    // MARK: Pasteboard

    static let pasteboardType = NSPasteboard.PasteboardType("com.onigam.mrcarve.objects")

    func copySelection() {
        let objects = selectedObjects
        guard !objects.isEmpty, let data = try? JSONEncoder().encode(objects) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: DocumentModel.pasteboardType)
    }

    func cutSelection() {
        copySelection()
        let ids = selection
        perform(L("Cut")) { $0.objects.removeAll { ids.contains($0.id) } }
        selection = []
    }

    var canPaste: Bool { NSPasteboard.general.data(forType: DocumentModel.pasteboardType) != nil }

    func paste() {
        guard let data = NSPasteboard.general.data(forType: DocumentModel.pasteboardType),
              let objects = try? JSONDecoder().decode([DesignObject].self, from: data) else { return }
        let existing = Set(project.objects.map(\.id))
        let offset = objects.contains { existing.contains($0.id) } ? Vec2(2, -2) : .zero
        add(objects.map { $0.duplicated(offsetBy: offset) }, actionName: L("Paste"))
    }

    // MARK: Analysis

    /// Recomputes the time estimate and the field check in the background, debounced.
    /// At most one analysis runs at a time (raster-heavy jobs are expensive); a newer request reruns it afterwards.
    func scheduleAnalysis() {
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.runAnalysis()
        }
    }

    private func runAnalysis() {
        guard !analysisRunning else { analysisPending = true; return }
        analysisRunning = true
        let project = self.project
        let field = machine.field
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let job = JobCompiler.compile(project)
                return (JobCompiler.estimate(job), Set(JobCompiler.objectsOutsideField(project, field: field)))
            }.value
            guard let self else { return }
            self.estimate = result.0
            self.outsideField = result.1
            self.analysisRunning = false
            if self.analysisPending {
                self.analysisPending = false
                self.runAnalysis()
            }
        }
    }

    /// Re-traces the red light shortly after edits while this document is framing.
    private func scheduleFramingRefresh() {
        framingTask?.cancel()
        framingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, DeviceViewModel.shared.isFraming, DeviceViewModel.shared.ownerID == self.id else { return }
            self.refreshFraming()
        }
    }

    // MARK: Files

    static let projectType: UTType = UTType(Project.typeIdentifier)
        ?? UTType(filenameExtension: Project.fileExtension, conformingTo: .json) ?? .json

    nonisolated static let imageExtensions = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "bmp", "gif"]

    static var importableExtensions: [String] { VectorImporter.supportedExtensions + imageExtensions }

    /// Loads a project from disk, replacing the current one.
    func load(_ url: URL) throws {
        let loaded = try Project(contentsOf: url)
        project = loaded
        fileURL = url
        selection = []
        inspectedPenID = nil
        isDirty = false
        undoManager?.removeAllActions()
        RecentFiles.shared.add(url)
        scheduleAnalysis()
    }

    /// Saves to the current file, or asks for one. Returns false if cancelled or failed.
    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DocumentModel.projectType]
        panel.nameFieldStringValue = displayName + "." + Project.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            try project.write(to: url)
            fileURL = url
            isDirty = false
            RecentFiles.shared.add(url)
            return true
        } catch {
            alert = AlertInfo(title: L("Could not save the project"), message: error.localizedDescription)
            return false
        }
    }

    // MARK: Import

    /// Shows an open panel for vector files and images.
    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DocumentModel.importableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = L("Choose vector files (%@) or images.", VectorImporter.supportedExtensions.map { $0.uppercased() }.joined(separator: ", "))
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, at: nil)
    }

    /// Imports vector files and images; files are decoded off the main thread. `point` is the drop location.
    func importFiles(_ urls: [URL], at point: Vec2?) {
        let field = machine.field
        let penID = currentPenID
        Task {
            var objects: [DesignObject] = []
            var failures: [String] = []
            for (n, url) in urls.enumerated() {
                let center = (point ?? .zero) + Vec2(Double(n) * 3, Double(n) * -3)
                do {
                    objects.append(try await Task.detached(priority: .userInitiated) {
                        try DocumentModel.makeObject(from: url, center: center, field: field, penID: penID)
                    }.value)
                } catch {
                    failures.append("\(url.lastPathComponent): \(DeviceViewModel.describe(error))")
                }
            }
            add(objects, actionName: L("Import"))
            if !failures.isEmpty {
                alert = AlertInfo(title: L("Some files could not be imported"), message: failures.joined(separator: "\n"))
            }
        }
    }

    nonisolated static func makeObject(from url: URL, center: Vec2, field: Rect2, penID: Int) throws -> DesignObject {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if VectorImporter.supportedExtensions.contains(ext) {
            let polylines = try VectorImporter.load(url: url)
            guard !polylines.isEmpty else { throw VectorImportError.unreadable(L("the file contains no paths")) }
            var object = DesignObject.vector(polylines, sourceName: name, at: center, penID: penID)
            // Shrink artwork larger than the field to 90 % of it.
            let limit = min(field.width, field.height) * 0.9
            let largest = max(object.placement.width, object.placement.height)
            if largest > limit {
                object.placement.width *= limit / largest
                object.placement.height *= limit / largest
            }
            return object
        }
        if imageExtensions.contains(ext) {
            let content = try ImageContent(imageData: try Data(contentsOf: url), sourceName: name)
            return DesignObject.image(content, at: center, longestSide: 40, penID: penID)
        }
        throw VectorImportError.unsupported(ext.isEmpty ? name : ext)
    }
}

/// Recently opened projects (File ▸ Open Recent).
@MainActor @Observable
final class RecentFiles {
    static let shared = RecentFiles()
    private static let key = "recentFiles"
    private static let limit = 10

    private(set) var urls: [URL] = []

    private init() {
        urls = (UserDefaults.standard.stringArray(forKey: RecentFiles.key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        urls.removeAll { $0.path == url.path }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(RecentFiles.limit))
        UserDefaults.standard.set(urls.map(\.path), forKey: RecentFiles.key)
    }

    func clear() {
        urls = []
        UserDefaults.standard.removeObject(forKey: RecentFiles.key)
    }
}
