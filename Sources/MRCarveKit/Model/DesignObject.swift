import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Kind payloads

/// Parameters of a text object. Glyph outlines come from `TextOutliner`.
public struct TextContent: Codable, Hashable, Sendable {
    public var string: String
    public var fontFamily: String
    /// Em size in mm.
    public var height: Double
    /// Extra space between characters, mm.
    public var letterSpacing: Double
    /// Line pitch as a multiple of `height`.
    public var lineSpacing: Double
    public var alignment: TextAlignment

    public init(string: String, fontFamily: String = "Helvetica", height: Double = 5,
                letterSpacing: Double = 0, lineSpacing: Double = 1.2, alignment: TextAlignment = .left) {
        self.string = string
        self.fontFamily = fontFamily
        self.height = height
        self.letterSpacing = letterSpacing
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }
}

/// Imported vector artwork (already flattened to polylines, mm, natural size).
public struct VectorContent: Codable, Hashable, Sendable {
    public var polylines: [Polyline]
    /// File name the artwork was imported from (display only).
    public var sourceName: String

    public init(polylines: [Polyline], sourceName: String) {
        self.polylines = polylines
        self.sourceName = sourceName
    }
}

/// A bitmap engraved line by line. The image is stored as PNG so projects are self-contained.
public struct ImageContent: Codable, Hashable, Sendable {
    public var pngData: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var raster: RasterSettings
    /// File name the image was imported from (display only).
    public var sourceName: String

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int, raster: RasterSettings = .init(), sourceName: String = "") {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.raster = raster
        self.sourceName = sourceName
    }

    /// Decodes and re-encodes any image format ImageIO understands (PNG, JPEG, TIFF, HEIC, …) as PNG.
    public init(imageData: Data, sourceName: String = "", raster: RasterSettings = .init()) throws {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ModelError.unreadableImage(sourceName) }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw ModelError.unreadableImage(sourceName)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ModelError.unreadableImage(sourceName) }
        self.init(pngData: out as Data, pixelWidth: image.width, pixelHeight: image.height,
                  raster: raster, sourceName: sourceName)
    }

    /// Decoded image, or nil if the data is corrupt.
    public var cgImage: CGImage? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Width / height of the pixel grid.
    public var aspectRatio: Double {
        pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1
    }
}

/// Errors raised by the document model.
public enum ModelError: Error, LocalizedError, Sendable {
    case unreadableImage(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let name): "The image “\(name)” could not be read."
        }
    }
}

// MARK: - Kind

/// What a design object is. Shapes are generated analytically; text, vectors and images carry their content.
public enum ObjectKind: Hashable, Sendable {
    case text(TextContent)
    /// Rectangle; `cornerRadius` in mm (clamped to half the shorter side).
    case rectangle(cornerRadius: Double)
    case ellipse
    /// Regular polygon with `sides` corners; with `starRatio` (0…1, inner/outer radius) it becomes a star.
    case polygon(sides: Int, starRatio: Double?)
    /// Straight segment along the local X axis; its length is the placement width.
    case line
    case vector(VectorContent)
    case image(ImageContent)

    /// Stable identifier of the case, also used in the file format.
    public var typeName: String {
        switch self {
        case .text: "text"
        case .rectangle: "rectangle"
        case .ellipse: "ellipse"
        case .polygon: "polygon"
        case .line: "line"
        case .vector: "vector"
        case .image: "image"
        }
    }

    public var isText: Bool { if case .text = self { true } else { false } }
    public var isImage: Bool { if case .image = self { true } else { false } }
    public var isLine: Bool { if case .line = self { true } else { false } }

    /// Whether the kind can be hatch-filled (has closed contours).
    public var supportsFill: Bool {
        switch self {
        case .line, .image: false
        default: true
        }
    }
}

extension ObjectKind: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, cornerRadius, sides, starRatio, vector, image }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try c.decode(TextContent.self, forKey: .text))
        case "rectangle": self = .rectangle(cornerRadius: try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0)
        case "ellipse": self = .ellipse
        case "polygon":
            self = .polygon(sides: try c.decodeIfPresent(Int.self, forKey: .sides) ?? 6,
                            starRatio: try c.decodeIfPresent(Double.self, forKey: .starRatio))
        case "line": self = .line
        case "vector": self = .vector(try c.decode(VectorContent.self, forKey: .vector))
        case "image": self = .image(try c.decode(ImageContent.self, forKey: .image))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown object type “\(type)”")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .text(let t): try c.encode(t, forKey: .text)
        case .rectangle(let r): try c.encode(r, forKey: .cornerRadius)
        case .ellipse, .line: break
        case .polygon(let sides, let star):
            try c.encode(sides, forKey: .sides)
            try c.encodeIfPresent(star, forKey: .starRatio)
        case .vector(let v): try c.encode(v, forKey: .vector)
        case .image(let i): try c.encode(i, forKey: .image)
        }
    }
}

