# 09 - CAN Networking & Multi-Node Vehicle Buses

> How Renode models a CAN bus, connects multiple ECUs onto it, transports frames,
> arbitrates (and where it *doesn't*), and lets you stimulate, observe, and bridge the
> bus to the real world. Written against an automotive/EV use case - a BMS, motor
> controller, driver-control unit, and telemetry module exchanging heartbeats and data
> frames - but the machinery is generic.
>
> Every claim is cited to source at the bottom (`file:line`). Verified against the
> `renode/` tree and the `renode-infrastructure/` submodule clone at
> `~/renode-infrastructure`.

---

## 0. The one idea to internalize first

**Renode models the *wire* and the *silicon*. Your firmware defines the *protocol*.**

CAN IDs, heartbeats, and conventions like "`0x600` = BMS heartbeat, `0x601` = pack
voltage, `0x402` = motor-controller heartbeat" are **application-level facts that live in
firmware**, not in Renode. Renode's job is two layers below that:

1. emulate the **CAN controller** (e.g. the S32K3's FlexCAN) that your firmware's driver
   reads and writes, and
2. faithfully **transport `CANMessageFrame`s** between every controller attached to a bus.

The hub never interprets an arbitration ID. It carries the frame; the firmware on each
node decides what to send and what to accept. Keep this split in mind - most "does Renode
support X?" questions resolve cleanly once you ask *"is X a property of the wire, the
controller, or the firmware?"*

```
   firmware (BMS app)         ← defines: 0x600 heartbeat, 0x601 data, filter on 0x402
        │ writes TX mailbox / reads RX mailbox
        ▼
   CAN controller model       ← S32K3XX_FlexCAN: mailboxes, filters, local TX arbitration
        │ emits / receives CANMessageFrame
        ▼
   CANHub  ("the bus")        ← broadcasts each frame to every *other* attached controller
        ▲
        │ same interface (ICAN)
   other nodes' controllers + host-side testers + SocketCAN bridge
```

---

## 1. The object model - four layers

| Layer | Type | Role | Source |
|---|---|---|---|
| The bus | `CANHub` | An idealized, collision-free broadcast medium. Every attached interface receives every frame any *other* attached interface sends. | `CANHub.cs` |
| The connector contract | `ICAN` (`: IPeripheral, INetworkInterface`) | What it means to be "a thing you can plug into a CAN hub": raise `FrameSent`, accept `OnFrameReceived`. Implemented by every CAN controller, by `CANTester`, and by the SocketCAN bridge. | `ICAN.cs` |
| The frame | `CANMessageFrame` | One CAN/CAN-FD frame: ID, data, format flags. | `CANMessageFrame.cs` |
| The controller | e.g. `S32K3XX_FlexCAN` | The actual on-chip peripheral your firmware drives: mailboxes, RX filters, IRQs, and *local* TX arbitration. | `S32K3XX_FlexCAN.cs` |

Because the bus contract is just `ICAN`, **anything** implementing it can sit on the same
hub: a real emulated controller running firmware, a scripted host-side `CANTester`, or a
bridge out to your host OS. They are interchangeable from the hub's point of view.

---

## 2. `CANMessageFrame` - the unit of transport

A frame carries everything CAN/CAN-FD needs (`CANMessageFrame.cs`):

| Member | Meaning |
|---|---|
| `Id` | 11-bit standard or 29-bit extended arbitration ID (`StandardIdWidth = 11`, `ExtendedIdWidth = 29`). Your `0x402`, `0x600`, `0x601`… are just this value. |
| `Data` | payload bytes - up to 8 (classic) or 64 (CAN-FD). |
| `ExtendedFormat` | standard (11-bit) vs extended (29-bit) ID. |
| `RemoteFrame` | RTR - remote request frame. |
| `FDFormat` | CAN-FD frame. |
| `BitRateSwitch` | CAN-FD BRS (data-phase bit-rate switch). |
| `DataAsHex` | pretty-printed payload, used in logs. |

Construction helpers: the plain constructor takes `(id, data, …)`; `CreateWithExtendedId`
handles the standard/extended bit-shifting; `ExtendedId` / `StandardIdPart` /
`ExtendedIdPart` decompose a 29-bit ID. There is also `TryFromSocketCAN` / `ToSocketCAN`
for the host bridge (§8).

> **Implication:** a "message type" in your protocol *is* a `CANMessageFrame.Id`. Renode
> imposes no schema on `Data` - a DBC/signal layout is entirely a firmware/tooling concern.

---

## 3. Wiring nodes onto a bus - the `.resc` commands

Two Monitor commands build an entire network:

```
emulation CreateCANHub "canHub"          # create the bus (an "external", not a machine)
connector Connect sysbus.can0 canHub     # plug a controller into it
```

- `CreateCANHub` is an `Emulation` extension: `CreateCANHub(name, loopback = false,
  useNetworkByteOrderForLogging = true)` (`CANHub.cs:26`). `loopback = false` means a
  sender does **not** receive its own frames (the real-bus default); `true` echoes them
  back - occasionally handy for single-node tests.
- `connector Connect <iface> <hub>` attaches any `ICAN` to the hub. The interface can be
  named by its sysbus path (`sysbus.can0`) or a bare alias (`fdcan1`).

### The canonical multi-node example - RAMN (4 ECUs on one bus)

`scripts/multi-node/ramn.resc` is the reference topology and the closest in-tree analogue
to a vehicle bus (it runs Toyota's real RAMN firmware - four ECUs named
GATEWAY / CHASSIS / POWERTRAIN / BODY):

```
emulation CreateCANHub "canHub"

set global.name "ECUA"
include @scripts/single-node/ramn.resc        # creates a machine, loads its firmware
connector Connect sysbus.fdcan1 canHub        # … and plugs it onto the shared bus

set global.name "ECUB"
include @scripts/single-node/ramn.resc
connector Connect sysbus.fdcan1 canHub

set global.name "ECUC"
include @scripts/single-node/ramn.resc
connector Connect sysbus.fdcan1 canHub

set global.name "ECUD"
include @scripts/single-node/ramn.resc
connector Connect sysbus.fdcan1 canHub

emulation SetGlobalQuantum "0.00001"          # tighten sync for CAN responsiveness (§5)
```

The per-node `single-node/ramn.resc` is parameterized by `$global.name`: it does
`mach create $name`, includes the board `.repl`, then selects the matching firmware ELF
and personality `.repl`. **This is exactly the pattern for a BMS/MC/DCU/telemetry network**
- one `single-node` script per ECU role, included once per node, each `connector
Connect`'d to the same hub.

---

## 4. The S32K388 as a CAN node

The in-tree `nxp-s32k388` model (a quad-core **Cortex-M7**) already exposes the full CAN
interface set, so each node has plenty of controllers (`platforms/cpus/nxp-s32k388.repl`):

| Bus | Count | Model type |
|---|---|---|
| FlexCAN | 8 (`can0`–`can7`) | `CAN.S32K3XX_FlexCAN` |
| LPUART | 16 | `UART.NXP_LPUART` |
| LPSPI | 6 | `SPI.IMXRT_LPSPI` |
| LPI2C | 2 | `I2C.S32K3XX_LowPowerInterIntegratedCircuit` |

A board file `platforms/boards/nxp-s32k388evb.repl` wraps the CPU as an EVB. The smaller
`s32k118` (Cortex-M0+) is also present if a low-end node is wanted. Connect any of the
eight FlexCAN instances to a hub: `connector Connect sysbus.can0 canHub`.

---

## 5. Arbitration - read this carefully (two layers, only one modeled)

"Who does CAN arbitration?" has a layered answer in Renode.

### 5a. Local (intra-controller) arbitration - **modeled**

The FlexCAN model decides which of *its own* pending TX mailboxes transmits next.
`RunArbitrationProcess()` either iterates buffers in index order when **Lowest Buffer
Transmitted First** (`CTRL1.LBUF`) is set, or otherwise sorts the controller's message
buffers by their priority field (`OrderBy(-MessageBuffer.Priority)`) and transmits in that
order (`S32K3XX_FlexCAN.cs:405,424,434`). This faithfully reproduces the real FlexCAN's
*local* mailbox arbitration. So **within a single node**, "which of my queued frames goes
first" behaves correctly.

### 5b. Bus-level (inter-node) arbitration - **NOT modeled**

On real hardware, arbitration is a **distributed, emergent, bit-by-bit** physical-layer
process: every transmitter watches the wire while it sends, dominant bits beat recessive
ones, the lowest ID wins **non-destructively**, and losers automatically back off and
retransmit. No chip "performs" it.

Renode's `CANHub` does none of this. `Transmit()` takes a fully-formed frame from a sender
and delivers it to every *other* attached interface as a discrete, atomic virtual-time
event (`CANHub.cs:98`; the broadcast loop `attached.Where(x => x != sender || loopback)`
at `:133`). The whole emulation is serialized by the time framework (`lock(sync)` +
`HandleTimeDomainEvent(..., vts)`), so two nodes are **never literally on the wire in the
same bit-time**. Consequently:

| Real CAN behavior | In Renode |
|---|---|
| Bit-by-bit dominant/recessive contention | ❌ not modeled |
| Lowest ID wins *across nodes* | ❌ - delivery order is scheduler order, **not** ID priority |
| Destructive collision / lost arbitration | ❌ no frame is ever lost to contention |
| Automatic retransmit on arbitration loss | ❌ |
| Error frames, TEC/REC counters driven by bus contention | ❌ |
| Busload-dependent frame latency / jitter | ❌ (fidelity is frame/event-level, not bit-level) |
| **Acceptance filtering by ID (what each node receives)** | ✅ faithful - firmware RX filters/mailboxes |
| **Local mailbox TX priority within one controller** | ✅ faithful (§5a) |

**Net:** the FlexCAN arbitrates among *its own* mailboxes; the hub does **no** inter-node
arbitration - it is a perfect, ordered, collision-free broadcast bus.

### What this means in practice

- ✅ **Functional/integration logic is faithful and *more* reproducible than hardware.**
  Does the BMS emit `0x600/0x601/0x602`? Does the DCU accept them and ignore everything
  else? Does a missed heartbeat trip a timeout/fault? All correct and deterministic.
- ⚠️ **Bus-contention physics is not faithful.** Anything depending on priority inversion,
  arbitration-loss timing, retransmission jitter, error-counter escalation, or latency
  under bus saturation will **not** reproduce real behavior out of the box.
- If you need that, you'd extend the hub yourself - e.g. queue concurrent transmits within
  a bit-time window and resolve by ID, and synthesize bus-error/back-off behavior. It is
  not built in. (Flagged here as a known boundary; see §11.)

---

## 6. Determinism & timing

CAN behavior depends on every node's clock being coherent. Two Monitor knobs govern this:

- `emulation SetGlobalQuantum "<seconds>"` - the synchronization granularity. Tighter =
  more faithful inter-node timing, slower wall-clock. The RAMN multi-node script uses
  `0.00001` (10 µs); the FlexCAN test uses `0.000025` (25 µs).
- `emulation SetGlobalSerialExecution True` - forces strictly serialized node execution,
  used by the FlexCAN test for fully deterministic frame ordering
  (`tests/peripherals/S32K3XX_FlexCAN.robot`).

Heartbeats are simply periodic frames: under real firmware they come off the node's own
timers; under host stimulation (§7) you emit them from a loop. Because timing is
deterministic, a **dropped-heartbeat → timeout → fault** sequence is fully reproducible -
the main reason to test BMS safety logic here rather than on a flaky bench.

---

## 7. Stimulating & testing the bus without firmware - `CANTester`

You don't need every ECU's firmware to start. `CANTester` is a host-side virtual node that
implements `ICAN`, so it plugs onto the hub like any controller (`CANTester.cs`):

- `SendFrame(CANMessageFrame)` - inject an arbitrary frame (e.g. a synthetic `0x402` MC
  heartbeat) onto the bus (`CANTester.cs:214`).
- `WaitForMessageFrame(CANMatcher, …)` - block until a matching frame appears
  (`CANTester.cs:224`). `CANMatcher(singleId: 0x600)` matches by exact ID
  (`CANTester.cs:312`).
- ISO-TP / UDS helpers - `SendISOTPMessage`, `WaitForISOTPMessage`,
  `SendUDSCommandAndWaitForPositiveResponse` for multi-frame transport and diagnostics
  (`CANTester.cs:49`).

These are exposed as **Robot Framework keywords** for automated tests
(`RobotFrameworkEngine/CANKeywords.cs`):

| Keyword | Purpose |
|---|---|
| `Create CAN Tester <hub>` | attach a tester to a hub |
| `Wait For Frame With Id <id>` | assert a frame with that ID was broadcast |
| `Send ISOTP Message` / `Wait For ISOTP Message Hex` | multi-frame transport |
| `Send UDS Command And Wait For Positive Response` | diagnostics over CAN |
| `Set Default CAN Timeout` | tune the wait timeout |

So you can bring up **just the BMS node**, inject a fake MC heartbeat, and assert the BMS
broadcasts `0x600/0x601/0x602` correctly - before any other ECU exists. The FlexCAN Robot
suite is a working template: it does `emulation CreateCANHub "${CAN_HUB}" False`, includes
a per-node `.resc`, then `connector Connect ${CAN} ${CAN_HUB}`
(`tests/peripherals/S32K3XX_FlexCAN.robot:11–19`).

---

## 8. Observability - watching the bus like a sniffer

- **Wireshark.** `CANHub` implements `INetworkLog<ICAN>`, and the Wireshark plugin exposes
  `emulation CreateWiresharkForCAN "<name>"` plus `LogToWireshark`
  (`INetworkLogExtensions.cs:31,41`). You get a live capture of every frame - watch
  `0x600/0x601/0x602` scroll exactly like candump or PCAN-View.
- **Logging.** The hub logs each `sender → message` at `Debug` level out of the box
  (`CANHub.cs` `Transmit`, the `this.Log(LogLevel.Debug, …)` call).
- **Events for custom decoders/assertions.** `CANHub` raises `FrameReceived` (sender →
  hub), `FrameProcessed` (frame accepted for distribution), and `FrameTransmitted` (hub →
  each receiver) - `CANHub.cs:92–96`. Hook these to decode signals or build invariants.

---

## 9. Bridging to the real world - SocketCAN

`CANHub` can be tied to a host SocketCAN interface so **real tools see the emulated bus**:

```
emulation CreateCANHub "canHub"
connector Connect fdcan1 canHub

machine CreateSocketCANBridge "socketcan"   # default host iface name: vcan0
connector Connect socketcan canHub          # bridge is just another ICAN on the hub
```

(`scripts/complex/socketcan_bridge/nucleo_h743zi-socketcanbridge.resc`;
`SocketCANBridge.cs`, `SocketCAN.cs`; frame conversion via
`CANMessageFrame.ToSocketCAN` / `TryFromSocketCAN`.)

Once bridged, `candump`, `cangen`, `python-can`, BusMaster, or your actual telemetry
backend interact with the emulated BMS as if it were physical hardware - so a telemetry
module or DCU dashboard can even run as a host process consuming the emulated frames
upstream. (Linux SocketCAN / `vcan` only.)

---

## 10. Sensors on each node (SPI / I2C / UART)

Sensors attach to a node's bus controller in the `.repl`, addressed per bus:

```
bmp180:  Sensors.BMP180  @ i2c 0x77          # I2C address
lsm330_a: Sensors.LSM330_Accelerometer @ i2c 0x18
lm74:    Sensors.TI_LM74 @ spi0              # SPI chip-select / bus
si7021:  Sensors.SI70xx  @ i2c 5
```

(Real registrations from in-tree platforms - note I2C devices take an address, SPI devices
register on the SPI controller; sub-devices can chain off a parent, e.g. a magnetometer
`@ icm 0xC`.)

The sensor library lives at
`renode-infrastructure/src/Emulator/Peripherals/Peripherals/Sensors/`. EV-relevant models
present today include:

- **IMU / accel / gyro:** `LSM6DSO_IMU`, `LSM9DS1_IMU`, `ICM20948`, `ADXL345`, `ADXL372`,
  `MC3635`, `LIS2DW12`, `LIS2DS12`
- **Temperature:** `TMP103`, `TMP108`, `AS6221`, `TI_LM74`, `MAX30208`, `MAX6682MUA`
- **Pressure / environment:** `BMP180`, `LPS25HB`, `ICP_101xx`, `HS3001`, `SI70xx`
- **Power / current / PMIC:** `PAC1934`, `MAX77818` (useful for pack/BMS monitoring)

When a specific part isn't modeled, there are **base classes to roll your own**:
`GenericSPISensor`, `ST_I2CSensorBase`, `DummySensor`. (Authoring a new peripheral is
covered in `03-csharp-peripherals.md`; registering it in a `.repl` in `01-repl-format.md`.)

---

## 11. Mapping the EV/BMS scenario → Renode

| Your concept | Renode realization |
|---|---|
| The CAN bus | one `CANHub` (`emulation CreateCANHub`) |
| BMS / MC / DCU / telemetry nodes | S32K388 machines running real firmware, or `CANTester`/host stubs |
| Node CAN_ID & "broadcasts `0x600/0x601/0x602`" | firmware loads TX mailboxes; FlexCAN emits frames with those `Id`s |
| "BMS listens for MC heartbeat `0x402`" | firmware RX acceptance filter on a FlexCAN mailbox (✅ faithful) |
| Heartbeat timing | firmware timer (real fw) or scripted loop (`CANTester`); `SetGlobalQuantum` for sync |
| Missed heartbeat → fault | deterministic & reproducible via the time framework |
| DCU displays / telemetry forwards | another hub node, or a host process over the SocketCAN bridge |
| Sniff / verify the bus | `CreateWiresharkForCAN`, hub `Debug` logs, `Wait For Frame With Id` |
| Sensors on a node | `Sensors.*` models registered on `i2c`/`spi`/`uart` (§10) |
| Bus arbitration / priority under load | ⚠️ **not modeled at bit level** - see §5b |

### Fidelity boundaries (consolidated)

**Faithful:** controller register behavior, mailbox/filter semantics, local TX priority,
ID-based acceptance, frame payloads, IRQ delivery, deterministic timing, multi-node
routing, host bridging.

**Not modeled out of the box:** bit-level inter-node arbitration, destructive collisions,
lost-arbitration retransmit, error frames / TEC-REC escalation from contention, exact
busload-dependent latency. These require extending the hub.

---

## 12. Copy-paste skeletons

### A. Two-node bus: BMS firmware + synthetic MC heartbeat (Robot)

```
*** Test Cases ***
BMS Emits Heartbeat After Seeing MC
    Execute Command    emulation CreateCANHub "canHub" False
    # --- BMS node (real firmware) ---
    Execute Command    mach create "bms"
    Execute Command    machine LoadPlatformDescription @platforms/boards/nxp-s32k388evb.repl
    Execute Command    sysbus LoadELF @bms-firmware.elf
    Execute Command    connector Connect sysbus.can0 canHub
    # --- host-side stand-in for the motor controller ---
    ${mc}=  Create CAN Tester    canHub
    Execute Command    emulation SetGlobalQuantum "0.00001"
    Start Emulation
    # MC heartbeat 0x402, then expect BMS heartbeat 0x600
    Send Frame         ${mc}    0x402    00 00
    Wait For Frame With Id    0x600    timeout=1
    Wait For Frame With Id    0x601    timeout=1     # pack data
```

### B. Multi-ECU network (`.resc`, RAMN-style)

```
emulation CreateCANHub "canHub"

set global.name "BMS"
include @scripts/single-node/<your-bms>.resc
connector Connect sysbus.can0 canHub

set global.name "MC"
include @scripts/single-node/<your-mc>.resc
connector Connect sysbus.can0 canHub

set global.name "DCU"
include @scripts/single-node/<your-dcu>.resc
connector Connect sysbus.can0 canHub

emulation CreateWiresharkForCAN "canSniff"     # live capture of the whole bus
emulation SetGlobalQuantum "0.00001"
```

### C. Bridge the bus to host tooling

```
machine CreateSocketCANBridge "socketcan"      # appears as vcan0 on the host
connector Connect socketcan canHub
# then on the host:  candump vcan0   /   python-can, etc.
```

---

## 13. References (source-verified)

| Fact | Source |
|---|---|
| Hub creation, `loopback` / byte-order options | `renode-infrastructure/src/Emulator/Extensions/Tools/Network/CANHub.cs:26` |
| Frame distribution = broadcast to all but sender; virtual-time delivery | `…/CANHub.cs:98` (`Transmit`), `:133` (`attached.Where(x => x != sender \|\| loopback)`) |
| Hub events `FrameReceived` / `FrameProcessed` / `FrameTransmitted` | `…/CANHub.cs:92–96` |
| `ICAN` contract (`FrameSent`, `OnFrameReceived`) | `renode-infrastructure/src/Emulator/Main/Peripherals/CAN/ICAN.cs:17,19,21` |
| Frame fields & ID widths (11/29-bit), FD/BRS/RTR, SocketCAN conv. | `renode-infrastructure/src/Emulator/Main/Peripherals/CAN/CANMessageFrame.cs:58,108–129` |
| Host tester: `SendFrame`, `WaitForMessageFrame`, `CANMatcher`, ISO-TP/UDS | `renode-infrastructure/src/Emulator/Main/Testing/CANTester.cs:214,224,312,49` |
| Robot keywords (`Create CAN Tester`, `Wait For Frame With Id`, UDS/ISO-TP) | `renode/src/Renode/RobotFrameworkEngine/CANKeywords.cs` |
| Local TX arbitration: priority sort / lowest-buffer-first | `renode-infrastructure/.../CAN/S32K3XX_FlexCAN/S32K3XX_FlexCAN.cs:405,424,434,504` |
| S32K388 CAN/UART/SPI/I2C inventory; Cortex-M7 ×4 | `renode/platforms/cpus/nxp-s32k388.repl` |
| S32K388 EVB board; S32K118 (Cortex-M0+) | `renode/platforms/boards/nxp-s32k388evb.repl`, `renode/platforms/cpus/s32k118.repl` |
| Multi-node bus topology (4 ECUs) | `renode/scripts/multi-node/ramn.resc`, `renode/scripts/single-node/ramn.resc` |
| Determinism knobs (`SetGlobalQuantum`, `SetGlobalSerialExecution`) | `renode/tests/peripherals/S32K3XX_FlexCAN.robot:11–19,42–43` |
| Wireshark CAN capture (`CreateWiresharkForCAN`, `LogToWireshark`); hub is `INetworkLog<ICAN>` | `renode/src/Plugins/WiresharkPlugin/INetworkLogExtensions.cs:31,41`; `…/CANHub.cs` class decl |
| SocketCAN host bridge | `renode/scripts/complex/socketcan_bridge/nucleo_h743zi-socketcanbridge.resc`; `renode-infrastructure/.../CAN/SocketCANBridge.cs`, `…/CAN/SocketCAN.cs` |
| Sensor models + base classes; bus registration syntax | `renode-infrastructure/src/Emulator/Peripherals/Peripherals/Sensors/` (`GenericSPISensor`, `ST_I2CSensorBase`, `DummySensor`, etc.) |

> **Provenance note.** §5b (no bit-level inter-node arbitration) is an inference from
> reading `CANHub.Transmit` end-to-end - the hub forwards each frame unconditionally to all
> non-sender interfaces with no priority comparison, contention queue, or retransmit path -
> cross-checked against the absence of any `arbitration`/`backoff`/`retransmit` logic in the
> hub. The *local* FlexCAN arbitration in §5a **is** present and cited. If you later need
> bus-contention fidelity, that gap is the thing to build (§5 "What this means").
