> **Superseded (2026-10).** Early planning notes, kept for history. Several assumptions here turned out wrong
> (e.g. the logs contain no USB traces; the Android app talks USB through libusb). Current, verified
> information: [README.md](README.md) and [docs/PROTOCOL.md](docs/PROTOCOL.md).

# Implementation Plan - MR Carve M1 Pro macOS Controller

## Architecture Overview

```
┌──────────────────────────────────────────────────────┐
│                    SwiftUI App                        │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │ Canvas   │  │ Mark     │  │ Parameter          │ │
│  │ View     │  │ Control  │  │ Panel              │ │
│  └────┬─────┘  └────┬─────┘  └────────┬───────────┘ │
│       │              │                 │              │
│  ┌────┴──────────────┴─────────────────┴───────────┐ │
│  │              Document Model                      │ │
│  │  (Shapes, Layers, Pens, Fill, Parameters)        │ │
│  └──────────────────────┬──────────────────────────┘ │
│                         │                             │
│  ┌──────────────────────┴──────────────────────────┐ │
│  │            Mark Engine (Swift)                    │ │
│  │  - Vector → galvo coordinate conversion          │ │
│  │  - Fill pattern generation                       │ │
│  │  - Path optimization                             │ │
│  │  - Timing/delay calculation                      │ │
│  │  - Calibration correction (.cor)                 │ │
│  └──────────────────────┬──────────────────────────┘ │
│                         │                             │
│  ┌──────────────────────┴──────────────────────────┐ │
│  │          USB Communication Layer                  │ │
│  │  - Cypress FX2LP device enumeration              │ │
│  │  - Bulk transfer command protocol                │ │
│  │  - FPGA command serialization                    │ │
│  │  - Device status monitoring                      │ │
│  └──────────────────────────────────────────────────┘ │
│                         │                             │
└─────────────────────────┼─────────────────────────────┘
                          │ USB Bulk Transfer
                    ┌─────┴─────┐
                    │ FX2LP     │
                    │ VID:04B4  │
                    │ PID:1004  │
                    └─────┬─────┘
                          │
                    ┌─────┴─────┐
                    │ FPGA      │
                    │ v1.6.0.8  │
                    └─────┬─────┘
                          │
              ┌───────────┼───────────┐
              │           │           │
         ┌────┴────┐ ┌───┴───┐ ┌────┴────┐
         │ X Galvo │ │Laser  │ │ Y Galvo │
         │ Mirror  │ │Source │ │ Mirror  │
         └─────────┘ └───────┘ └─────────┘
```

## Technology Stack

| Layer | Technology | Rationale |
|---|---|---|
| **UI** | SwiftUI + AppKit | Native macOS look, performant canvas via Metal |
| **Canvas Rendering** | Metal / Core Graphics | Hardware-accelerated 2D rendering for design view |
| **USB Communication** | IOKit (IOUSBHost) | Native macOS USB framework, no kernel extension needed |
| **Image Processing** | Core Image + vImage | Bitmap-to-engrave conversion (grayscale, dithering) |
| **Vector Graphics** | Core Graphics + custom SVG/DXF parser | Import PLT, DXF, AI, SVG files |
| **File Format** | Codable JSON/binary | Native project format (with .orzx import if needed) |
| **Barcode** | CIFilter (Core Image) | QR/barcode generation |
| **Build System** | Xcode / Swift Package Manager | Standard Apple toolchain |
| **Min Deployment** | macOS 13 Ventura | IOUSBHost API stability |

---

## Phase 0: Protocol Reverse Engineering

**Goal**: Fully document the USB command protocol between `MR CARVE.exe` and the FPGA board.

### Tasks

#### 0.1 Android APK Decompilation
- Decompile `ADDApp_1.7.21.apk` using `jadx`
- Extract USB/WiFi/Bluetooth protocol classes
- Document command structures, opcodes, and data framing
- The APK is the **easiest source** for protocol details since Java/Kotlin decompiles cleanly