// MARK: - Design object

/// One item of a project: geometry + placement + marking attributes. Order in the project is mark order.
public struct DesignObject: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ObjectKind
    public var placement: Placement
    /// Pen used for outlines, rasters and hatch layers without their own pen.
    public var penID: Int
    /// Hatch fill; `nil` marks the outline only.
    public var fill: FillSettings?
    public var isVisible: Bool
    public var isLocked: Bool

    public init(id: UUID = UUID(), name: String, kind: ObjectKind, placement: Placement, penID: Int = 0,
                fill: FillSettings? = nil, isVisible: Bool = true, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.placement = placement
        self.penID = penID
        self.fill = fill
        self.isVisible = isVisible
        self.isLocked = isLocked
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, placement, penID, fill, isVisible, isLocked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decode(ObjectKind.self, forKey: .kind)
        placement = try c.decode(Placement.self, forKey: .placement)
        penID = try c.decodeIfPresent(Int.self, forKey: .penID) ?? 0
        fill = try c.decodeIfPresent(FillSettings.self, forKey: .fill)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(placement, forKey: .placement)
        try c.encode(penID, forKey: .penID)
        try c.encodeIfPresent(fill, forKey: .fill)
        try c.encode(isVisible, forKey: .isVisible)
        try c.encode(isLocked, forKey: .isLocked)
    }

    /// A copy with a fresh identifier.
    public func duplicated(offsetBy delta: Vec2 = .zero) -> DesignObject {
        var copy = self
        copy.id = UUID()
        copy.placement.center = placement.center + delta
        return copy
    }
}

// MARK: - Factories

extension DesignObject {
    /// A text object sized to its glyphs (falls back to an estimate when no outlines are available).
    public static func text(_ string: String, at center: Vec2 = .zero, content: TextContent? = nil, penID: Int = 0) -> DesignObject {
        var c = content ?? TextContent(string: string)
        c.string = string
        var object = DesignObject(name: string.components(separatedBy: .newlines).first ?? string, kind: .text(c),
                                  placement: Placement(center: center, width: 1, height: 1), penID: penID)
        object.fitToContent()
        return object
    }

    public static func rectangle(_ rect: Rect2, cornerRadius: Double = 0, penID: Int = 0) -> DesignObject {
        DesignObject(name: "Rectangle", kind: .rectangle(cornerRadius: cornerRadius),
                     placement: Placement(center: rect.center, width: rect.width, height: rect.height), penID: penID)
    }

    public static func ellipse(_ rect: Rect2, penID: Int = 0) -> DesignObject {
        DesignObject(name: "Ellipse", kind: .ellipse,
                     placement: Placement(center: rect.center, width: rect.width, height: rect.height), penID: penID)
    }

    public static func polygon(_ rect: Rect2, sides: Int = 6, starRatio: Double? = nil, penID: Int = 0) -> DesignObject {
        DesignObject(name: starRatio == nil ? "Polygon" : "Star", kind: .polygon(sides: sides, starRatio: starRatio),
                     placement: Placement(center: rect.center, width: rect.width, height: rect.height), penID: penID)
    }

    /// A line from `a` to `b` (stored as centre + length + rotation).
    public static func line(from a: Vec2, to b: Vec2, penID: Int = 0) -> DesignObject {
        let d = b - a
        return DesignObject(name: "Line", kind: .line,
                            placement: Placement(center: (a + b) / 2, width: d.length, height: 0,
                                                 rotation: atan2(d.y, d.x) * 180 / .pi), penID: penID)
    }

    /// Imported vector artwork at natural size, centred on `center`.
    public static func vector(_ polylines: [Polyline], sourceName: String, at center: Vec2 = .zero, penID: Int = 0) -> DesignObject {
        var object = DesignObject(name: sourceName, kind: .vector(VectorContent(polylines: polylines, sourceName: sourceName)),
                                  placement: Placement(center: center, width: 1, height: 1), penID: penID)
        object.fitToContent()
        return object
    }

    /// An image whose longest side is `longestSide` mm.
    public static func image(_ content: ImageContent, at center: Vec2 = .zero, longestSide: Double = 40, penID: Int = 0) -> DesignObject {
        let aspect = content.aspectRatio
        let w = aspect >= 1 ? longestSide : longestSide * aspect
        let h = aspect >= 1 ? longestSide / aspect : longestSide
        return DesignObject(name: content.sourceName.isEmpty ? "Image" : content.sourceName, kind: .image(content),
                            placement: Placement(center: center, width: w, height: h), penID: penID)
    }
}
