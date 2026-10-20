#!/usr/bin/env bash
# Builds "MR Carve.app" into ./build using SwiftPM only (no Xcode required).
# Usage: scripts/build-app.sh [debug|release] [--icon]
#   --icon          regenerate Sources/MRCarveApp/Resources/AppIcon.icns (also done when it is missing)
#   SCRATCH_PATH    optional SwiftPM scratch directory (default: .build)
set -euo pipefail

CONFIG="release"
REGEN_ICON=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --icon) REGEN_ICON=1 ;;
        *) echo "usage: $0 [debug|release] [--icon]" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MR Carve.app"
SCRATCH="${SCRATCH_PATH:-$ROOT/.build}"
ICON="$ROOT/Sources/MRCarveApp/Resources/AppIcon.icns"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1.0)"
case "$VERSION" in [0-9v]*.*) ;; *) VERSION="0.1.0" ;; esac

# --- App icon -------------------------------------------------------------------------------
# Drawn with CoreGraphics by a small Swift script, then packed with iconutil.
make_icon() {
    local work
    work="$(mktemp -d)"
    cat > "$work/icon.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    let space = CGColorSpaceCreateDeviceRGB()

    // Squircle body with a soft drop shadow (macOS icon grid: 824 pt body in a 1024 canvas).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0x10131A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x2A3242), color(0x0D1016)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Metal workpiece.
    let plate = CGRect(x: 262, y: 190, width: 500, height: 500)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.55))
    ctx.addPath(platePath); ctx.setFillColor(color(0xB8BEC7)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(platePath); ctx.clip()
    let metal = CGGradient(colorsSpace: space, colors: [color(0xEEF1F5), color(0xA9B0BA), color(0xD5DAE1)] as CFArray,
                           locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    // Brushed texture.
    ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(2)
    var y = plate.minY + 6
    while y < plate.maxY { ctx.move(to: CGPoint(x: plate.minX, y: y)); ctx.addLine(to: CGPoint(x: plate.maxX, y: y)); y += 9 }
    ctx.strokePath()

    // Engraved hatch disc, partially done (lines up to the laser spot).
    let center = CGPoint(x: 512, y: 440), radius: CGFloat = 170
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)); ctx.clip()
    ctx.setStrokeColor(color(0x1E232B, 0.92)); ctx.setLineWidth(9); ctx.setLineCap(.round)
    var hy = center.y - radius
    let spotY = center.y + 92
    while hy < spotY { ctx.move(to: CGPoint(x: center.x - radius, y: hy)); ctx.addLine(to: CGPoint(x: center.x + radius, y: hy)); hy += 17 }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.setStrokeColor(color(0x1E232B, 0.95)); ctx.setLineWidth(8); ctx.strokePath()
    ctx.restoreGState()

    // Red-pointer framing brackets.
    ctx.setStrokeColor(color(0xFF5B4A, 0.9)); ctx.setLineWidth(10); ctx.setLineCap(.round)
    let f = plate.insetBy(dx: -34, dy: -34), l: CGFloat = 70
    for (p, dx, dy) in [(CGPoint(x: f.minX, y: f.minY), 1.0, 1.0), (CGPoint(x: f.maxX, y: f.minY), -1.0, 1.0),
                        (CGPoint(x: f.maxX, y: f.maxY), -1.0, -1.0), (CGPoint(x: f.minX, y: f.maxY), 1.0, -1.0)] {
        ctx.move(to: CGPoint(x: p.x + dx * l, y: p.y)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x, y: p.y + dy * l))
    }
    ctx.strokePath()

    // Laser beam from the galvo head to the spot, with glow.
    let spot = CGPoint(x: center.x + 118, y: spotY)
    let head = CGPoint(x: 512, y: 960)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0xFF7A2E, 1))
    ctx.setStrokeColor(color(0xFF7A2E, 0.85)); ctx.setLineWidth(22); ctx.setLineCap(.round)
    ctx.move(to: head); ctx.addLine(to: spot); ctx.strokePath()
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFF4D6)); ctx.setLineWidth(7)
    ctx.move(to: head); ctx.addLine(to: spot); ctx.strokePath()

    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xFFB347, 0.95), color(0xFF5A1F, 0)] as CFArray,
                          locations: [0, 0.25, 1])!
    ctx.drawRadialGradient(glow, startCenter: spot, startRadius: 0, endCenter: spot, endRadius: 95, options: [])
    ctx.restoreGState()

    // Subtle top highlight on the body.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let shine = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        draw(ctx, size: CGFloat(px))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
SWIFT
    mkdir -p "$work/AppIcon.iconset"
    swift "$work/icon.swift" "$work/AppIcon.iconset"
    iconutil -c icns "$work/AppIcon.iconset" -o "$ICON"
    rm -rf "$work"
    echo "Icon: $ICON"
}

if [ "$REGEN_ICON" = 1 ] || [ ! -f "$ICON" ]; then
    make_icon
fi

# --- Build ----------------------------------------------------------------------------------
cd "$ROOT"
swift build -c "$CONFIG" --product MRCarveApp --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MRCarveApp" "$APP/Contents/MacOS/MRCarve"

# SwiftPM resource bundle (localizations, icon). The app looks for it in Contents/Resources (see Bundle.app).
if [ -d "$BIN_DIR/MRCarve_MRCarveApp.bundle" ]; then
    cp -R "$BIN_DIR/MRCarve_MRCarveApp.bundle" "$APP/Contents/Resources/"
fi
# Declare the localizations in the main bundle too, so AppKit localizes system menus and panels.
for lproj in "$ROOT"/Sources/MRCarveApp/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MR Carve</string>
    <key>CFBundleDisplayName</key><string>MR Carve</string>
    <key>CFBundleIdentifier</key><string>com.onigam.mrcarve</string>
    <key>CFBundleExecutable</key><string>MRCarve</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
    <key>CFBundleVersion</key><string>${VERSION#v}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>MR Carve Project</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.onigam.mrcarve.project</string></array>
            <key>CFBundleTypeIconFile</key><string>AppIcon</string>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.onigam.mrcarve.project</string>
            <key>UTTypeDescription</key><string>MR Carve Project</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeIconFile</key><string>AppIcon</string>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>mrcarve</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP"
