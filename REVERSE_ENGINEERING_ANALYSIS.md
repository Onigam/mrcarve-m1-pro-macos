> **Superseded (2026-10).** Early planning notes, kept for history. Several assumptions here turned out wrong
> (e.g. the logs contain no USB traces; the Android app talks USB through libusb). Current, verified
> information: [README.md](README.md) and [docs/PROTOCOL.md](docs/PROTOCOL.md).

# Reverse Engineering Analysis - MR Carve M1 Pro

## 1. Windows Software Architecture

### 1.1 Application Identity

| Field | Value |
|---|---|
| **Executable** | `MR CARVE.exe` (1.9 MB, 32-bit MFC application) |
| **Internal Name** | BSL激光打标系统 (BSL Laser Marking System) |
| **Version** | 5.2.2.2373 |
| **Developer** | Changsha Basiliang Information Technology Co., Ltd. |
| **Build Path** | `E:\bslapp\5.2.simple.AiDiDa\Release\` |
| **Framework** | MFC (mfc100u.dll, msvcr100.dll, msvcp100.dll) |
| **Crash Handler** | CrashRpt 1.4.03 |

### 1.2 Module Architecture (DLL Map)

The application follows a modular plugin architecture with clearly separated concerns:

```
MR CARVE.exe          Main MFC application shell
├── SeaBase.dll       Base library (1.2 MB) - core data types, file I/O, config parsing
├── SeaMark.dll       Mark engine (741 KB) - galvo control, mark execution, laser timing
├── SeaDraw.dll       Drawing engine (1.8 MB) - vector/raster graphics, shape primitives
├── SeaCali.dll       Calibration (458 KB) - field lens correction, .cor file handling
├── SeaExts.dll       Extensions (877 KB) - extended features (fly marking, rotary axis)
├── SeaUI.dll         UI framework - MFC dialog/view management
├── SeaUsb.lib        USB communication layer (static lib linked into SeaMark)
├── MarkUI.dll        Mark control UI (606 KB) - mark panel, progress, I/O display
├── ParaUI.dll        Parameter UI (968 KB) - laser params, pen settings, system config
├── DrawUI.dll        Drawing UI (1.7 MB) - canvas, object list, property panels
├── calib.dll         Additional calibration utilities
├── libcodebar.dll    Barcode generation (673 KB) - 1D/2D barcode support
├── LPCodeAddin.dll   Barcode addon (253 KB)
├── crypto3.dll       Encryption/license (179 KB)
├── crypto5.0.dll     Encryption v5 (22 KB)
├── crypto6.0.dll     Encryption v6 (23 KB)
└── dbghelp.dll       Debug helper for crash reporting
```

### 1.3 File Formats

| Format | Extension | Purpose |
|---|---|---|
| **Project File** | `.orzx`, `.orz` | Proprietary project format containing shapes, parameters, layers |
| **Calibration File** | `.cor` | Field lens distortion correction table (`sea.cor`) |
| **Configuration** | `.cfg` | INI-style config files for all parameters |
| **Config Library** | `.lib` | Serialized dialog parameter presets (`dlgInit_para.lib`) |
| **Vector Fonts** | `.shx` | AutoCAD-compatible single-line fonts for engraving |
| **Localization** | `.ini` | Language strings (17 languages supported) |

---

## 2. USB Communication Protocol

### 2.1 Hardware Interface

The M1 Pro uses a **Cypress FX2LP** (CY7C68013A) USB microcontroller as the bridge between the host PC and the laser control FPGA board.

| Parameter | Value |
|---|---|
| **USB VID** | `0x04B4` (Cypress Semiconductor) |
| **USB PID** | `0x1004` (FX2LP Sample Device) |
| **USB Speed** | USB 2.0 High Speed (480 Mbps) |
| **Transfer Type** | Bulk Transfer |
| **Windows Driver** | `CYUSB3.sys` v1.2.3.10 (Cypress Generic USB Driver) |
| **Driver GUID** | `{AE18AA60-7F6A-11d4-97DD-00010229B959}` |
| **Max Transfer Size** | 4096 bytes (from registry config) |

### 2.2 Communication Flow (from Log Analysis)

The logs reveal the following USB communication sequence:

```
1. STARTUP
   corfile=<path>/sea.cor                              # Load calibration file
   CExecutor::GetDevPathMap size=N                      # Enumerate USB devices
   CExecutor::GetDevPathMap try open index=0            # Try opening first device
   CExecutor::GetDevPathMap index=0 vid=4B4, pid=1004  # Verify VID/PID
   UsbComm::OpenUsbDev:: 0                             # Open USB device (success=0)