#### 0.2 USB Traffic Capture (Windows)
- Set up USBPcap + Wireshark on a Windows machine with the M1 Pro connected
- Capture full sessions: startup, red light, simple mark, shutdown
- Parse captured packets to identify command structures
- Correlate with log file timestamps

#### 0.3 DLL Static Analysis
- Load `SeaMark.dll` and `SeaUsb.lib` into Ghidra
- Identify `WriteCMD` function signature and calling convention
- Trace command construction for key operations
- Document the binary protocol format

#### 0.4 Calibration File Analysis
- Binary-analyze `sea.cor` to determine format
- Cross-reference with `LEN_*` config parameters
- Build a parser for the correction lookup table

### Deliverable
A complete **Protocol Specification Document** with:
- USB endpoint configuration
- Command frame format (header, opcode, payload, checksum)
- Full opcode table
- Galvanometer coordinate system mapping
- Initialization sequence
- Mark data transfer format

---

## Phase 1: USB Foundation

**Goal**: Establish reliable USB communication with the M1 Pro from macOS.

### Tasks

#### 1.1 Device Discovery & Connection
- Implement FX2LP device enumeration via IOKit
- Handle USB device attach/detach notifications
- Open device, claim interface, configure endpoints
- Verify with firmware version query (`GetSSVersion`)

#### 1.2 Command Protocol Implementation
- Implement command framing (serialize/deserialize)
- Implement bulk write/read with proper async handling
- Build the initialization sequence
- Implement device mode detection (factory vs. normal)

#### 1.3 Basic Device Control
- Red light on/off
- Laser test pulse
- Galvanometer position command (move to XY)
- I/O port read/write
- Extended axis control (rotary motor)

### Deliverable
A Swift package `MRCarveUSB` that provides:
```swift
class MRCarveDevice {
    func connect() async throws
    func disconnect()
    func getFirmwareVersion() async throws -> String
    func redLightPreview(path: [CGPoint]) async throws
    func moveTo(x: Double, y: Double) async throws
    func testLaser(power: Double, duration: TimeInterval) async throws
}
```

---

## Phase 2: Mark Engine

**Goal**: Convert 2D design data into galvanometer commands.

### Tasks

#### 2.1 Coordinate System
- Implement work area coordinate system (70x70mm, origin-centered)
- Implement DAC coordinate conversion using `LEN_SCALEX/Y` factors
- Apply barrel/trapezoidal distortion correction
- Apply rotation and offset corrections
- Implement `.cor` file calibration grid interpolation

#### 2.2 Vector Path Processing
- Polyline to galvo command sequence conversion
- Arc tolerance segmentation (`ARCTOL` parameter)
- Path optimization (minimize laser-off travel distance)
- Jump delay, mark delay, polygon delay calculation

#### 2.3 Fill Pattern Engine
- Line fill with configurable angle and spacing
- Cross-hatch fill
- Along-border fill
- Circular fill patterns
- Fill line sorting and optimization

#### 2.4 Raster/Bitmap Processing
- Grayscale conversion
- Dithering (Floyd-Steinberg, ordered)
- DPI-to-galvo resolution mapping
- Bidirectional scanning mode
- Power modulation per pixel

#### 2.5 Mark Execution
- Single mark execution with progress tracking
- Continuous mark mode
- Layer/pen-based parameter switching
- Power ramp at start/end of lines
- First Pulse Killer timing
- Abort/pause support

### Deliverable
A Swift package `MRCarveEngine` with:
```swift
class MarkEngine {
    func compile(document: Document, parameters: MarkParameters) -> MarkJob
    func execute(job: MarkJob, device: MRCarveDevice) async throws
    func redLightPreview(document: Document, device: MRCarveDevice) async throws
}
```

---

## Phase 3: macOS Application UI

**Goal**: Build the user-facing macOS application.

### Tasks

