# MR Carve M1 Pro — host→board control protocol

Reverse-engineered from the vendor core. Primary source: the Android ARM64 build
`re/out/libCoreSDK.so.c` (C++ names: `CCmdExecutor`, `CDGExecutor`, `DevComm`, `TransferCtrl`,
`LibUsbControl`, `CDevUtil`, `tagSeaCMD`). Cross-checked against the Windows x86 build
`re/out/SeaMark.dll.c` (`UsbComm`, `CDataTransmission`, `CMarkAdaptor`, `CController`) and the
higher-level `re/out/libSeaSDK.so.c` (`CParaMgr`, `CMarkAdaptor`, `CController`, parameter loaders).

Addresses are Ghidra addresses. For the ARM64 ELF, ELF virtual address = Ghidra address − 0x100000
(e.g. Ghidra `0x12ae94` = ELF `0x2ae94`); the `llvm-objdump` commands in this repo use the ELF address.

Every claim is tagged **confirmed** (byte layout read directly from code), **inferred** (derived from
consistent usage), or **unverified** (plausible but not proven — validate on hardware).

> **Board-side handshake — flag for the owner (out of scope to implement).** The vendor init path
> (`CCmdExecutor::Initialize` @0x12ae94, Windows `FUN_10066a70` @0x10066a70) does more than read the
> version: it runs a **GetBoardMode** exchange (opcode `0x0140` legacy / `0xFFF1` new) in a retry loop and,
> if the board is still in **factory mode**, sends a mode command (`FUN_1006da50` builds it) and waits.
> The vendor logs `"board still in factory mode uMode=0"` (`板卡异常,初始化时仍然处于工厂模式 uMode=%d`)
> when this fails. There is also a `bind`/`EncryptTest` step (opcode `0xF0FA` plus a crypto exchange with
> `libcrypto6.0`), which is **licensing/registration and explicitly out of scope** — not analysed here.
> This port's `connect()` performs **neither** handshake; it only reads version and status. If the board
> refuses data/motion commands until a mode switch or bind has happened, that must be designed with the
> owner before `frame`/`mark` can work. See "Open questions".

---

## 1. Transport

**Device:** Cypress FX2LP, VID `0x04B4` / PID `0x1004`, USB 2.0 high speed, interface 0. The firmware-less
FX2 appears as `0x04B4:0x8613` (needs firmware upload — not handled here). confirmed (`DevComm::GetDeviceList`
@0x16a700 matches `0x4b4`/`0x1004`; Windows `UsbComm::OpenUsbDev` checks the same).

**Bulk endpoints** (confirmed, `LibUsbControl` @0x1688d8–0x168e5c; Windows config endpoints agree):

| Endpoint | Dir | Use | Vendor call |
|---|---|---|---|
| `0x06` | OUT | **commands** (queries, state changes) | `WriteCMDBuf` → `libusb_bulk_transfer(…,6,…)` |
| `0x02` | OUT | **data** (geometry, batched command lists) | `WriteDataBuf` → `…,2,…` (refuses < 12 bytes) |
| `0x88` | IN | command reply | `ReadCmdBuf` → `ReadPort(0,…)` |
| `0x84` | IN | data reply / status | `ReadDataBuf` → `ReadPort(1,…)` |

Timeout **100 ms**; reply read length **0x50 = 80 bytes**. confirmed.

**Confirmed on the owner's machine** (read-only descriptor dump via `mrcarve-cli list -v` + `ioreg`;
nothing was sent to the device):

| field | value |
|---|---|
| VID:PID | `04B4:1004` (firmware already loaded — not the bare-FX2 `8613`) |
| manufacturer | `SEATHINKING` |
| bcdDevice | `0x0000` |
| speed | high speed, 480 Mb/s |
| interface | 0, alt 0, class `0xFF` (vendor-specific) |
| endpoints | 4 × bulk, `wMaxPacketSize` 512: OUT `0x02`, IN `0x84`, OUT `0x06`, IN `0x88` |

This is exactly the map derived from the decompiled code above. The Swift transport uses the same mapping:
`SeaEndpoint` command = OUT `0x06` / IN `0x88`, data = OUT `0x02` / IN `0x84`; `SeaLink` routes
`.command` → 0x06/0x88 and `.data` → 0x02/0x84; `LibUSBTransport` claims interface 0. (The serial string
seen in `ioreg` belongs to the hub and is ignored.)

