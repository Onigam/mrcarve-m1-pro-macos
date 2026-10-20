# Struct layouts (Android libCoreSDK/libSeaSDK, ARM64)

All offsets hex. "conf" = confirmed in code, "inf" = inferred from usage, "?" = unknown.
Key → offset maps were decoded from `CParaMgr::LoadLmcPar` (libSeaSDK 0x378728), `LoadMarkPar`
(0x383064) and `LoadPenPar` (0x3c4dc4): the INI key strings are built inline as libc++ short strings,
so they were reassembled from the byte stores preceding each `CIniFile::Get*` call.

## tagSeaCMD (heap object, 0x80 bytes) — conf

| off | type | meaning |
|---|---|---|
| 0x00 | ptr | vtable |
| 0x08 | u16 | command id (host order) |
| 0x0a | u8 | hasLen: payload byte 2 carries the (padded) payload length |
| 0x0b | u8 | payload length in bytes (before padding) |
| 0x0c..0x11 | 6 B | packet header scratch (`getData(true)`) |
| 0x12.. | bytes | payload: `[0..1]` = id big-endian, `[2]` = len (if hasLen), `[3]` = 0, params from `[4]` |
| 0x54 | mutex | |

`getData`: pads payload with zeros to ≥ 12 bytes and to an even length; if hasLen writes padded
length to payload[2]. With header: `FE FF | len16 BE | flags | 00 | payload | 00 | cs`,
flags = 0x80 if !hasLen ("command") else 0x00 ("data"); cs = p[0]+p[1]+p[n-2]+p[n-1].

CSeaCmdList (at CCmdExecutor+0x70; vector at +0x98, buffer at +0xb0) concatenates the padded payloads
of all queued commands behind one header with flags 0; `ExeCurCmd` ORs a 4-bit sequence number into
byte 4.

## tagLmcPar (machine parameters) — keys conf

```
0x000 PARNAME(string)        0x014 LASERTYPE            0x018 FIBERTYPE
0x020 OPC_ENPWMOUT (u8)      0x024 OPC_MAXPWMFREQ (f)   0x028 OPC_MINPWMFREQ (f)
0x034 OPC_MAXPWMFREQ_MOPA    0x038 OPC_MINPWMFREQ_MOPA  0x03c OPC_ENPWMTICK (u8)
0x03e OPC_PWMTICKPERIOD(u16) 0x040 OPC_PWMTICKPULSEWIDTH(u16)  0x042 OPC_MoDelay (u16, inf)
0x045 OPC_ENCO2FPK           0x048 OPC_CO2FPKSTARTPOWER 0x04c OPC_CO2FPKINCPOWER
0x054 OPC_ENABLEDIGITALQSWITCH 0x055 OPC_ENABLECLOSEQSWTICH 0x056 OPC_PULSEWIDTHREVERSE
0x057 OPC_FPK (u8)           0x058 OPC_FPKTIME (u16)    0x05a VIOLET_REDLIGHT_MODE2
0x05c OPC_SPIWAVE            0x05e OPC_SPICONTINUES     0x060 OPC_SPISIMMERCUR  0x064 OPC_SPIFPK
0x066 OPC_ENPOWERANALOGOUT   0x067 OPC_ENFREQANALOGOU   0x068 OPC_ENABLEANALOGFPK 0x069 OPC_FPKDIRLOWTOHIGH
0x06c OPC_ANALOGFPKMAXV (f)  0x070 OPC_ANALOGFPKMINV (f) 0x074 OPC_ANALOGFPKTIME (u16) 0x076 OPC_ANALOGFPKTIME2
0x078..0x0a0 OPC_POWERMAP0..10 (f)      0x0a4..0x0cc OPC_POWERANALOGMAP0..10 (f)
0x0d0..0x0f8 OPC_FREQANALOGMAP0..10     0x0fc..0x124 OPC_CURRENTMAP0..10
0x12c.. OPC_RAMPACCMAP0..10  0x158.. OPC_RAMPDECMAP0..10
0x1a8 tagLenPar (head 0, see below)
0x5988 tagMarkPar: 0x59b0 MAX_CLOSE_DIST (f, mm)  0x59b6 LeakPro  0x59f0 GAPLENGTH (f)
        0x59a4 AFTERMODE 0x59a8/ac AFTERPOSX/Y  0x5ac4 REDLIGHTOUTPORT ...
0x650c REDCONTMODE (inf)  0x6514 REDLIGHTSPEED (f, mm/s, default 3000)  0x6518 "RedlightSrc" (inf)
```