#### 3.1 Design Canvas
- Metal-backed 2D canvas with zoom/pan/rotate
- Grid, rulers, crosshair, work area boundary display
- Shape selection, move, resize, rotate handles
- Snap-to-grid, snap-to-object
- Undo/redo stack

#### 3.2 Shape Tools
- Rectangle, circle, polygon, line, polyline, arc
- Text tool with system fonts + SHX vector fonts
- Barcode generator (QR, Code128, DataMatrix, etc.)
- Node editing (Bezier curve manipulation)

#### 3.3 Import/Export
- Image import (PNG, JPG, BMP, TIFF) with processing dialog
- Vector import (SVG, DXF, PLT, AI)
- Project save/load (native format)
- Optional: .orzx import for compatibility

#### 3.4 Parameter Panel
- Pen/layer management (color-coded, up to 256 pens)
- Per-pen laser parameters: speed, power, frequency, Q-switch PW
- Fill settings dialog
- Mark configuration (delays, optimization, repeat count)

#### 3.5 Mark Control Panel
- Device connection status indicator
- Red light preview button (F1)
- Mark button (F2) with progress bar
- Parameter config button (F3)
- Total count / total time display
- Continuous mark toggle
- Emergency stop

#### 3.6 System Configuration
- Field lens calibration UI
- Galvo correction parameters
- Red light offset calibration
- Extended axis (rotary) configuration
- Language selection

### Deliverable
A complete macOS `.app` bundle ready for testing.

---

## Phase 4: Advanced Features

#### 4.1 Rotary Axis Support
- Ring marking mode (cylindrical objects)
- Rotation angle marking (flat objects on rotary)
- Auto-segmentation for curved surfaces
- Diameter/circumference input

#### 4.2 Array/Matrix Marking
- Rectangular array with configurable rows/columns/spacing
- Mark order optimization

#### 4.3 Serial Number / Variable Text
- Auto-incrementing serial numbers
- Date/time stamps
- CSV data import for batch marking

#### 4.4 Camera Preview (Future)
- USB camera integration for live work area view
- Image overlay for precise positioning

---

## Cursor Agent Architecture

Each implementation phase should be executed by specialized Cursor agents. Below is the recommended agent breakdown and the `.cursorrules` or prompt each should use.

### Agent 1: `protocol-reverse-engineer`

**Scope**: Phase 0 — APK decompilation, protocol documentation

**Prompt Context**:
> You are reverse engineering the USB communication protocol of the MR Carve M1 Pro laser engraver. The device uses a Cypress FX2LP USB controller (VID 0x04B4, PID 0x1004) communicating via USB bulk transfers to an FPGA (firmware v1.6.0.8). Your job is to:
> 1. Decompile the Android APK `ADDApp_1.7.21.apk` using jadx and find all USB/protocol-related classes
> 2. Document every command opcode, frame structure, and data format
> 3. Create a `docs/PROTOCOL.md` specification
> Reference: `REVERSE_ENGINEERING_ANALYSIS.md` for known parameters and log traces.

**Key Files**: `M1-pro-3.0-tomigrate/3、APP/`, all log files in `2、software/Log/`

---

### Agent 2: `usb-driver`

**Scope**: Phase 1 — Swift IOKit USB communication layer

**Prompt Context**:
> You are building a Swift USB communication layer for the MR Carve M1 Pro laser engraver on macOS. The device is a Cypress FX2LP (VID 0x04B4, PID 0x1004). Use Apple's IOKit/IOUSBHost framework for device discovery, connection, and bulk transfers. Implement the command protocol documented in `docs/PROTOCOL.md`. The package should be called `MRCarveUSB` and follow Swift concurrency patterns (async/await). Target macOS 13+.

**Key Files**: `docs/PROTOCOL.md`, `REVERSE_ENGINEERING_ANALYSIS.md`

---

### Agent 3: `mark-engine`

**Scope**: Phase 2 — Mark compilation and execution engine