A **command** (`TransferCtrl::SendCmd` @0x1695e0) goes out on `0x06`, reply on `0x88`, up to **2** retries.
A **data** buffer (`TransferCtrl::SendData` @0x169218) goes out on `0x02`, reply on `0x84`, up to **8** retries.
5 ms between retries. confirmed.

### 1a. Two wire protocols — the owner's unit speaks the OLD one (hardware evidence)

The vendor code has two protocols, selected per transmission object by a "new protocol" byte (Windows
`CDataTransmission` vtable `+0x48` getter `FUN_1006fa70` / `+0x4c` setter `FUN_1006fa80`, byte at `+0xc`).
In the SeaMark.dll shipped in the vendor package **both** transmission constructors (`UsbComm` `FUN_1006fa90`,
`CUDPTransmit` `FUN_10071dc0`) set it to 1 and no caller clears it, but every command builder still contains
the old branch. The Android core (`libCoreSDK`) has **no** old path — `TransferCtrl` always frames.

**Observed on the owner's unit** (2026-10-20, lead + owner, `mrcarve-cli info --live --trace`, read-only):
```
>> EP 0x06 (20 B) FE FF 00 14 81 00 F0 F0 00 00 00 00 00 00 00 00 00 00 00 E0   (framed GetDeviceInfo)
<< EP 0x88 (12 B) 00 00 FF FF 81 00 F0 F0 00 00 00 00
(identical for seq 0x82, 0x83; 0xAA05 never sent)
```
Interpretation (bytes confirmed, meaning inferred): the board consumed the first 12 bytes as an
**old-protocol block** whose opcode word is `FEFF`, did not recognise it, and answered a 12-byte block with
word0 `0000` (no opcode echo), word1 `FFFF` (error), bytes 4…11 left as the request's bytes 4…11. The vendor's
old reply check (first word must equal the request's first word, `FUN_100649c0`/`FUN_10063f60`) would reject
this too. Supporting evidence from the vendor factory logs: `10AA:/18AA:/22AA: IDS_COMMAND_FAILURE` — new-protocol
`AA10`/`AA18`/`AA22` failing on some boards. **This port therefore defaults to the legacy protocol**
(`SeaProtocolVariant.legacy`); `--framed` opts into the new one.

### Old (legacy) protocol — confirmed from the `IsNewProtocol()==false` branches of SeaMark.dll

- **Command block:** exactly **12 bytes, unframed**: opcode word + five 16-bit words, all big-endian
  (`htons` = `Ordinal_9`). Sent on **EP 0x06** by `WriteCMD` (`FUN_10070350`: no `PackageData` when the flag is 0).
- **Reply:** **12 bytes** read on **EP 0x88** (`ReadPort` `FUN_10070600`: old branch reads 0xC bytes raw, no
  header/checksum). Accept only if `reply[0..1] == request[0..1]`; otherwise read again — up to 3 reads
  (`FUN_100649c0`), "GetSSVersion ReadPort again" (`FUN_10063f60`). 5 ms between write and read, 10 ms between
  write attempts.
- **Data lists (geometry):** N concatenated 12-byte blocks, no header (`FUN_1006eb40`: buffer = `count·0xC`),
  sent by `WriteData` on **EP 0x02** (needs > 11 bytes), then a 12-byte ack read on **EP 0x84**
  (old `ExeCurCmd` `FUN_100690c0`).
- **Opcode numbering differs from the new protocol** — e.g. old `0x0212` is the lens block (new `0x0221`), old
  LineToAbs is `0x0243` (new `0x0245`). Never reuse a new opcode in legacy mode.

| old op | new equiv. | function | meaning / layout (conf) |
|---|---|---|---|
| `0110` | `F0F0` | `FUN_10063f60` GetSSVersion | reply `[2],[3],[4],[5]` = FPGA a.b.c.d ("FPGA:%d.%d.%d.%d") |
| `0101` | `AA05` | `FUN_10069580` status poll | reply `[2]` flags (bit0 running, bit1 ready, bit2 reset, bit5 finished, bit6, bit7 — *inferred* by matching the new branch's fields), `[4..5]` word, `[6]`·4096 = free cache bytes, `[7]`, `[9..10]` mark counter |
| `0140` | `FFF1` | `FUN_10063d20` GetBoardMode | word5 = 1; reply `[10..11]` = `55 AA` → mode 0 (factory), `AA 55` → mode 1, else `[2]` |
| `0103` | `AA07` | `FUN_10066f40` | extended state |
| `0104` | `AA10 03` | `FUN_10069400` | SetRun |
| `0105` | `AA10 01` | `FUN_100692b0` | SetReady |
| `0106` | `AA18` | `FUN_10064770` | ClearCache |
| `010D` | `AA34` | `FUN_10068fd0` | query (retried ×3) |
| `0111` | `AA22` | `FUN_10069cb0` | GPO |
| `0125` | `AA2C` | `FUN_1006c4e0` | pause / resume |
| `0202`, `0205` | same | `FUN_10068de0`, `FUN_10068f00` | hardware block, count once |
| `0212` | `0221` | `FUN_10067210` | lens block, words 3–4 = `FFFF FFFF` |
| `0241` / `0242` | same | `FUN_1006a030` / `FUN_1006a630` | jump abs / rel: `[2..3]` time, `[4..5]` X, `[6..7]` Y (16-bit), `[8..9]` 0, `[10..11]` delay |
| `0243` / `0244` | `0245` / `0246` | `FUN_1006a330` / `FUN_1006a930` | line abs / rel, same layout |
| `0206 0207 0208 0217 0218` (+`A501`) | `0212 021B 0208 0213 0218 021A 0216` | `FUN_10067b90` (old branch) | pen/laser parameters — **layouts not mapped yet** |

Not yet mapped in old mode: the red pointer (no old-branch red opcode exists in `FUN_10067b90`; old `0x0212` is
the lens block — probably driven via GPO / `REDLIGHTOUTPORT`, *unverified*) and all laser/pen parameters.
**Until they are mapped, `mark()` and `startFraming()` refuse to run in legacy mode before sending anything.**
Swift: `LegacyCommand`, `LegacyReply`, `LegacyStatus`, `LegacyLink`, `MarkCompiler.legacyMotionPreview`.

### Framing ("new protocol", `tagSeaCMD::getData` @0x13922c, Windows `PackageData` @0x10072780)

```
FE FF | len16 (BE) | flags | 00 | payload… | 00 | checksum
```
- `len16` = total frame length = `payload.count + 8`, big-endian. confirmed.
- `flags` = `0x80 | seq` for a **command**, or `seq` for a **data** buffer; `seq` is a 4-bit counter
  per channel. confirmed.
- trailing `00` is at frame offset `len−2`; `checksum` (offset `len−1`) =
  `(payload[0] + payload[1] + payload[last] + payload[last−1]) & 0xFF`. confirmed.
- The reply is parsed the same way: verify checksum, require the net-error bits `flags & 0x0E00 == 0`,
  then strip 6 header + 2 trailer bytes to recover the reply payload. confirmed.

Swift: `SeaFrame.encode/decode`, `SeaLink` (framing + retry + validation).

### Command payload (`tagSeaCMD`)

```
payload[0..1] = opcode, big-endian
payload[2]    = padded length   (only when the command carries a length byte — "hasLen")
payload[3]    = 00
payload[4..]  = parameters       (or payload[2..] when there is no length byte)
```
The payload is padded to **≥ 12 bytes and an even length** before framing. confirmed. Multi-byte scalar
params are **big-endian** on the wire (the vendor byte-swaps off `CCommFun::isBigEndian`, false on all
targets, so the bytes always land in the board's big-endian order). confirmed.

Swift: `SeaCommand` / `SeaEncode` / `SeaCommandBuilder`.

### Batching (`CSeaCmdList::getData` @0x129410)

A batch concatenates the **payloads** of several commands (no per-command `FE FF` header) behind one
`FE FF` frame with `flags` = data seq, then sends it as one `SendData` transfer on EP `0x02`. The USB
batch size limit is **0x200 bytes** (`AddCmd` @0x12f1c8 uses `0x200` for comm-type USB, `0x578` for UDP).
confirmed. Swift: `USBLaserController.batch`.

### Flow control

`GetCacheFreeSpace`/`WaitForEnoughCache` (@0x12e3e0/@0x12e400): the host tracks the board cache as
`cacheKiB * 1024` (cacheKiB from the status reply, default 0xFFF) and blocks before a batch until the
device reports enough free space, polling `GetDevBaseState`. `WaitForFinish` (@0x12e6c0) polls the same
status until the idle bit is set / board status drops below run-ready. confirmed shape; thresholds inferred.

---

## 2. Status & device info

### `GetDevBaseState` — opcode `0xAA05` (command channel)

Reply payload, after the 4-byte prefix the vendor skips (`updateDevBaseState(payload+4)` @0x12acf8):

| base off | meaning | conf |
|---|---|---|
| `[0]` | board status (0 reset, 1 ready, 2 run-ready, 3 run) | inferred |
| `[1]` bits 1..6 | status flags | inferred |
| `[2..3]` | counter / aux | inferred |
| `[4..5]` BE | **laser state** — must be 0 before a job may start | inferred (`CMarkAdaptor::DoMark` checks `GetLaserState()==0`) |
| `[8]` bit0 | **idle / finished** (cache drained) | inferred |
| `[9..11]` BE24 | free cache, **KiB** | inferred |
| `[20..21]`, `[22..23]`, `[24..25]` BE | marked counts | inferred |

Windows `FUN_10069580` agrees: `payload[2]!=0` → error; `payload[4]` status; `payload[12]&1` idle;
`payload[13..15]` free cache. Swift: `DeviceBaseState`.

### `GetDeviceInfo` — opcode `0xF0F0` (command channel; `DevComm::GetDevInfo` @0x16aa54)

Reply ≥ 52 bytes. **FPGA version = reply payload bytes `[42..45]` = a.b.c.d** (Windows `GetSSVersion`
prints these four; observed `1.6.0.8`, `1.4.0.85`). confirmed. Card id at `[6..17]`. Swift:
`USBLaserController.fpgaVersion`.

Other queries: `0xAA01` heartbeat (`GetDevHeartState`), `0xAA07` extended state, `0xF013` IsBindMe.

---

## 3. Opcode table

Big-endian id in `payload[0..1]`. "ch" = channel (cmd = EP 0x06, data = EP 0x02).

| id | ch | name | source (addr) | params (conf) |
|---|---|---|---|---|
| `F0F0` | cmd | GetDeviceInfo | `DevComm::GetDevInfo` 16aa54 | none; reply carries FPGA ver |
| `F013` | cmd | IsBindMe | 12e188 | none |
| `AA01` | cmd | heartbeat | GetDevHeartState 12c4f0 | none |
| `AA05` | cmd | GetDevBaseState | 12c860 | none |
| `AA07` | cmd | GetDevExtState | 12c9f4 | none |
| `AA10` | cmd | SetBoardStatus | 12e91c | `[2]` = mode (0/1/2/3) |
| `AA18` | cmd | ClearCache | 12ed8c | none |
| `AAA4` | cmd | SetOnline | 12f070 | `[2]` = !online |
| `AAA6` | cmd | SetOnline (2nd pkt) | 12f070 | `[4]` = !online |
| `AA2C` | cmd | Pause / Resume | 12eb04/12ec30 | pause vs resume *(inferred)* |
| `AA22` | cmd | SetGpoValues | 12fa10 | GPO mask/value |
| `0140`/`FFF1` | data | **GetBoardMode** | SeaMark 10063d20 | mode query (handshake — see top) |
| `0202` | data | SetHardwareBlock | 13014c | bitmask |
| `0205` | data | CountOnce | 12cc24 | none |
| `0208` | data | SendLightOnDelay | 12d1dc | `[4..5]` on-offset, `[6..7]` open delay (BE) |
| `0210` | data | SetMoStatus / SendMOSignal | 130264/12d2a4 | `[4]` on, `[6..7]` MO delay µs (BE) |
| `0211` | data | SendAPSignal | 12d35c | `[4]` on |
| `0212` | data | SendRedSignal / SetRedLightMark | 12d3e4/135080 | `[4]` on (red pointer) |
| `0213` | data | SendPRRSignal | 12d46c | `[4..5]` = 48000/freq_kHz (BE) |
| `0214` | data | SendFiberPower | 12d548 | `[4..5]` = power·65535/100 (BE) |
| `0216` | data | SendMOPALaser | 12d670 | `[4..]` Q pulse-width index, marker 0xA501 |
| `0218` | data | SendPWMSignal | 12d75c | `[6..9]` period = 48000/freq_kHz |
| `021A` | data | SendDASignal | 12d9d8 | `[4..5]` = power·4095/100 via POWERANALOGMAP |
| `021B` | data | SendPreionFPS | 12dda4 | pre-ionisation FPS |
| `0220` | data | SendLaserEffectTime | 12df3c | `[4..5]` µs (BE) |
| `0221` | data | SendLenPara | 12cd84 | lens/field block |
| `0A00` | data | SetDelayTime | 12e81c | `[4..7]` = delay·2, 32-bit BE |
| `0241` | data | MoveToAbs / GotoPosition | 134088/131c10 | see §5 |
| `0242` | data | MoveToRel | 1341e0 | as 0241 |
| `0245` | data | LineToAbs / LinetoPosition | 134338/132058 | see §5 |
| `0246` | data | LineToRel | 1344f0 | as 0245 |
| `0230`–`0233` | data | axis config | 13511c.. | extended axis |
| `0300`–`03A0` | data | motor-axis (MoAx) | 136574.. | rotary/joint — not ported |

Not implemented here (out of scope or not needed for basic operation): `bind`/`debind`/crypto (`0xF0FA`
+ `libcrypto6`), factory data (`SendFactoryData`), motor-axis / rotary (`MoAx*`), fly-marking, 3D
(`CDGExecutor`, `tagSeaTPointF`, `CailZ`).

---

## 4. mm → galvo coordinate conversion

`CDevUtil::LP2DPEX` (@0x13c634) → `LP2DPEX_SFT` → `CalibPoint` → `CCalibAlg::CalibManual`
(`libBslCal` @0x121d04). The M1 Pro's `LmcPar_*.cfg` has `LEN_ENABLECORFILE=0`, so the **box**
(manual) correction is used, **not** the 9-point / `.cor`-file least-squares path (`CalibLSM` — present in
`libBslCal` but not ported). Galvo range **0…0xFFFF**, centre **0x8000**, barrel normaliser **0xFFFF²**.
counts/mm = `0xFFFF / LEN_WORKSIZE`. confirmed; arithmetic **unverified**. Swift: `GalvoTransform`.

Pipeline (point in mm, origin at field centre, +Y up):
1. `(x,y) += (LEN_FIELDOFFSETX, LEN_FIELDOFFSETY)`.
2. if `|LEN_ROTATEANGLE| > 1e-4`: rotate about `(LEN_ROTATEOX, LEN_ROTATEOY)` (defaults to origin).
3. axis swap/invert: `LEN_XYFLIP`, `LEN_XINVERT`, `LEN_YINVERT` (all 0 on the M1 Pro).
4. box correction:
   ```
   a0 = LEN_SCALEX·x/100 ;  b0 = LEN_SCALEY·y/100
   a1 = a0 − (1−LEN_PRRLX)·b0 ;  b1 = b0 − (1−LEN_PRRLY)·a0        # parallelogram
   g  = 0xFFFF / LEN_WORKSIZE
   a2 = (a1 + (1−LEN_TRAPEX)·b1·a1·(−2)/LEN_WORKSIZE)·g            # trapezoid
   b2 = (b1 + (1−LEN_TRAPEY)·a1·b1·(−2)/LEN_WORKSIZE)·g
   fx = a2 + (b2·(LEN_BUCKETX−1)·a2·b2)/0xFFFF²                    # barrel
   fy = b2 + ((LEN_BUCKETY−1)·b2·a2·a2)/0xFFFF²
   X  = clamp(round(fx + 0x8000), 0, 0xFFFF)
   Y  = clamp(round(fy + 0x8000), 0, 0xFFFF)
   ```

Red pointer uses a separate scale/offset (`REDLIGHTSCALEX/Y`, `REDLIGHTOFFSETX/Y`) applied inside
`CalibManual` via the `+0x1368..` lens fields; **not** modelled in `GalvoTransform` yet (framing uses the
same box transform). unverified.

---

## 5. Motion commands (`MoveToAbs` 0x0241 / `LineToAbs` 0x0245)

Payload after the opcode+length prefix (confirmed field order; reserved trailing bytes unverified):
```
[4..5]  time   (u16 BE) = round(distance_mm · 1e6 / speed_mm_s), clamp 0..0xFFFF
[6..7]  delay  (u16 BE) = jump settle delay (MoveTo) or end delay SHUTDEPLAY (LineTo)
[8..10] X      (24-bit BE; 2D uses low 16 bits)
[11..13] Y     (24-bit BE)
[14..16] reserved 0  (Z / padding)
```
`MoveToAbs` jumps with the laser off; `LineToAbs` marks with the laser on. Jump delay interpolates
`ADV_JUMPMINDELAY…ADV_JUMPMAXDELAY` over `0…ADV_JUMPMAXDISTANCE` (`GetJumpTime` @0x130580). confirmed.
Swift: `SeaCommandBuilder.moveToAbs/lineToAbs`, `PenConversion` for timing.

---

## 6. Pen parameters → registers

From `SendFiberPower`/`SendPWMSignal`/`SendPRRSignal`/`GetJumpTime`. Board timebase **48 MHz**. confirmed.

| UI field | cfg key / `tagPenPar` off | register |
|---|---|---|
| power % | LSRPWR / +0x38 | fiber DAC = `round(p·65535/100)`; analog DAC12 = `round(p·4095/100)` |
| frequency kHz | LSRFREQ / +0x44 | PWM/PRR period = `round(48000 / freq_kHz)` |
| mark speed mm/s | RUNSPEED / +0x34 | per-segment time = `dist·1e6/speed` |
| jump speed mm/s | ADV_JUMPSPEED / +0xCC | jump time = `dist·1e6/jumpSpeed` |
| laser-on delay µs | OPENDEPLAY / +0x50 | sent verbatim |
| laser-off delay µs | SHUTDEPLAY / +0x54 | sent verbatim |
| corner delay µs | CORNERDEPLAY / +0x5C | sent verbatim |
| jump min/max delay µs | ADV_JUMPMIN/MAXDELAY / +0xD8/+0xDC | interpolated by distance |
| jump max distance mm | ADV_JUMPMAXDISTANCE / +0xE0 | interpolation cap |

`PenConversion` clamps power to 0–100 %, frequency to `[OPC_MINPWMFREQ, OPC_MAXPWMFREQ]`, pulse width to
`[OPC_MINQPW, OPC_MAXQPW]`, speed to `[LEN_MINSPEED, LEN_MAXSPEED]` before encoding.

Full `tagLmcPar`/`tagPenPar`/`tagMarkPar` field-offset → cfg-key maps: `re/notes/structs.md`.

---

## 7. Sequences

### Init (safe, what this port's `connect()` does)
1. open 04B4:1004, claim interface 0.
2. **Legacy (default):** `01 10 00…00` (GetSSVersion, EP 0x06) → 12-byte reply on 0x88, FPGA = bytes 2..5;
   then `01 01 00…00` (status poll) → flags / free cache.
   **Framed (`--framed`):** `GetDeviceInfo` (0xF0F0) then `GetDevBaseState` (0xAA05), framed.
3. *(The vendor additionally runs GetBoardMode `0x0140` and, if in factory mode, a mode-switch command — not
   performed; see top of doc.)*

### Red-pointer framing (`startFraming`, laser never fires)
1. `SendMOSignal(off)` (0x0210) — master oscillator gated off.
2. `SendRedSignal(on)` (0x0212) — red diode on (gated by `REDLIGHTOUTPORT`).
3. for each outline polyline: `MoveToAbs` to the start, `LineToAbs` along it, at `REDLIGHTSPEED`.
4. loop steps 3 until `stop()`; then `SendRedSignal(off)`.

### Marking (`mark`, laser fires)
1. `SetOnline(true)`, `ClearCache`, `SetBoardStatus(ready)`.
2. per enabled pen: `SendRedSignal(off)`, `SendLightOnDelay`, `SendPWMSignal`/`SendFiberPower`,
   `SetMoStatus(on)`; then per polyline `GotoPosition`+`LinetoPosition`; then `SetMoStatus(off)`.
   (vendor `SendMarkPara`/`SendPenPara` @0x12ccc0/0x12e098 → `CController::MarkPaths` @0x486eb8.)
3. stream the geometry in ≤0x200-byte batches on EP 0x02, with `WaitForEnoughCache` flow control.
4. `SetBoardStatus(run)`, then `WaitForFinish` (poll 0xAA05 until idle).
5. `SetBoardStatus(ready)`.

### Stop (`stop`, fast, laser left off)
`SetMoStatus(off)` + `SendRedSignal(off)` + `SetBoardStatus(reset)`. The Windows `CMarkAdaptor::StopMark`
also sets a stop flag that each queued command checks (`this[0xbc0]`), so the batch loop aborts promptly.

---

## 8. Hardware bring-up checklist (safest → riskiest)

1. **Enumerate (no I/O):** `swift run mrcarve-cli list -v`. Confirm `04B4:1004`; record the endpoints
   (expect OUT 0x02/0x06, IN 0x84/0x88). If it shows `04B4:8613` the FX2 has no firmware.
2. **Dry-compile (no device):** `mrcarve-cli dryrun job.json --cfg LmcPar_Fiber.cfg`. Check the opcodes,
   galvo counts (centre → 0x8000) and that the job fits the field.
3. **Read version (read-only):** `mrcarve-cli info --live --trace`. Legacy mode sends only
   `01 10 00 00 00 00 00 00 00 00 00 00` then `01 01 00 00 00 00 00 00 00 00 00 00`. Expect a reply starting
   `01 10` with bytes 2..5 = FPGA version, then one starting `01 01`. *(Done once in framed mode on 2026-10-20 —
   board rejected `FE FF`; see §1a.)* **If the reply is `00 00 FF FF …` again or the board reports factory
   mode, STOP** and resolve with the owner before going further.
3b. *(optional, after 3 succeeds)* GetBoardMode `01 40 00 00 00 00 00 00 00 00 00 01` — a query by usage
   (polled ×15 at init), but word5's meaning is unknown; send only with the owner's approval.
4. **Status poll:** confirm `GetDevBaseState` returns sane board status / free cache across repeated reads.
5. **Red framing (no laser):** `mrcarve-cli frame job.json --live`. Galvos trace the outline with the red
   pointer only. Verify the traced box matches the intended size/position — this validates the galvo
   transform and sign conventions (XINVERT/YINVERT/XYFLIP) without emitting laser light.
6. **Laser at very low power:** `mrcarve-cli mark-test --live` with a pen at the **lowest** power and
   slowest speed, on scrap, eye protection on. Confirm a 10 mm square marks where the red frame showed.
   Only then raise power.

---

## 9. Open questions for bring-up

- **Old-protocol laser / red-pointer encodings** (legacy mode, the owner's unit): decode the old branch of
  `FUN_10067b90` (`0x0206/0x0207/0x0208/0x0217/0x0218`, `0xA501` marker) and find how the red pointer is driven
  in old mode (likely GPO `0x0111` on `REDLIGHTOUTPORT`). Framing and marking stay disabled in legacy mode until
  then. **Now the gating item after `info`.**
- **What selects old vs new in the owner's working software?** The packaged SeaMark.dll always selects new; the
  owner's working XP install is probably an older build. Its version string / DLL would settle it.

- **Board mode / factory-mode handshake** (`GetBoardMode` 0x0140/0xFFF1, `uMode`). Does the M1 Pro accept
  `0xAA05`/motion commands straight after enumeration, or must a mode switch happen first? Decide with the
  owner; not implemented. **Highest priority — may block everything.**
- **Bind / encryption** (`0xF0FA` + `libcrypto6`). Licensing/registration, out of scope. Confirm the board
  does not gate normal operation behind it (the Android `CCmdExecutor::bind` returns success for USB comm
  type without the crypto exchange — inferred that USB devices are not bind-gated, but unverified).
- **Galvo transform arithmetic** (barrel/trapezoid order, red-light scale/offset) and **axis sign**
  (does +Y mm = increasing galvo count on this unit?). Validate in step 5 with red framing.
- **Motion param trailing bytes** (reserved bytes 14..16 in Move/Line) and the exact **time units** the
  board expects (µs vs galvo micro-steps). Validate that a known-length line marks at the commanded speed.
- **Flow-control thresholds** in `WaitForEnoughCache`/`WaitForFinish` (the `+10000`/`0x2711` margins).
- **`SendPWMSignal` field width** for the period (16 vs 32 bit) and the MOPA pulse-width index mapping.
- **Status bit meanings** (`[1]` flags, idle bit position) — confirm against live `0xAA05` replies.
