# Vtable maps (libCoreSDK.so, Android ARM64; SeaMark.dll, Windows x86)

How these were obtained (reproducible):

- `llvm-nm -D -C re/bin/libCoreSDK.so | grep 'vtable for'` gives the vtable symbol address `V`.
- Vtable slots are `R_AARCH64_ABS64` relocations (`llvm-readobj -r`); slot *n* (byte offset `8n` as used
  in the decompiled `(**(code **)(*(long *)this + OFF))`) lives at `V + 0x10 + OFF`.
- Ghidra addresses = ELF virtual address + 0x100000 (e.g. Ghidra `0012ae94` = ELF `0x2ae94`).
- SeaMark.dll (MSVC): find the RTTI TypeDescriptor `.?AVName@@`, the CompleteObjectLocator that points
  at it, and the vftable is the word after the pointer to the COL.

## LibUsbControl (vtable 0x7fd80) — confirmed

| off | function |
|---|---|
| 0x10 | `WriteDataBuf(buf,len)` → `libusb_bulk_transfer(ep 0x02, timeout 100 ms)`; refuses len < 12 |
| 0x18 | `WriteCMDBuf(buf,len)` → `libusb_bulk_transfer(ep 0x06, 100 ms)` |
| 0x20 | `ReadPort(isData, buf, &len)` → bulk IN, ep `isData ? 0x84 : 0x88`, **80 bytes**, 100 ms |
| 0x28 | `TransferBase::ReadDataBuf` → `ReadPort(1, …)` (ep 0x84) |
| 0x30 | `TransferBase::ReadCmdBuf` → `ReadPort(0, …)` (ep 0x88) |
| 0x38/0x40/0x48/0x50/0x58 | InitDrv / IsOpen / OpenDrv (`libusb_wrap_sys_device`) / CloseDrv / GetErrorString |

`TransferCtrl::SendCmd` uses 0x18 then 0x30; `TransferCtrl::SendData` uses 0x10 then 0x28.

## tagSeaCMD (vtable 0x7e6f0)

`+0x10 setCmdId(id, hasLen)`, `+0x18 getData(withHeader, out)`.

## CCmdExecutor (vtable 0x7e218) — confirmed; CDGExecutor/CMemExecutor/CBatchExecutor derive from it

`CExecutor::Init(tagDevInfo&)` creates a `CCmdExecutor` when `DevComm::GetDevInfo` (0xF0F0) succeeds
(returns 1000). `CDGExecutor` (dual lens, overrides 0x288/0x298/0x368/0x380/0x388) is not used by it.

