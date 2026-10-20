import Foundation
import Observation
import MRCarveKit

/// Canvas tools.
enum CanvasTool: String, CaseIterable, Identifiable {
    case select, text, rectangle, ellipse, polygon, line

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: L("Select")
        case .text: L("Text")
        case .rectangle: L("Rectangle")
        case .ellipse: L("Ellipse")
        case .polygon: L("Polygon")
        case .line: L("Line")
        }
    }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .polygon: "hexagon"
        case .line: "line.diagonal"
        }
    }

    /// Single-key shortcut on the canvas.
    var key: Character {
        switch self {
        case .select: "v"
        case .text: "t"
        case .rectangle: "r"
        case .ellipse: "e"
        case .polygon: "p"
        case .line: "l"
        }
    }
}

/// Per-window UI state that is not part of the document.
@MainActor @Observable
final class EditorState {
    var tool: CanvasTool = .select
    /// Cursor position over the canvas, mm (nil when outside).
    var cursor: Vec2?
    /// Zoom relative to physical size (1 = actual size on screen).
    var zoom: Double = 1
    var isInspectorPresented = true
    /// Lock W/H proportions in the inspector.
    var aspectLocked = true
    /// Set to ask the inspector to focus the text field of the selected text object.
    var wantsTextFocus = false
    /// The canvas view, for zoom commands.
    @ObservationIgnored weak var canvas: CanvasNSView?
}
