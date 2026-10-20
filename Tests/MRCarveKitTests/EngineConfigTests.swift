import Foundation
import MRCarveKit

enum EngineConfigTests {
    /// Vendor files (read-only, outside the repository's tracked content); tests skip when absent.
    static let vendorDirectory: URL = {
        let here = URL(fileURLWithPath: #filePath)  // Tests/MRCarveKitTests/EngineConfigTests.swift
        return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("M1-pro-3.0-tomigrate/2、software/config")
    }()

    static func vendorFile(_ name: String) -> URL? {
        let url = vendorDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        print("    (skipped: \(name) not found)")
        return nil
    }

    static func register() {
        test("config: INI parsing") {
            let text = "[FileBegin]\r\n; comment\r\n[default]\r\nA=1\r\nb = two words \r\nA=3\r\nEMPTY=\r\nnoequals\r\n"
                + "[Other]\r\nX=y=z\r\n[FileEnd]\r\nAFTER=1\r\n"
            let s = VendorConfig.parse(text: text)
            expectEqual(Set(s.keys), ["default", "Other"])
            expectEqual(s["default"], ["A": "3", "b": "two words", "EMPTY": ""])
            expectEqual(s["Other"], ["X": "y=z"])
            expectEqual(VendorConfig.parse(text: "K=V\n")[""], ["K": "V"])
        }

        test("config: encodings") {
            let text = "[s]\nname=参数 é\n"
            var utf16 = Data([0xFF, 0xFE])
            utf16.append(text.data(using: .utf16LittleEndian)!)
            expectEqual(VendorConfig.parse(data: utf16)["s"]?["name"], "参数 é")
            expectEqual(VendorConfig.parse(data: text.data(using: .utf16LittleEndian)!)["s"]?["name"], "参数 é")
            expectEqual(VendorConfig.parse(data: Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8))["s"]?["name"], "参数 é")
            let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let gb = "[s]\nname=参数\n".data(using: gbEncoding)!
            expect(String(data: gb, encoding: .utf8) == nil)  // really not UTF-8
            expectEqual(VendorConfig.parse(data: gb)["s"]?["name"], "参数")
        }

        test("config: machine profile from synthetic LmcPar") {
            let text = """
                [FileBegin]
                [default]
                LEN_SCALEX=6.500000e+001
                LEN_XINVERT=1
                OPC_MINPWMFREQ=1.000000e+003
                OPC_MAXPWMFREQ=2.000000e+006
                OPC_POWERMAP0=5
                COR_FILENAME=
                CUSTOM_KEY=42
                [FileEnd]
                """
            let p = try VendorConfig.machineProfile(fromLmcPar: VendorConfig.parse(text: text), source: .blue)
            expectEqual(p.source, .blue)
            expectClose(p.lens.scaleX, 65)
            expect(p.lens.invertX)
            expectClose(p.laser.minFrequency, 1)
            expectClose(p.laser.maxFrequency, 2000)
            expectEqual(p.laser.powerMap, LaserSourceParameters().powerMap)  // incomplete map keeps the default
            expect(p.lens.correctionFilePath == nil)
            expectEqual(p.raw["CUSTOM_KEY"], "42")
            expectClose(p.lens.scaleY, LensParameters().scaleY)  // missing → default
            do {
                _ = try VendorConfig.machineProfile(fromLmcPar: ["a": [:], "b": [:]], source: .fiber)
                expect(false, "missing [default] should throw")
            } catch {}
        }

        test("config: real LmcPar_Fiber.cfg / LmcPar_Blue.cfg") {
            guard let fiberURL = vendorFile("LmcPar_Fiber.cfg"), let blueURL = vendorFile("LmcPar_Blue.cfg") else { return }
            let fiber = try VendorConfig.machineProfile(fromLmcPar: fiberURL, source: .fiber)
            // Core/MachineProfile.swift defaults were taken from this file.
            var lens = fiber.lens
            lens.correctionFilePath = nil
            expectEqual(lens, LensParameters())
            expectEqual(fiber.redLight, RedLightParameters())
            expectEqual(fiber.laser, LaserSourceParameters())
            expect(fiber.lens.correctionFilePath?.hasSuffix("sea.cor") == true)
            expect(fiber.raw.count > 400, "raw keys: \(fiber.raw.count)")
            expectEqual(fiber.raw["PARNAME"], "default")
            expectEqual(fiber.raw["OPC_MoDelay"], "8")

            let blue = try VendorConfig.machineProfile(fromLmcPar: blueURL, source: .blue)
            expectClose(blue.lens.scaleX, 64.418)
            expectClose(blue.lens.scaleY, 65.693)
            expectClose(blue.lens.bucketX, 1.04)
            expectClose(blue.lens.trapezoidX, 1.002)
            expectClose(blue.lens.fieldOffsetX, 0.4)
            expectClose(blue.redLight.offsetX, 0)
            expectClose(blue.redLight.scaleX, 1)
            expectClose(blue.laser.maxFrequency, 200)
        }

        test("config: real fillPara.cfg") {
            guard let url = vendorFile("fillPara.cfg") else { return }
            let fill = try VendorConfig.fillSettings(fromFillPara: url)
            expectEqual(fill.layers.count, 4)
            expect(fill.markOutline && fill.outlineFirst)
            let first = fill.layers[0]
            expect(first.isEnabled && first.evenDistribution && first.bidirectional && !first.crossHatch)
            expectClose(first.spacing, 0.05)
            expectClose(first.angle, 0)
            expect(first.penID == nil)
            expect(fill.layers.dropFirst().allSatisfy { !$0.isEnabled && abs($0.spacing - 0.06) < 1e-12 })
            // Round trip through Codable, and decoding of a document written before the extra fields existed.
            let data = try JSONEncoder().encode(fill)
            expectEqual(try JSONDecoder().decode(FillSettings.self, from: data), fill)
            let old = try JSONDecoder().decode(HatchLayer.self, from: Data(#"{"angle": 45, "spacing": 0.1}"#.utf8))
            expectClose(old.angle, 45)
            expect(old.isEnabled && !old.evenDistribution && old.endOffset == 0)
            let raster = try JSONDecoder().decode(RasterSettings.self, from: Data(#"{"dither": "atkinson"}"#.utf8))
            expectEqual(raster.dither, .atkinson)
            expectClose(raster.lineInterval, RasterSettings().lineInterval)
        }
    }
}
