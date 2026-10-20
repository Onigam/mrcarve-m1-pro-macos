import Foundation
import CoreGraphics
import ImageIO
import MRCarveKit

enum ModelProjectTests {
    /// A project exercising every object kind and optional field.
    static func sampleProject() throws -> Project {
        var project = Project()
        project.repeatCount = 3
        project.updatePen(2) { $0.markSpeed = 1234; $0.power = 77; $0.isEnabled = false }

        var text = DesignObject.text("Hello\nWorld", at: Vec2(1, 2),
                                     content: TextContent(string: "", fontFamily: "Avenir Next", height: 6,
                                                          letterSpacing: 0.3, lineSpacing: 1.5, alignment: .center))
        var fill = FillSettings()
        var second = HatchLayer()
        second.angle = 45
        second.penID = 3
        second.crossHatch = true
        fill.layers.append(second)
        fill.outlineFirst = false
        text.fill = fill
        text.placement.rotation = 30
        text.placement.mirrorX = true

        var rect = DesignObject.rectangle(Rect2(minX: -10, minY: -5, maxX: 10, maxY: 5), cornerRadius: 2, penID: 1)
        rect.isLocked = true
        var ellipse = DesignObject.ellipse(Rect2(minX: 0, minY: 0, maxX: 8, maxY: 4))
        ellipse.isVisible = false
        let star = DesignObject.polygon(Rect2(minX: -3, minY: -3, maxX: 3, maxY: 3), sides: 5, starRatio: 0.4)
        let hexagon = DesignObject.polygon(Rect2(minX: -3, minY: -3, maxX: 3, maxY: 3), sides: 6)
        let line = DesignObject.line(from: Vec2(-5, -5), to: Vec2(5, 5))
        let vector = DesignObject.vector([Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 5)], closed: true),
                                          Polyline([Vec2(1, 1), Vec2(2, 3)])], sourceName: "logo.svg")
        var raster = RasterSettings()
        raster.dither = .atkinson
        raster.lineInterval = 0.08
        let image = DesignObject.image(try ImageContent(imageData: tinyPNG(), sourceName: "photo.png", raster: raster))
        project.objects = [text, rect, ellipse, star, hexagon, line, vector, image]
        return project
    }

    /// A 4×2 RGBA PNG generated with ImageIO.
    static func tinyPNG() -> Data {
        let ctx = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func register() {
        test("model: project JSON round-trip preserves every object kind") {
            let project = try sampleProject()
            let data = try project.fileData()
            let decoded = try Project(fileData: data)
            expectEqual(decoded, project)
            expectEqual(decoded.objects.map(\.kind.typeName),
                        ["text", "rectangle", "ellipse", "polygon", "polygon", "line", "vector", "image"])
            // Writing the decoded copy again is byte-identical (sorted keys, stable encoding).
            expectEqual(try decoded.fileData(), data)
        }

        test("model: project file round-trip through disk") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID()).mrcarve")
            defer { try? FileManager.default.removeItem(at: url) }
            let project = try sampleProject()
            try project.write(to: url)
            expectEqual(try Project(contentsOf: url), project)
        }

        test("model: newer format versions and foreign files are rejected") {
            var json = try JSONSerialization.jsonObject(with: try Project().fileData()) as! [String: Any]
            json["version"] = Project.formatVersion + 1
            let newer = try JSONSerialization.data(withJSONObject: json)
            do { _ = try Project(fileData: newer); expect(false, "newer version accepted") } catch let e as ProjectFileError {
                expectEqual(e, .newerVersion(Project.formatVersion + 1))
            }
            do { _ = try Project(fileData: Data("{\"a\":1}".utf8)); expect(false, "foreign file accepted") } catch let e as ProjectFileError {
                expectEqual(e, .notAProject)
            }
        }

        test("model: files missing newer pen / profile fields still load") {
            var project = Project()
            project.updatePen(3) { $0.markSpeed = 777 }
            var json = try JSONSerialization.jsonObject(with: try project.fileData()) as! [String: Any]
            var pens = json["pens"] as! [[String: Any]]
            pens[3].removeValue(forKey: "pointDwell")
            pens[3].removeValue(forKey: "jumpSpeed")
            json["pens"] = pens
            let decoded = try Project(fileData: try JSONSerialization.data(withJSONObject: json))
            expectEqual(decoded.pen(3).markSpeed, 777)
            expectEqual(decoded.pen(3).jumpSpeed, PenParameters(id: 3).jumpSpeed)
            expectEqual(decoded.pens.count, 16)

            let data = try JSONEncoder().encode(MachineProfileLibrary())
            var lib = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var profiles = lib["profiles"] as! [[String: Any]]
            var lens = profiles[1]["lens"] as! [String: Any]
            lens.removeValue(forKey: "scaleX")
            profiles[1]["lens"] = lens
            profiles[1].removeValue(forKey: "redLight")
            lib["profiles"] = profiles
            let machines = try JSONDecoder().decode(MachineProfileLibrary.self, from: try JSONSerialization.data(withJSONObject: lib))
            expectEqual(machines.profiles.count, 2)
            expectEqual(machines.profiles[1].source, .blue)
            expectEqual(machines.profiles[1].lens.scaleX, LensParameters().scaleX)
        }

        test("model: new project has 16 default pens") {
            let p = Project()
            expectEqual(p.pens.count, 16)
            expectEqual(p.pens.map(\.id), Array(0..<16))
            expectEqual(p.pen(5).colorRGB, PenParameters.defaultColors[5])
            expectEqual(p.repeatCount, 1)
        }

        test("model: pen usage counts outline and hatch pens") {
            let p = try sampleProject()
            expectEqual(p.usageCount(ofPen: 3), 1)
            expectEqual(p.usageCount(ofPen: 1), 1)
            expectEqual(p.usageCount(ofPen: 9), 0)
        }

        test("model: preset apply keeps pen identity") {
            var pen = PenParameters(id: 7, name: "Logo", colorRGB: 0x123456)
            pen.isEnabled = false
            let preset = PenPresetLibrary.startingPoints[0]
            let applied = preset.applied(to: pen)
            expectEqual(applied.id, 7)
            expectEqual(applied.name, "Logo")
            expectEqual(applied.colorRGB, 0x123456)
            expectEqual(applied.isEnabled, false)
            expectEqual(applied.markSpeed, preset.parameters.markSpeed)
            expect(PenPresetLibrary.startingPoints.allSatisfy(\.isStartingPoint))
        }

        test("model: preset and machine libraries round-trip") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mrcarve-lib-\(UUID())")
            defer { try? FileManager.default.removeItem(at: dir) }
            var pen = PenParameters(id: 0)
            pen.markSpeed = 42
            let library = PenPresetLibrary(userPresets: [PenPreset(name: "Mine", from: pen, source: .blue)])
            try library.save(to: dir.appendingPathComponent("p.json"))
            expectEqual(PenPresetLibrary.load(from: dir.appendingPathComponent("p.json")), library)
            expectEqual(PenPresetLibrary.load(from: dir.appendingPathComponent("missing.json")).userPresets.count, 0)

            var machines = MachineProfileLibrary()
            var custom = MachineProfile(name: machines.uniqueName(MachineProfileLibrary.fiberName), source: .fiber)
            custom.lens.scaleX = 63
            machines.upsert(custom)
            try machines.save(to: dir.appendingPathComponent("m.json"))
            let loaded = MachineProfileLibrary.load(from: dir.appendingPathComponent("m.json"))
            expectEqual(loaded, machines)
            expectEqual(loaded.profile(named: custom.name).lens.scaleX, 63)
            expectEqual(loaded.profile(named: "nope").name, MachineProfileLibrary.fiberName)
        }
    }
}