```
+0x000  CCmdExecutor::~CCmdExecutor()
+0x008  CCmdExecutor::~CCmdExecutor()
+0x010  CCmdExecutor::GetMemData(std::__ndk1::vector<std::__ndk1::vector<char, std::__ndk1::allocator<c…)
+0x018  CCmdExecutor::Initialize(DevComm*, tagDevInfo&)
+0x020  CCmdExecutor::SetEnable(bool)
+0x028  CCmdExecutor::IsEnable(bool)
+0x030  CCmdExecutor::CanExeDataCmd()
+0x038  CCmdExecutor::GetDevInfo()
+0x040  CCmdExecutor::ConfigWifi(std::__ndk1::basic_string<char, std::__ndk1::char_traits<char>, std::_…)
+0x048  CCmdExecutor::ConfigCmd(unsigned char)
+0x050  CCmdExecutor::bind()
+0x058  CCmdExecutor::debind()
+0x060  CCmdExecutor::modify(char const*)
+0x068  CCmdExecutor::modify(tagDevice const&)
+0x070  CCmdExecutor::EncryptTest()
+0x078  CCmdExecutor::GetDevHeartState()
+0x080  CCmdExecutor::GetDevBaseState(tagDevBaseState&, bool)
+0x088  CCmdExecutor::GetDevExtState(tagDevExtState&, bool)
+0x090  CCmdExecutor::SendPackData(unsigned char*, unsigned int)
+0x098  CCmdExecutor::AddCmd(tagSeaCMD*)
+0x0a0  CCmdExecutor::ExeCurCmd(bool)
+0x0a8  CCmdExecutor::ClearCmdList()
+0x0b0  CCmdExecutor::ExeCurDataCmd(bool)
+0x0b8  CCmdExecutor::SetRedLightMark(bool)
+0x0c0  CCmdExecutor::SetHardwareBlock(unsigned short, bool, int)
+0x0c8  CCmdExecutor::DoRedPoint(tagLmcPar&, tagSeaPointF, tagSeaPointF)
+0x0d0  CCmdExecutor::SetSPIMode(int)
+0x0d8  CCmdExecutor::GetLaserState()
+0x0e0  CCmdExecutor::SendMarkPara(tagLmcPar&, int, int)
+0x0e8  CCmdExecutor::SendFlowLinePara(tagLmcPar&)
+0x0f0  CCmdExecutor::SendLightOnDelay(tagPenPar const&)
+0x0f8  CCmdExecutor::SendMOSignal(bool, unsigned short)
+0x100  CCmdExecutor::SendAPSignal(bool)
+0x108  CCmdExecutor::SendRedSignal(bool)
+0x110  CCmdExecutor::SendPRRSignal(tagLmcPar const&, tagPenPar const&)
+0x118  CCmdExecutor::SendFiberPower(tagLmcPar const&, unsigned short, unsigned short)
+0x120  CCmdExecutor::SendMOPALaser(tagLmcPar const&, tagPenPar const&)
+0x128  CCmdExecutor::SendPWMSignal(tagLmcPar const&, tagPenPar const&, unsigned short, bool)
+0x130  CCmdExecutor::SendDASignal(tagLmcPar const&, tagPenPar const&, unsigned short*)
+0x138  CCmdExecutor::SendPreionFPS(tagLmcPar const&)
+0x140  CCmdExecutor::SendLaserEffectTime(unsigned short)
+0x148  CCmdExecutor::SendLenPara(tagLmcPar&, int, bool)
+0x150  CCmdExecutor::SendPenPara(tagLmcPar&, bool, tagPenPar const&, bool, int)
+0x158  CCmdExecutor::GetMoAxState(unsigned int&)
+0x160  CCmdExecutor::GetMarkedCount(bool)
+0x168  CCmdExecutor::IsBindMe()
+0x170  CCmdExecutor::WaitForEnoughCache(unsigned int)
+0x178  CCmdExecutor::WaitForFinish()
+0x180  CCmdExecutor::WaitForMoveFinish(int)
+0x188  CCmdExecutor::StartMark()
+0x190  CCmdExecutor::StopMark(int)
+0x198  CCmdExecutor::PauseMark()
+0x1a0  CCmdExecutor::ResumeMark()
+0x1a8  CCmdExecutor::SetReset()
+0x1b0  CCmdExecutor::ClearCache()
+0x1b8  CCmdExecutor::SetReady()
+0x1c0  CCmdExecutor::SetRunReady()
+0x1c8  CCmdExecutor::SetRun()
+0x1d0  CCmdExecutor::CountOnce()
+0x1d8  CCmdExecutor::SetOnline(bool)
+0x1e0  CCmdExecutor::SetMarkReady()
+0x1e8  CCmdExecutor::SetStartMark(bool)
+0x1f0  CCmdExecutor::GetInPortState(unsigned int&, bool)
+0x1f8  CCmdExecutor::GetOutPortState(unsigned int&, bool)
+0x200  CCmdExecutor::SetGpiFilter(unsigned int, unsigned int)
+0x208  CCmdExecutor::SetGpoValue(unsigned int, bool)
+0x210  CCmdExecutor::SetGpoValues(unsigned int, unsigned int)
+0x218  CCmdExecutor::SetGpoPulse(unsigned int, bool, unsigned int)
+0x220  CCmdExecutor::SetGpoPulseMode(unsigned int, bool)
+0x228  CCmdExecutor::SendGpoValue(unsigned int, bool)
+0x230  CCmdExecutor::SendGpoValues(unsigned int, unsigned int)
+0x238  CCmdExecutor::SendGpoPulse(unsigned int, bool, unsigned int)
+0x240  CCmdExecutor::SetMoStatus(tagLmcPar&, bool, bool)
+0x248  CCmdExecutor::QueryMarkCount(unsigned int&, unsigned int&)
+0x250  CCmdExecutor::ResetCount()
+0x258  CCmdExecutor::SetDelayTime(unsigned int)
+0x260  CCmdExecutor::SetEncoderDistance(int)
+0x268  CCmdExecutor::SetMarkStartDelay(int)
+0x270  CCmdExecutor::SetQPW(tagLmcPar&, tagPenPar&)
+0x278  CCmdExecutor::GetMoveDistance(tagSeaPointF)
+0x280  CCmdExecutor::GetMoveDistance(tagSeaTPointF)
+0x288  CCmdExecutor::GotoPosition(tagLmcPar&, tagPenPar const&, tagSeaPointF)
+0x290  CCmdExecutor::GotoPosition(tagLmcPar&, tagPenPar const&, tagSeaTPointF)
+0x298  CCmdExecutor::LinetoPosition(tagLmcPar&, tagPenPar const&, tagSeaPointF, bool)
+0x2a0  CCmdExecutor::LinetoPosition(tagLmcPar&, tagPenPar const&, tagSeaTPointF, bool)
+0x2a8  CCmdExecutor::MoveToAbs(tagLmcPar&, tagPenPar const&, tagSeaPointF)
+0x2b0  CCmdExecutor::LinetoAbs(tagLmcPar&, tagPenPar const&, tagSeaPointF)
+0x2b8  CCmdExecutor::MovetoRel(tagLmcPar&, tagPenPar const&, tagSeaPointF)
+0x2c0  CCmdExecutor::LinetoRel(tagLmcPar&, tagPenPar const&, tagSeaPointF)
+0x2c8  CCmdExecutor::MoveToAbs(tagLmcPar&, tagPenPar const&, tagSeaTPointF)
+0x2d0  CCmdExecutor::LinetoAbs(tagLmcPar&, tagPenPar const&, tagSeaTPointF)
+0x2d8  CCmdExecutor::MovetoRel(tagLmcPar&, tagPenPar const&, tagSeaTPointF)
+0x2e0  CCmdExecutor::LinetoRel(tagLmcPar&, tagPenPar const&, tagSeaTPointF)
+0x2e8  CCmdExecutor::SetLaserOnSpot(tagLmcPar&, tagPenPar const&, tagSeaPointF, bool, unsigned int)
+0x2f0  CCmdExecutor::SetLaserOnSpot(tagLmcPar&, tagPenPar const&, tagSeaTPointF&, bool, unsigned int)
+0x2f8  CCmdExecutor::SetPower(tagLmcPar&, tagPenPar const&, unsigned short, unsigned short, bool)
+0x300  CCmdExecutor::ReCalcPower(tagLmcPar&, float)
+0x308  CCmdExecutor::SetPWMOut(float, float)
+0x310  CCmdExecutor::SetDAPowerOut(int)
+0x318  CCmdExecutor::SetDAPowerFloatOut(float)
+0x320  CCmdExecutor::SetPowerOut(tagLmcPar&, float)
+0x328  CCmdExecutor::SetLaserPortSwitch(int, int, int, int, int, int)
+0x330  CCmdExecutor::SendFactoryData(unsigned char*, int)
+0x338  CCmdExecutor::SetRegString(char const*, int)
+0x340  CCmdExecutor::GetRegCardID(char*)
+0x348  CCmdExecutor::GetDevRegInfo(tagDevRegInfo&)
+0x350  CCmdExecutor::GetDevCryptoId()
+0x358  CCmdExecutor::GetLineEndDelay(tagSeaPointF, tagSeaPointF, tagSeaPointF, tagPenPar const&)
+0x360  CCmdExecutor::GetLineEndDelay(tagSeaTPointF, tagSeaTPointF, tagSeaTPointF, tagPenPar const&)
+0x368  CCmdExecutor::MarkPoints(tagLmcPar&, MARKTYPE, int, std::__ndk1::vector<tagSeaPointF, std::__nd…)
+0x370  CCmdExecutor::MarkPoints(tagLmcPar&, MARKTYPE, int, std::__ndk1::vector<tagSeaPointF, std::__nd…)
+0x378  CCmdExecutor::MarkPoint(tagLmcPar&, MARKTYPE, int, tagSeaPointF const&, tagPenPar const&, doub…)
+0x380  CCmdExecutor::MarkPointsByPulseCount(tagLmcPar&, MARKTYPE, int, std::__ndk1::vector<tagSeaPointF, std::__nd…)
+0x388  CCmdExecutor::MarkLines(tagLmcPar&, MARKTYPE, int, std::__ndk1::vector<tagSeaPointF, std::__nd…)
+0x390  CCmdExecutor::MarkPoints(tagLmcPar&, MARKTYPE, int, std::__ndk1::vector<tagSeaTPointF, std::__n…)
+0x398  CCmdExecutor::MarkPointsByPulseCount(tagLmcPar&, MARKTYPE, int, std::__ndk1::vector<tagSeaTPointF, std::__n…)
+0x3a0  CCmdExecutor::MarkLines(tagLmcPar&, MARKTYPE, int, std::__ndk1::vector<tagSeaTPointF, std::__n…)
+0x3a8  CCmdExecutor::MoveAxis(tagAxisPar*, int*, int*, int, bool)
+0x3b0  CCmdExecutor::MoveAxis(tagAxisPar&, int, int, bool)
+0x3b8  CCmdExecutor::MoveAxisToZero(tagAxisPar&, int, int, bool, bool)
+0x3c0  CCmdExecutor::MoveAxis(tagLmcPar&, int, float, bool, bool)
+0x3c8  CCmdExecutor::MoveAxisEx(tagLmcPar&, int, tagAxisPar&, float, bool)
+0x3d0  CCmdExecutor::CalcAngleMode(tagLmcPar&, int)
+0x3d8  CCmdExecutor::SetAxisMovePulse(tagLmcPar&, int, float, bool)
+0x3e0  CCmdExecutor::MoAxSetPar(tagMoAxisPar&, bool)
+0x3e8  CCmdExecutor::MoAxSetPar(tagM2JPar&, bool)
+0x3f0  CCmdExecutor::MoAxMovePulse(tagMoAxisPar&, int, int, int, int, bool)
+0x3f8  CCmdExecutor::MoAxMoveDist(tagMoAxisPar&, float, int, int, int, bool)
+0x400  CCmdExecutor::MoAxMovePulse(tagM2JPar&, int*, int*, int*, int*, bool)
+0x408  CCmdExecutor::MoAxMoveDist(tagM2JPar&, float*, int*, int*, int*, bool)
+0x410  CCmdExecutor::MoAxMoveJointPulse(tagM2JPar&, int*, int*, int*, int*, bool)
+0x418  CCmdExecutor::MoAxMoveJointDist(tagM2JPar&, float*, int*, int*, int*, bool)
+0x420  CCmdExecutor::MoAxToZero(tagMoAxisPar&, bool)
+0x428  CCmdExecutor::MoAxToZero(tagM2JPar&, bool)
+0x430  CCmdExecutor::MoAxToPos(int*, tagM2JPar&, bool)
+0x438  CCmdExecutor::MoAxToPos(tagSeaPointF, tagM2JPar&, bool)
+0x440  CCmdExecutor::MoAxToOrigin(tagM2JPar&, bool)
+0x448  CCmdExecutor::MoJMark(tagLenPar&, tagM2JPar&, std::__ndk1::vector<tagMovMarkItem, std::__ndk…)
+0x450  CCmdExecutor::MoJMove(tagM2JPar&, std::__ndk1::vector<tagMovMarkItem, std::__ndk1::allocator…)
+0x458  CCmdExecutor::MoveToCenter()
+0x460  CCmdExecutor::MoveToAbs(tagSeaPointF, int, int)
+0x468  CCmdExecutor::MoveToAbs(tagSeaTPointF, int, int)
+0x470  CCmdExecutor::MoveToRel(tagSeaPointF, int, int)
+0x478  CCmdExecutor::MoveToRel(tagSeaTPointF, int, int)
+0x480  CCmdExecutor::LineToAbs(tagSeaPointF, int, int)
+0x488  CCmdExecutor::LineToRel(tagSeaPointF, int, int)
+0x490  CCmdExecutor::LineToRel(tagSeaTPointF, int, int)
+0x498  CCmdExecutor::LineToAbs(tagLmcPar&, tagSeaPointF, int, int, bool)
+0x4a0  CCmdExecutor::LineToAbs(tagLmcPar&, tagSeaTPointF, int, int, bool)
+0x4a8  CCmdExecutor::LineToRel(tagLmcPar&, tagSeaPointF, int, int, bool)
+0x4b0  CCmdExecutor::LineToRel(tagLmcPar&, tagSeaTPointF, int, int, bool)
+0x4b8  vtable for __cxxabiv1::__class_type_info
```