2. INITIALIZATION
   GetSSVersion FPGA:1.6.0.8                           # Query firmware version
   WriteCMD -> WaitForXfer -> FinishDataXfer            # Send init commands
   (Multiple WriteCMD cycles at ~200ms intervals)       # Configuration upload

3. OPERATION
   WriteCMD sequences for:
   - Laser parameter upload (power, speed, frequency)
   - Mark data transfer (vector coordinates, fill patterns)
   - Red light preview commands
   - I/O port control
   - Galvanometer position commands

4. SHUTDOWN
   CMarkAdaptor::CloseExecutor:: 0                     # Stop mark engine
   UsbComm::CloseUsbDev 0                              # Close USB device
```

### 2.3 Key Protocol Methods (from DLL exports and logs)

| Method | Purpose |
|---|---|
| `UsbComm::OpenUsbDev` | Open USB connection to device |
| `UsbComm::CloseUsbDev` | Close USB connection |
| `WriteCMD` | Send command to FPGA via USB bulk write |
| `WaitForXfer` | Wait for USB transfer completion |
| `FinishDataXfer` | Complete async USB transfer |
| `GetSSVersion` | Query FPGA firmware version |
| `CExecutor::GetDevPathMap` | Enumerate connected USB devices |
| `CMarkAdaptor::CloseExecutor` | Shutdown mark execution engine |

### 2.4 Error States

From logs, the Chinese error message `板卡异常,初始化时仍然处于工厂模式 uMode=0` translates to:
> "Board abnormal, still in factory mode during initialization uMode=0"

This indicates the FPGA board has operating modes (factory vs. normal) and requires a mode switch command during initialization.

---

## 3. Laser Control Parameters

### 3.1 Galvanometer / Lens Configuration (`LmcPar_Fiber.cfg`)

| Parameter | Value | Description |
|---|---|---|
| `LEN_WORKSIZE` | 70.0 | Work area size (mm) |
| `LEN_SCALEX` | 64.407 | X-axis DAC-to-mm scale factor |
| `LEN_SCALEY` | 64.424 | Y-axis DAC-to-mm scale factor |
| `LEN_BUCKETX` | 1.038 | X barrel distortion correction |
| `LEN_BUCKETY` | 0.958 | Y barrel distortion correction |
| `LEN_TRAPEX` | 0.997 | X trapezoidal correction |
| `LEN_TRAPEY` | 0.999 | Y trapezoidal correction |
| `LEN_FIELDOFFSETX` | 0.0 | Field offset X (mm) |
| `LEN_FIELDOFFSETY` | 0.0 | Field offset Y (mm) |
| `LEN_ROTATEANGLE` | 0.0 | Rotation correction (degrees) |
| `LEN_XINVERT` | 0 | X-axis inversion flag |
| `LEN_YINVERT` | 0 | Y-axis inversion flag |
| `LEN_XYFLIP` | 0 | XY axis swap flag |
| `LEN_LINECOUNT` | 25 | Calibration grid line count (25x25) |
| `LEN_MAXSPEED` | 10000 | Maximum galvo speed (mm/s) |
| `LEN_MINSPEED` | 1 | Minimum galvo speed (mm/s) |
| `LEN_ENABLECORFILE` | 0 | Use external .cor correction file |

### 3.2 Laser Source Configuration

| Parameter | Value | Description |
|---|---|---|
| `LASERTYPE` | 0 | Laser type (0=fiber) |
| `FIBERTYPE` | 0 | Fiber sub-type |
| `OPC_FPK` | 1 | First Pulse Killer enabled |
| `OPC_FPKTIME` | 20 | FPK time (μs) |
| `OPC_ENPWMOUT` | 1 | PWM output enabled |
| `OPC_ENPOWERANALOGOUT` | 1 | Analog power output enabled |
| `OPC_MINPWMFREQ` | 20000 | Min PWM frequency (Hz) |
| `OPC_MAXPWMFREQ` | 200000 | Max PWM frequency (Hz) |
| `OPC_MAXQPW` | 200 | Max Q-switch pulse width (μs) |
| `OPC_MINQPW` | 0 | Min Q-switch pulse width (μs) |
| `STARTPOWER` | 0.1 | Start power (%) |
| `ENDPOWER` | 100 | End power (%) |
| `STARTLENGTH` | 0.5 | Start length for power ramp (mm) |
| `ENDLENGTH` | 0.5 | End length for power ramp (mm) |

### 3.3 Red Light Preview

| Parameter | Value | Description |
|---|---|---|
| `REDLIGHTSPEED` | 7000 | Red light preview speed (mm/s) |
| `REDLIGHTOFFSETX` | 0.21 | Red-to-laser X offset (mm) |
| `REDLIGHTOFFSETY` | 0.1 | Red-to-laser Y offset (mm) |
| `REDLIGHTSCALEX` | 1.01 | Red light X scale correction |
| `REDLIGHTSCALEY` | 1.01 | Red light Y scale correction |
| `REDLIGHTOUTPORT` | 0 | Red light output port |
| `REDCONTMODE` | 0 | Red light control mode |

### 3.4 Extended Axis (Rotary)

| Parameter | Value | Description |
|---|---|---|
| `EAX_ENABLE0` | 0 | Extended axis 0 enabled |
| `EAX_PPR0` | 40000 | Pulses per revolution |
| `EAX_MAXPPS0` | 32500 | Max pulses per second |
| `EAX_RUNPPS0` | 3200 | Run speed (pps) |
| `EAX_STTPPS0` | 100 | Start speed (pps) |
| `EAX_ACCTIME0` | 255 | Acceleration time (ms) |
| `EAX_ROTAXIS0` | 1 | Rotation axis ID |
| `EAX_DIR0` | 0 | Direction |
| `EAX_ZEROTYPE0` | 2 | Zero/home type |
| `EAX_LPR0` | 5.0 | Length per revolution (mm) |

### 3.5 Fill Parameters (`fillPara.cfg`)

4 fill layers supported, each with:
- Fill type (0=none, 1=line, 4=other)
- Line spacing (0.05-0.06 mm)
- Fill angle (0-360°)
- Cross-fill option
- Along-border option
- Margin, start/end preserve distances

---

## 4. Android App Analysis

| Field | Value |
|---|---|
| **APK** | `ADDApp_1.7.21.apk` (140 MB) |
| **Communication** | Likely WiFi/Bluetooth (the M1 Pro has wireless connectivity for the app) |
| **Potential Value** | APK can be decompiled with `jadx` to extract protocol logic, especially useful since Java/Kotlin code is more readable than x86 disassembly |

---

## 5. Tool2 Sub-Application (RangeFind)

A Qt 5-based autofocus/rangefinding application:

| Component | DLL | Purpose |
|---|---|---|
| **Qt Framework** | Qt5Core/Gui/Widgets/Network/Multimedia/SerialPort | App framework |
| **OpenCV** | opencv_world320.dll | Camera image processing |
| **Serial Port** | SerialPortDLL.dll | Motor/laser rangefinder control |
| **Camera** | UsbCamera.dll | USB camera capture |
| **Image Processing** | ImageProcessing.dll | Focus detection algorithms |
| **Scanner** | ScannerDll.dll | Galvo scanner control |
| **Laser Ranging** | LaserRanging.dll | Distance measurement |

Configuration shows serial port communication (COM4), camera-based autofocus at 20 FPS, with motor speed calibration data.

---

## 6. macOS Compatibility Assessment

### 6.1 USB Access on macOS

The Cypress FX2LP is **well-supported on macOS** without a custom kernel driver:

- **IOKit/IOUSBHost** framework provides direct USB access
- **libusb** (cross-platform) works natively on macOS
- The FX2LP uses standard USB bulk transfers — no proprietary driver needed
- Apple's USB stack natively recognizes Cypress devices

### 6.2 Key Challenges

1. **Protocol Reverse Engineering**: The exact binary command format sent via `WriteCMD` is not yet documented. This requires either:
   - USB traffic capture (using Wireshark + USBPcap on Windows)
   - Static analysis of `SeaMark.dll` / `SeaUsb.lib` with Ghidra/IDA
   - Dynamic analysis of the Android APK (easier to decompile)

2. **Calibration Data**: The `.cor` correction file format needs to be reverse-engineered. It likely contains a lookup table mapping ideal XY coordinates to corrected galvo DAC values.

3. **File Format**: The `.orzx` project file format is proprietary but the config files are plain-text INI format, so much of the parameter handling is straightforward.

4. **FPGA Firmware**: The device contains an FPGA (v1.6.0.8) that interprets commands. Understanding its command set is the critical path item.

### 6.3 Reverse Engineering Priority

| Priority | Target | Method | Difficulty |
|---|---|---|---|
| **P0** | USB command protocol | USB capture + APK decompile + DLL disassembly | High |
| **P1** | Android APK protocol code | jadx decompilation | Medium |
| **P2** | `.cor` calibration format | Binary analysis + config cross-reference | Medium |
| **P3** | `.orzx` project file format | Binary analysis | Low (can use own format) |
| **P4** | SeaMark.dll galvo math | Ghidra disassembly | Medium |
