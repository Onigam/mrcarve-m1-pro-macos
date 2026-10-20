import SwiftUI
import MRCarveKit

/// SwiftUI bindings that route writes through undoable, coalesced edits.
extension DocumentModel {
    /// Binding to a property of object `id`.
    func binding<T>(_ id: UUID, _ keyPath: WritableKeyPath<DesignObject, T>, _ actionName: String) -> Binding<T> {
        let fallback = project.object(id)?[keyPath: keyPath]
        return Binding(
            get: { [weak self] in (self?.project.object(id)?[keyPath: keyPath] ?? fallback)! },
            set: { [weak self] value in
                self?.updateObjects([id], actionName, coalesce: "\(id)\(keyPath)") { $0[keyPath: keyPath] = value }
            })
    }

    /// Binding to a property of the text content of object `id`; the object is resized to the new glyphs.
    func textBinding<T>(_ id: UUID, _ keyPath: WritableKeyPath<TextContent, T>) -> Binding<T> {
        var fallback: T?
        if case .text(let t) = project.object(id)?.kind { fallback = t[keyPath: keyPath] }
        return Binding(
            get: { [weak self] in
                if case .text(let t) = self?.project.object(id)?.kind { return t[keyPath: keyPath] }
                return fallback!
            },
            set: { [weak self] value in
                self?.updateObjects([id], L("Edit Text"), coalesce: "text\(id)\(keyPath)") { o in
                    guard case .text(var t) = o.kind else { return }
                    let oldFirstLine = t.string.components(separatedBy: .newlines).first ?? ""
                    t[keyPath: keyPath] = value
                    o.kind = .text(t)
                    // The name follows the text unless the user renamed the object.
                    if o.name == oldFirstLine || o.name.isEmpty || o.name == L("Text") {
                        let first = t.string.components(separatedBy: .newlines).first ?? ""
                        o.name = first.isEmpty ? L("Text") : first
                    }
                    let center = o.placement.center
                    o.fitToContent()
                    o.placement.center = center
                }
            })
    }

    /// Binding to the whole kind of object `id`.
    func kindBinding(_ id: UUID, _ actionName: String) -> Binding<ObjectKind> {
        binding(id, \.kind, actionName)
    }

    /// Binding to the raster settings of image object `id`.
    func rasterBinding(_ id: UUID) -> Binding<RasterSettings> {
        var fallback = RasterSettings()
        if case .image(let img) = project.object(id)?.kind { fallback = img.raster }
        return Binding(
            get: { [weak self] in
                if case .image(let img) = self?.project.object(id)?.kind { return img.raster }
                return fallback
            },
            set: { [weak self] value in
                self?.updateObjects([id], L("Change Image Settings"), coalesce: "raster\(id)") { o in
                    guard case .image(var img) = o.kind else { return }
                    img.raster = value
                    o.kind = .image(img)
                }
            })
    }

    /// Binding to a parameter of pen `penID`.
    func penBinding<T>(_ penID: Int, _ keyPath: WritableKeyPath<PenParameters, T>, _ actionName: String = L("Change Pen Parameters")) -> Binding<T> {
        Binding(
            get: { [weak self] in (self?.project.pen(penID) ?? PenParameters(id: penID))[keyPath: keyPath] },
            set: { [weak self] value in
                self?.perform(actionName, coalesce: "pen\(penID)\(keyPath)") { $0.updatePen(penID) { $0[keyPath: keyPath] = value } }
            })
    }

    /// Binding to the project's repeat count / machine profile and other top-level fields.
    func projectBinding<T>(_ keyPath: WritableKeyPath<Project, T>, _ actionName: String) -> Binding<T> {
        Binding(
            get: { [weak self] in (self?.project ?? Project())[keyPath: keyPath] },
            set: { [weak self] value in self?.perform(actionName, coalesce: "project\(keyPath)") { $0[keyPath: keyPath] = value } })
    }
}