## tagLenPar (lens / galvo calibration, at tagLmcPar+0x1a8) — conf unless marked

```
+0x000 LEN_MAXSPEED (f)   +0x004 LEN_MINSPEED (f)  +0x008 LEN_WORKSIZE (d, mm)
+0x010 (d) 80.0 default, 9-point mode only (inf)
+0x018 (i) galvo max = 0xFFFF  +0x01c (i) galvo centre = 0x8000   (tagLmcPar ctor)
+0x020 (d) barrel normaliser = 65535^2 = 4294836225.0             (tagLmcPar ctor)
+0x028 LEN_XYFLIP  +0x02c LEN_XINVERT  +0x030 LEN_YINVERT
+0x038/+0x040 LEN_FIELDOFFSETX/Y (d)  +0x048 LEN_ROTATEANGLE (d, deg)  +0x050/+0x058 LEN_ROTATEOX/OY
+0x060/+0x068 LEN_BUCKETX/Y  +0x070/+0x078 LEN_PRRLX/Y  +0x080/+0x088 LEN_TRAPEX/Y  +0x090/+0x098 LEN_SCALEX/Y
+0x0a0 (i) per-axis table enable, +0x0a4 count (default 21); +0x0a8 XA[], +0x3c8 YA[], +0xd28 XR[], +0x1048 YR[] (inf)
+0x1368/+0x136c REDLIGHTOFFSETX/Y (f)  +0x1370/+0x1374 REDLIGHTSCALEX/Y (f)
+0x1378 LEN_ENABLECORFILE → use correction-file (9-point LSM) path instead of the box formula
+0x1480/+0x1484/+0x1488 flip/invX/invY used in the correction-file path
```

## tagPenPar (0x128 bytes) — keys conf

```
0x004 SWITCHON  0x00c name  0x030 MACHINECOUNT (loops)  0x034 RUNSPEED (i, mm/s)
0x038 LSRPWR (i, %)  0x040 CURRENT (f)  0x044 LSRFREQ (f, kHz)  0x048 LSRZKB (f)  0x04c QPULSE (i)
0x050 OPENDEPLAY (i, µs)  0x054 SHUTDEPLAY (i, µs)  0x058 ENDDEPLAY  0x05c CORNERDEPLAY (i, µs)
0x060 ENABLESTEP  0x064 STEPDEPLAY  0x068 STEPLEN (f)  0x08c DAADVANCE  0x090..0x0b0 power ramp
0x0cc ADV_JUMPSPEED (i, mm/s)  0x0d8 ADV_JUMPMINDELAY (i, µs)  0x0dc ADV_JUMPMAXDELAY (i, µs)
0x0e0 ADV_JUMPMAXDISTANCE (stored as float, mm)  0x0e4 ADV_ENDCOMP  0x0e8 ADV_ACCDISTANCE
0x0ec ADV_POINTTIME (f, ms)  0x0f0 ADV_PULSEPOINTMODE  0x0f4 ADV_PULSEPERPOINT  0x0f8.. wobble
0x108.. end-add-point  0x11c ADV_OPENLIGHTOFFSET (i)  0x120 nWeldExt
```

## Device state (0xAA05 reply, `updateDevBaseState`, payload offset +4) — conf (meaning inf)

```
s[0]  board status (0 reset, 1 ready, 2 run-ready, 3 run, …)   s[1] bits1..6 flags
s[2]  ?            s[4..5] BE "laser state" (must be 0 to start a job)
s[8] bit0 "finished/idle" (WaitForFinish exit condition)   s[9..11] BE24 free buffer, KiB
s[12..15] BE32, s[16..19] BE32 (?)   s[20..21] BE   s[22..23] BE counter   s[24..25] BE mark counter
```
Windows (FUN_10069580) agrees: payload[2] != 0 → error; payload[4] status; payload[12]&1;
payload[13..15] free KiB.

## Device info (0xF0F0 reply, payload incl. echoed id)

`[4..5]` → tagDevInfo+0x48, `[6..17]` (12 bytes) card id, `[42..45]` FPGA version a.b.c.d
(Windows GetSSVersion prints these four bytes; e.g. "1.6.0.8"). Reply payload ≥ 52 bytes.
