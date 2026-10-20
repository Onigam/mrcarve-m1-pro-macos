# Protocol working notes

## Endpoints / framing — see docs/PROTOCOL.md §1 (confirmed)
- EP 0x06 OUT = command, 0x88 IN = command reply (TransferCtrl::SendCmd, 2 retries).
- EP 0x02 OUT = data/batch, 0x84 IN = data reply (TransferCtrl::SendData, 8 retries).
- Frame: FE FF | len16 BE | flags | 00 | payload | 00 | checksum. flags 0x80|seq (cmd) or seq (data).
- checksum = (p[0]+p[1]+p[last]+p[last-1]) & 0xFF.
- payload: op BE @[0..1], len @[2] (if hasLen), params @[4] (hasLen) / @[2]; pad ≥12 & even.
- scalars BE on the wire; galvo coords 24-bit BE; batch limit 0x200 (USB).

## From vendor run.log (GBK-decoded, M1-pro-3.0-tomigrate/.../Log/*/run.log)
- `CExecutor::GetDevPathMap index=0 vid=4B4, pid=1004` then `UsbComm::OpenUsbDev:: 0` (0 = success).
- `GetSSVersion FPGA:1.6.0.8` / `1.4.0.85` / `1.4.0.81` / `1.7.2.3` — FPGA version strings seen.
- `GetBoardMode ReadPort again` and `板卡异常,初始化时仍然处于工厂模式 uMode=0` (factory-mode init error).
- Mark cycle logs `CCmdExecutor::DevID = <id>:nCmdCount = N` with N ~ 1 / 4 / 8 / 10 / 29 per batch —
  i.e. geometry is uploaded in many small batched command lists (matches CSeaCmdList / 0x200 batching).
- `OnRedLight...` / `1::SetMarkStatus:TRUE` precede marking; framing and marking share the DoMark path.
- Windows build only: all transfers go through CyAPI (`USBERROR [WriteCMD ...]`), but the frame layout is
  identical to the Android libusb build (verified via CDataTransmission::PackageData @0x10072780).

## Opcode immediates on Windows are invisible in the decompiler
The new-protocol command builders pass the opcode in EAX before `call tagSeaCMDNet::ctor`
(`mov eax, 0x245; call 0x1006dab0`), so they don't appear as stores in the C output — read them from the
disassembly (llvm-objdump). Confirmed 0x241/0x242/0x245/0x246 (move/line), 0x221 (len), 0x10d, 0xaa05,
0xaa10, 0x101/0x102/0x104/0x105 (status/mode) this way.

## Legacy (old) protocol — added after the 2026-10-20 hardware trace
- Owner's unit answered framed F0F0 with `00 00 FF FF 81 00 F0 F0 00 00 00 00` → speaks the old protocol.
- Old/new opcode pairs per Windows function were tabulated by pairing each function's old-branch `htons()`
  literal with the `mov eax, imm` before `call 0x1006dab0` in its new branch (script in session scratchpad;
  table reproduced in docs/PROTOCOL.md §1a). Numbering differs (old 0x0212 = lens, new 0x0212 = red).
- Both SeaMark transmission ctors (FUN_1006fa90 UsbComm, FUN_10071dc0 CUDPTransmit) set new-protocol = 1;
  no caller of the +0x4c setter exists in this build → the packaged DLL never uses the old path.
