# MR Carve for macOS

A native macOS app (Swift / SwiftUI + AppKit) to design and engrave with the **MR Carve M1 Pro** galvo laser
engraver over USB. The vendor ships only a Windows MFC application ("MR CARVE" 5.2.2, BSL / SeaCAD
controller software) and an Android app; this project replaces them on the Mac with a modern UI.

> **Status — work in progress.** The app, the engraving engine and the simulator are complete. Talking to
> the real machine is being brought up step by step: USB enumeration and the first read-only exchange
> with the board are verified on hardware; red-pointer framing and marking are **disabled** on the real
> device until the remaining commands are verified. See [docs/PROTOCOL.md](docs/PROTOCOL.md) §8.

## Features

- **Design canvas** — 70 × 70 mm field, grid and rulers, move / scale / rotate handles, zoom and pan,
  snapping, undo/redo, copy/paste, drag & drop.
- **Objects** — text (any installed font), rectangle, ellipse, polygon / star, line, imported vectors
  (SVG, DXF, PLT/HPGL) and bitmaps (PNG, JPEG, TIFF, HEIC).
- **Fill** — up to 4 hatch layers per object (angle, spacing, cross-hatch, bidirectional, border inset,
  concentric mode); imports the vendor `fillPara.cfg`.
- **Bitmaps** — threshold, Floyd–Steinberg, Jarvis, Stucki, Atkinson and ordered dithering with live preview.
- **Pens** — 16 pens with speed, power, frequency, pulse width, loops and delays; material presets.
- **Machine profiles** — imports the vendor `LmcPar_Fiber.cfg` / `LmcPar_Blue.cfg` (lens calibration,
  red-pointer offsets, laser source limits).
- **Laser workflow** — red-light framing (F1), mark (F2) with progress, stop (Esc), safety checklist.
  A built-in simulator lets you use everything without the machine.
- English and French UI.

## Build and run

Requirements: macOS 15+, Apple Silicon, Xcode **Command Line Tools** (full Xcode not needed), and libusb:

```bash
brew install libusb
```

Build the app bundle (`build/MR Carve.app`, libusb linked statically, ad-hoc signed):

```bash
scripts/build-app.sh release
```

```bash
open "build/MR Carve.app"
```

Run the tests (a plain executable, since SwiftPM cannot run XCTest without full Xcode):

```bash
swift run mrcarve-tests
```

Hardware diagnostics (`list` and `dryrun` never send anything to the machine; read [docs/PROTOCOL.md](docs/PROTOCOL.md)
before using any `--live` option):

```bash
swift run mrcarve-cli list -v
```

## Hardware

| | |
|---|---|
| USB bridge | Cypress FX2LP, `04B4:1004`, manufacturer "SEATHINKING", USB 2.0 high speed, firmware in EEPROM |
| Interface | 0, vendor class `0xFF`; bulk EP `0x06` OUT / `0x88` IN (commands), `0x02` OUT / `0x84` IN (data) |
| Board | BSL controller, FPGA 1.6.0.8, legacy 12-byte command protocol |
| Field | 70 × 70 mm |

No driver or kernel extension is needed on macOS: the app talks to the device through libusb.

## Repository layout

```
Sources/MRCarveKit/        Core library
  Core/                    Shared types (mm geometry, pens, mark jobs, machine profile)
  Engine/                  Text outlines, hatch & concentric fill, path ordering, SVG/DXF/PLT import, dithering
  Config/                  Vendor .cfg parser (LmcPar_*.cfg, fillPara.cfg)
  Model/                   Project document, design objects, job compiler, preset libraries
  Protocol/                Board command encoding (legacy + framed), galvo transform, pen conversion
  Device/                  LaserController API, USB controller (libusb), simulator, transports
Sources/MRCarveApp/        SwiftUI / AppKit application
Sources/mrcarve-cli/       Bring-up & diagnostics tool
Tests/MRCarveKitTests/     Test suites (`swift run mrcarve-tests`)
docs/PROTOCOL.md           Reverse-engineered device protocol and hardware bring-up checklist
re/                        Reverse-engineering notes and Ghidra scripts (vendor binaries and decompiler
                           output are kept out of the repository)
```

## Safety

This software drives a class 4 laser. Wear eye protection rated for your laser source, keep the enclosure
closed, never leave a job unattended, and keep a hand near the power switch while testing.

## Disclaimer

Independent interoperability project, not affiliated with MR Carve or the controller manufacturer. The
vendor software and binaries are not included in this repository.