## Windows SeaMark.dll

UsbComm vftable 0x1008cadc (CDataTransmission base 0x1008cc1c):

| off | function | notes |
|---|---|---|
| 0x08 | FUN_1006fc00 OpenUsbDev | CyAPI; checks VID 04B4 / PID 1004; endpoints 0x02 (XferSize 0x5A00 HS / 0xB40 FS), 0x84, 0x88, 0x06 (XferSize 12) |
| 0x14 | FUN_10070130 WriteData | only if len > 11; 500 ms wait |
| 0x18 | FUN_10070350 WriteCMD | if `+0x48` (new protocol) → `PackageData(1,…)` first |
| 0x1c | FUN_100708d0 WriteCMD + ReadPort(0) | |
| 0x20 | FUN_10070600 ReadPort(isData,…) | ep `0x84 + 4*(isData==0)`; new protocol reads 0x80, checks `[3]==len` and checksum, strips 6+2 |
| 0x34 | FUN_10072780 PackageData(isCmd, buf, len, &outLen) | FE FF framing, see PROTOCOL.md |
| 0x48 / 0x4c | FUN_1006fa70 / FUN_1006fa80 | get/set "new protocol" byte at +0xc; constructor FUN_1006fa90 sets it to **1**, no caller clears it |

CCmdExecutor (Windows) vftable 0x1008c2c4, relevant slots: 0x138 MoveToAbs (FUN_1006a030, op 0x241),
0x13c LineToAbs (FUN_1006a330, op 0x245), 0x140 MoveToRel (0x242), 0x144 LineToRel (0x246),
0x50 SetReady (AA10 01), 0xfc SetRun (AA10 03), 0xf0 status poll (AA05), 0x60 ExeCurCmd (FUN_100690c0),
0xe8 Init (FUN_10066a70: GetBoardMode 0xFFF1 loop, GetSSVersion 0xF0F0), 0x158 legacy MoveToCenter.
Opcode immediates for the new-protocol branch are passed in EAX (`mov eax, 0x245; call 0x1006dab0`),
so they are invisible in the decompiler output — read them from the disassembly.