**Prompt Context**:
> You are building the mark engine for a macOS laser engraver controller. This engine converts 2D vector/raster designs into galvanometer commands for a fiber laser. Key parameters: 70x70mm work area, galvo scale factors ~64.4 DAC/mm, 25x25 calibration grid, max speed 10000mm/s. Implement coordinate transformation (with barrel/trapezoid correction), fill pattern generation (line, cross-hatch, along-border), path optimization, raster-to-dot conversion, and mark job compilation. The package is `MRCarveEngine` in Swift. Reference the parameter configs in `REVERSE_ENGINEERING_ANALYSIS.md`.

**Key Files**: `REVERSE_ENGINEERING_ANALYSIS.md` (section 3), config files in `2、software/config/`

---

### Agent 4: `macos-app-ui`

**Scope**: Phase 3 — SwiftUI application

**Prompt Context**:
> You are building a native macOS application (SwiftUI + AppKit) for controlling the MR Carve M1 Pro laser engraver. The UI should be modern, professional, and follow macOS HIG. Key views: (1) Metal-backed 2D design canvas with shape tools, (2) object list sidebar, (3) property inspector, (4) mark control panel with device status. Reference the English language file `Lang/lang_en.ini` for feature naming and the operations manual for UX flow. Import `MRCarveUSB` and `MRCarveEngine` packages. Target macOS 13+ with SwiftUI.

**Key Files**: `Lang/lang_en.ini`, `4、Instruction Manual/`, `README.md`

---

### Agent 5: `advanced-features`

**Scope**: Phase 4 — Rotary axis, arrays, variable text

**Prompt Context**:
> You are adding advanced features to the MR Carve M1 Pro macOS controller: rotary axis marking (ring and angle modes), array/matrix marking, and variable text (serial numbers, date stamps, CSV import). Reference the rotary config sections `ROT_RINGMARK`, `ROT_TEXTMARK`, `ROTEXTMARK` in `REVERSE_ENGINEERING_ANALYSIS.md` for parameter ranges. Extend the existing `MRCarveEngine` and app UI.

**Key Files**: Config files (`DlgPar.cfg` sections), `REVERSE_ENGINEERING_ANALYSIS.md` (section 3.4)

---

## Execution Order & Dependencies

```
Phase 0 (Protocol RE)
    │
    ├──→ Phase 1 (USB Driver)     ←── depends on protocol spec
    │        │
    │        └──→ Phase 2 (Mark Engine)  ←── depends on USB layer
    │                  │
    │                  └──→ Phase 3 (App UI)  ←── depends on engine + USB
    │                            │
    │                            └──→ Phase 4 (Advanced)  ←── depends on everything
    │
    └──→ Phase 3 (App UI - can start canvas/import work in parallel)
```

**Parallelization**: Phase 3 canvas/import work can start alongside Phase 0-1 since it doesn't require USB connectivity.

---

## Risk Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Protocol cannot be fully reverse-engineered | Blocks all USB features | Prioritize APK decompilation (cleanest source); use USB capture as backup; community outreach to other M1 Pro owners |
| FPGA command set is encrypted/obfuscated | Blocks USB communication | Analyze `crypto*.dll` usage; check if commands are encrypted or just authenticated |
| macOS IOKit blocks FX2LP access | No USB on macOS | Fall back to `libusb` (which is well-tested with Cypress devices on macOS) |
| `.cor` calibration format undocumented | Reduced accuracy | Implement manual calibration UI as alternative; build own correction table |
| Performance: SwiftUI canvas too slow for complex designs | Poor UX for large files | Use Metal rendering for canvas; keep SwiftUI for panels only |

---

## Success Criteria

1. **Minimum Viable Product (MVP)**: Connect to M1 Pro via USB, send a simple text engrave job, execute it successfully
2. **Feature Parity**: Match 80% of the Windows software's daily-use features
3. **Stability**: No crashes during mark execution; safe abort at any time
4. **User Experience**: Native macOS feel; drag-and-drop import; responsive canvas
