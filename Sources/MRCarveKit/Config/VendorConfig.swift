import Foundation

/// Errors from reading vendor configuration files.
public enum VendorConfigError: Error, LocalizedError, Sendable {
    case unreadable(String)
    case missingSection(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let m): "Cannot read configuration: \(m)"
        case .missingSection(let s): "Configuration section [\(s)] not found"
        }
    }
}

// MARK: - Vendor configuration files

/// Reader for the vendor software's INI-style `.cfg` files (`LmcPar_*.cfg`, `fillPara.cfg`, ...).
///
/// Format: `[section]` headers and `key=value` lines (CRLF or LF), wrapped in `[FileBegin]` … `[FileEnd]`
/// markers which are not sections. Encodings: UTF-16 (BOM or BOM-less little-endian), UTF-8 (with or
/// without BOM), otherwise GB18030 (superset of the GBK used by the Chinese Windows software).
/// Keys are case-sensitive as stored; lookups by the mapping helpers fall back to case-insensitive matching.
public enum VendorConfig {
    /// Parses a vendor INI-style `.cfg` (`LmcPar_Fiber.cfg`, `fillPara.cfg`, ...). Handles GBK/UTF-8/UTF-16.
    public static func parse(url: URL) throws -> [String: [String: String]] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw VendorConfigError.unreadable(error.localizedDescription) }
        return parse(data: data)
    }

    /// Parses INI data: section → key → value. Keys before the first section go to the "" section.
    /// Later duplicates win. Lines starting with `;`, `#` or `//` are comments. Parsing stops at `[FileEnd]`.
    public static func parse(data: Data) -> [String: [String: String]] {
        parse(text: decodeText(data))
    }

    /// Parses INI text (see `parse(data:)`).
    public static func parse(text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                switch name.lowercased() {
                case "filebegin": continue
                case "fileend": return sections
                default:
                    current = name
                    if sections[current] == nil { sections[current] = [:] }
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            sections[current, default: [:]][key] = value
        }
        return sections
    }

    /// Decodes vendor text: UTF-16 (BOM, or zero high bytes), UTF-8 (BOM optional), else GB18030, else Latin-1.
    public static func decodeText(_ data: Data) -> String {
        let b = [UInt8](data.prefix(4))
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return String(data: data.dropFirst(3), encoding: .utf8) ?? "" }
        if b.count >= 4, b[0] != 0, b[1] == 0, b[2] != 0, b[3] == 0, let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Machine profile

    /// Builds a machine profile from an `LmcPar_*.cfg` file.
    public static func machineProfile(fromLmcPar url: URL, source: LaserSource) throws -> MachineProfile {
        try machineProfile(fromLmcPar: parse(url: url), source: source)
    }

    /// Builds a machine profile from parsed `LmcPar_*.cfg` sections (values are read from `[default]`).
    /// Unknown or missing keys keep the `MachineProfile` defaults; every key is preserved in `raw`
    /// (keys of other sections as "section.key").
    public static func machineProfile(fromLmcPar sections: [String: [String: String]], source: LaserSource) throws -> MachineProfile {
        let usedName = sections.keys.first { $0.caseInsensitiveCompare("default") == .orderedSame }
            ?? (sections.count == 1 ? sections.keys.first : nil)
        guard let usedName, let values = sections[usedName] else { throw VendorConfigError.missingSection("default") }
        let v = Values(values)
        var profile = MachineProfile(name: source == .fiber ? "M1 Pro (Fiber)" : "M1 Pro (Blue)", source: source)

        var lens = profile.lens
        v.double("LEN_WORKSIZE") { lens.workSize = $0 }
        v.double("LEN_SCALEX") { lens.scaleX = $0 }
        v.double("LEN_SCALEY") { lens.scaleY = $0 }
        v.double("LEN_BUCKETX") { lens.bucketX = $0 }
        v.double("LEN_BUCKETY") { lens.bucketY = $0 }
        v.double("LEN_TRAPEX") { lens.trapezoidX = $0 }
        v.double("LEN_TRAPEY") { lens.trapezoidY = $0 }
        v.double("LEN_PRRLX") { lens.parallelogramX = $0 }
        v.double("LEN_PRRLY") { lens.parallelogramY = $0 }
        v.double("LEN_FIELDOFFSETX") { lens.fieldOffsetX = $0 }
        v.double("LEN_FIELDOFFSETY") { lens.fieldOffsetY = $0 }
        v.double("LEN_ROTATEANGLE") { lens.rotateAngle = $0 }
        v.bool("LEN_XINVERT") { lens.invertX = $0 }
        v.bool("LEN_YINVERT") { lens.invertY = $0 }
        v.bool("LEN_XYFLIP") { lens.swapXY = $0 }
        v.double("LEN_MAXSPEED") { lens.maxSpeed = $0 }
        v.double("LEN_MINSPEED") { lens.minSpeed = $0 }
        v.bool("LEN_ENABLECORFILE") { lens.useCorrectionFile = $0 }
        if let path = v["COR_FILENAME"] { lens.correctionFilePath = path.isEmpty ? nil : path }
        profile.lens = lens

        var red = profile.redLight
        v.double("REDLIGHTSPEED") { red.speed = $0 }
        v.double("REDLIGHTOFFSETX") { red.offsetX = $0 }
        v.double("REDLIGHTOFFSETY") { red.offsetY = $0 }
        v.double("REDLIGHTSCALEX") { red.scaleX = $0 }
        v.double("REDLIGHTSCALEY") { red.scaleY = $0 }
        v.int("REDLIGHTOUTPORT") { red.outputPort = $0 }
        profile.redLight = red

        var laser = profile.laser
        v.int("LASERTYPE") { laser.laserType = $0 }
        v.int("FIBERTYPE") { laser.fiberType = $0 }
        v.bool("OPC_FPK") { laser.firstPulseKiller = $0 }
        v.double("OPC_FPKTIME") { laser.firstPulseKillerTime = $0 }
        v.bool("OPC_ENPWMOUT") { laser.pwmOutput = $0 }
        v.bool("OPC_ENPOWERANALOGOUT") { laser.analogPowerOutput = $0 }
        v.double("OPC_MINPWMFREQ") { laser.minFrequency = $0 / 1000 }  // Hz → kHz
        v.double("OPC_MAXPWMFREQ") { laser.maxFrequency = $0 / 1000 }
        v.double("OPC_MINQPW") { laser.minPulseWidth = $0 }
        v.double("OPC_MAXQPW") { laser.maxPulseWidth = $0 }
        v.double("OPC_MoDelay") { laser.moDelay = $0 }
        let map = (0...10).compactMap { v.number("OPC_POWERMAP\($0)") }
        if map.count == 11 { laser.powerMap = map }
        profile.laser = laser

        var raw = values
        for (name, other) in sections where name != usedName {
            for (k, value) in other { raw["\(name).\(k)"] = value }
        }
        profile.raw = raw
        return profile
    }

    // MARK: Fill parameters

    /// Reads `fillPara.cfg` into fill settings (see `fillSettings(fromFillPara:)` for the key mapping).
    public static func fillSettings(fromFillPara url: URL) throws -> FillSettings {
        try fillSettings(fromFillPara: parse(url: url))
    }

    /// Maps the `[FILLED_PARS]` section (keys suffixed `_0`…`_3`, one per hatch layer) to `FillSettings`.
    ///
    /// Mapping (field meanings inferred from the vendor UI strings and SDK structures):
    /// `bEnable` → isEnabled, `fAngle` → angle, `fLineSpacing` → spacing, `CrossFill` → crossHatch,
    /// `fMargin` → borderOffset (the SDK insets the outline by this distance), `fStartPreserve` / `fEndPreserve`
    /// → startOffset / endOffset ("Start/End Offset"), `bArrangeEqually` → evenDistribution ("Evenly Distributed
    /// Fill Line"), `m_fill_rotate` + `m_fRotateAngle` → autoRotateAngle, `nPenNum` → penID (0 → nil, i.e. the
    /// object's pen); global `bOutLine` → markOutline, `bOutLineFirst` → outlineFirst.
    /// Not mapped: `nFillType` / `nExecuteType` (one of them selects the SDK's concentric "circular" fill when 0,
    /// which one could not be confirmed, so the pattern stays `.lines`), `AlongBorder` ("walk around"),
    /// `nMarkCount`, `QuickFill`, `bWholeConsider`, `bRoundInvert` (ring order), `nCircularCount`,
    /// `fCircularGap`, `fInnerSpacing`, `cPenColor`, `nIndex`.
    /// Missing keys keep the `HatchLayer` / `FillSettings` defaults.
    public static func fillSettings(fromFillPara sections: [String: [String: String]]) throws -> FillSettings {
        guard let values = section("FILLED_PARS", in: sections) else { throw VendorConfigError.missingSection("FILLED_PARS") }
        let v = Values(values)
        var settings = FillSettings()
        v.bool("bOutLine") { settings.markOutline = $0 }
        v.bool("bOutLineFirst") { settings.outlineFirst = $0 }
        var layers: [HatchLayer] = []
        for i in 0..<4 {
            var layer = HatchLayer()
            if i > 0 { layer.isEnabled = false }
            v.bool("bEnable_\(i)") { layer.isEnabled = $0 }
            v.double("fAngle_\(i)") { layer.angle = $0 }
            v.double("fLineSpacing_\(i)") { if $0 > 0 { layer.spacing = $0 } }
            v.bool("CrossFill_\(i)") { layer.crossHatch = $0 }
            v.double("fMargin_\(i)") { layer.borderOffset = $0 }
            v.double("fStartPreserve_\(i)") { layer.startOffset = $0 }
            v.double("fEndPreserve_\(i)") { layer.endOffset = $0 }
            v.bool("bArrangeEqually_\(i)") { layer.evenDistribution = $0 }
            if v.number("m_fill_rotate_\(i)").map({ $0 != 0 }) ?? false {
                layer.autoRotateAngle = v.number("m_fRotateAngle_\(i)") ?? 0
            }
            v.int("nPenNum_\(i)") { layer.penID = $0 > 0 ? $0 : nil }
            layers.append(layer)
        }
        settings.layers = layers
        return settings
    }

    // MARK: Helpers

    static func section(_ name: String, in sections: [String: [String: String]]) -> [String: String]? {
        sections[name] ?? sections.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Case-insensitive typed accessors over one section.
    struct Values {
        let exact: [String: String]
        let folded: [String: String]

        init(_ values: [String: String]) {
            exact = values
            var f: [String: String] = [:]
            for (k, v) in values { f[k.lowercased()] = v }
            folded = f
        }

        subscript(key: String) -> String? { exact[key] ?? folded[key.lowercased()] }

        func number(_ key: String) -> Double? {
            guard let s = self[key], let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
            return d
        }

        func double(_ key: String, _ apply: (Double) -> Void) { if let d = number(key) { apply(d) } }
        func int(_ key: String, _ apply: (Int) -> Void) { if let d = number(key) { apply(Int(d)) } }
        func bool(_ key: String, _ apply: (Bool) -> Void) { if let d = number(key) { apply(d != 0) } }
    }
}
