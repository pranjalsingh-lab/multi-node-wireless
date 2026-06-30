# SimEV - Spec 01: ECU Configurator & Descriptor Schema

> **What this document is.** A complete design spec for the first milestone of SimEV: a web
> app where an EV customer describes each of their ECUs (CAN identity, the frames it
> broadcasts/consumes, heartbeats, expected responses, fault conditions) in a form that is
> *both* easy for them to fill in *and* directly usable by us to drive a Renode-based CAN
> simulation later.
>
> This milestone produces **no Renode wiring** - only the configurator UI and the data
> model that everything downstream will be generated from. But the schema is designed
> against the Renode mapping (see §11) so that nothing has to be reworked when we get there.
>
> Scope, stack, and input-method decisions in §0 are **locked** (confirmed with the
> stakeholder). Everything else is proposal-grade and open to revision.

---

## 0. Locked decisions (read first)

| Decision | Choice | Rationale |
|---|---|---|
| **Stack** | Next.js 14 + React 18 + TypeScript + Tailwind 3 (App Router, `src/` dir) | Rich UI for DBC upload + editing; same app can later host the results dashboard. Pinned to 14/18/3 because the build host runs **Node 18** and Next 16 / Tailwind 4 require Node ≥20 (see §13). |
| **Primary input** | **DBC/ARXML import-first, manual entry as fallback** | Every CAN ECU already has a DBC (or AUTOSAR ARXML). Re-typing IDs/signals is the painful, error-prone part. Import it; manual entry covers ECUs without a file and quick edits. |
| **Milestone 1 scope** | **Configurator + descriptor schema only** | Nail the data model and the entry/import/annotate UI. No Renode generation, no run orchestration this milestone. |
| **Renode vendoring** | **Deferred** - not pulled into the repo this milestone | `renode` + `renode-infrastructure` are large; the configurator doesn't touch them. Vendor (as submodules) in the simulation milestone (§13). |

---

## 1. Premise & problem statement

We are building firmware-testing-as-a-service for an EV company. Their vehicle is a set of
ECUs (BMS, motor controller, driver-control unit/VCU, telemetry module, gateway, charger…)
talking over one or more CAN buses. We want to:

- **Simulate CAN traffic** against their firmware and observe how it behaves.
- **Flag wrong responses** (firmware answered incorrectly or not at all).
- **Exercise edge conditions**: bus overload, missed heartbeats, malformed frames,
  out-of-range signals, fault injection.

The simulation engine is **Renode** (see [`../09-can-networking.md`](../09-can-networking.md)
for the full model). Renode emulates the *wire* (a `CANHub` broadcast bus) and the *silicon*
(the CAN controller, e.g. NXP FlexCAN, that the firmware drives). The firmware runs unmodified
inside the emulated MCU.

**This spec covers only the front door: capturing what each ECU *is*.** Until we know each
ECU's CAN contract and what "correct" looks like, we cannot generate stimulation or judge
responses.

---

## 2. The core mental model (why the configurator is load-bearing)

**The firmware is a black box, so the contract must be supplied - it cannot be discovered.**

Two reasons:

1. **It arrives encrypted.** We cannot statically read message/signal definitions out of an
   encrypted image.
2. **Even unencrypted, it wouldn't help.** Recovering a CAN database from a stripped binary is
   not realistic. CAN message layouts live in the build's DBC/ARXML and in firmware tables we
   can't reliably recover.

In Renode the firmware is **executed**, not parsed: we *stimulate* it and *observe* what comes
back. Therefore the ECU descriptor the customer fills in is not a convenience - it **is** the
specification of the black box:

```
ECU descriptor  =  the CAN interface contract  +  the test oracle
                   (what's on the wire)            (what counts as correct)
```

Everything downstream keys off this one model:

- **Stimulation** - what frames to inject, at what cadence → from the *contract* (TX cycle
  times) and *intent* (heartbeats, request triggers).
- **Pass/fail** - did the ECU respond correctly/in time → from the *intent* (expectations).
- **Fault campaigns** - what to perturb and what should happen → from the *intent* (fault
  scenarios + heartbeat tolerances).

This is why the schema (§5) is the centerpiece of the whole project, not just this milestone.

### 2.1 The contract / intent split

The single most important design idea in the schema:

| Layer | Comes from | Examples | Who owns it |
|---|---|---|---|
| **Contract** | DBC/ARXML import (or manual) | message IDs, DLC, signals, cycle times, sender/receivers | The customer's existing build artifacts |
| **Intent** | Annotation on top of the contract | "this message is the heartbeat; period 100 ms ±20", "when I send 0x402, expect 0x600 within 50 ms", "signal `PackVoltage` must stay 0–600 V" | **Us, with the customer** - this is the product's value |

A DBC tells you the messages exist. It does **not** tell you which one is a heartbeat, what a
request should trigger, what tolerance is acceptable, or what counts as overload. We never make
the customer re-enter contract data; we make them *annotate* it. Keeping these two layers
structurally separate (not interleaved) means a re-import of an updated DBC can refresh the
contract **without clobbering** the intent annotations.

---

## 3. Milestone scope

### In scope (Milestone 1)

- The **descriptor schema** (Zod = single source of truth; TS types derived from it).
- **Project / network** model: buses + ECUs + topology bindings.
- **DBC import**: parse a `.dbc`, map nodes→ECUs, messages/signals→contract, split TX/RX per
  ECU, pull cycle times and value tables. One DBC can populate many ECUs at once (§6.3).
- **Manual entry**: add/edit ECUs, messages, signals by hand.
- **Annotation UI** (the intent layer): mark heartbeats, define expectations, capture
  diagnostics (ISO-TP/UDS) addressing, list fault scenarios of interest.
- **Persistence**: projects stored as inspectable JSON (file-based via API routes) + export/
  import + localStorage autosave (§9).
- **Structural validation**: whatever Zod gives us for free (types, ranges, required fields).

### Out of scope (later milestones - see §14)

- ARXML *full* parsing (interface scaffolded + detected; deep parse is a fast-follow, §7).
- Cross-entity **lint** (ID collisions, signal-bit overlap, DLC overflow) - this was the
  "Configurator + validation" option we did **not** pick; it's M2 (§10).
- **Renode generation** (`.resc`/`.repl`/`CANTester` stim/Robot) - M3.
- **Run orchestration** + results/Wireshark dashboard - M4.
- **Fault-injection execution** - M5.
- **Encrypted-firmware ingestion / secure-boot emulation** - M6 (the biggest unknown, §15).

---

## 4. Architecture & stack

```
┌──────────────────────────────────────────────────────────────┐
│  Next.js 14 app (App Router, src/)                            │
│                                                              │
│  UI (React + Tailwind)        ◀── edits ──▶  Project JSON     │
│   • Project dashboard                          (the schema)   │
│   • ECU editor (tabs)                              ▲          │
│   • DBC/ARXML import wizard                        │          │
│   • Annotation builders               parse / validate        │
│                                                   │          │
│  lib/                                              │          │
│   • schema/   ← Zod = single source of truth ─────┘          │
│   • dbc/      ← .dbc → contract messages/signals             │
│   • arxml/    ← scaffolded (M1), full parse later            │
│   • validation/ ← structural now, lint later                 │
│                                                              │
│  API route handlers (server)                                 │
│   • /api/projects  ← read/write JSON files in data/          │
└──────────────────────────────────────────────────────────────┘
                              │
                  data/<project>.json   (git-trackable, feeds Renode gen later)
```

**Key principle:** the UI is a *view over the schema*. The same Zod schema validates DBC
import output, validates manual input, types every component, and (in M3) is the input to the
Renode generator. There is exactly one source of truth for "what an ECU is."

**Why file-based JSON persistence (not a DB) for M1.** Projects are small, human-readable, and
we want them diffable and git-trackable so the eventual Renode generator can consume them and
so we can ship example projects. A database adds nothing this milestone. Export/import lets the
customer hand us a project without our hosting it.

---

## 5. The descriptor schema (the centerpiece)

### 5.1 Design principles

1. **One source of truth**: authored as Zod; TS types are `z.infer`red; JSON Schema can be
   emitted from it if an external consumer needs it.
2. **Contract vs intent are sibling objects**, never interleaved (§2.1) - re-import refreshes
   `contract`, preserves `intent`.
3. **Numbers stored as numbers; hex shown in UI.** IDs are stored as integers plus a cached
   hex string for display; we never round-trip through strings for logic.
4. **Per-ECU direction.** A shared DBC describes a whole bus; each ECU descriptor records, for
   each message, whether *this* ECU transmits or receives it.
5. **Forward-compatible**: every field that the Renode generator (§11) will need is present
   now, even if the UI doesn't surface all of it in M1 (it's then optional/defaulted).
6. **Versioned**: top-level `schemaVersion` so migrations are explicit.

### 5.2 Object hierarchy

```
Project
├── meta            (id, name, description, schemaVersion, timestamps)
├── buses[]         CanBus      (one per physical CAN bus in the vehicle)
└── ecus[]          Ecu
    ├── identity    (id, name, role, vendor, partNumber, description)
    ├── target      EmulationTarget   (board/cpu/controller model - for Renode later)
    ├── busBindings[]  BusBinding      (which bus via which controller instance)
    ├── firmware    FirmwareRef        (artifact ref, format, encrypted, load addr)
    ├── contract    Contract           ← DBC/ARXML-derived ("what's on the wire")
    │   ├── source  (dbc | arxml | manual) + sourceFile
    │   └── messages[]  CanMessage
    │       └── signals[]  CanSignal
    └── intent      Intent             ← our annotations ("what's correct / to test")
        ├── heartbeats[]    HeartbeatSpec
        ├── expectations[]  Expectation        (the test oracle)
        ├── signalChecks[]  SignalCheck        (range / plausibility)
        ├── diagnostics     Diagnostics        (ISO-TP/UDS addressing)
        └── faultScenarios[] FaultScenario     (campaigns of interest; stub in M1)
```

### 5.3 Field reference

#### `CanBus`
| Field | Type | Notes |
|---|---|---|
| `id` | slug | unique within project, e.g. `powertrain` |
| `name` | string | display name |
| `protocol` | `classic \| fd` | classic CAN 2.0 vs CAN-FD |
| `nominalBitrate` | int (bit/s) | e.g. `500000` |
| `dataBitrate` | int? | FD data-phase rate, e.g. `2000000` (required if `fd`) |
| `samplePoint` | float? | optional, 0–1 |
| `description` | string? | |

> Note: the Renode `CANHub` itself is bit-rate-agnostic (it's an idealized broadcast medium),
> but bitrate matters for **controller** config and SocketCAN bridging, and documents intent.
> We capture it now.

#### `Ecu.identity`
| Field | Type | Notes |
|---|---|---|
| `id` | slug | unique within project, e.g. `bms` |
| `name` | string | "Battery Management System" |
| `role` | enum | `BMS \| MotorController \| VCU \| Telemetry \| Gateway \| BodyControl \| Charger \| Other` |
| `vendor`, `partNumber`, `description` | string? | optional |

#### `Ecu.target` - `EmulationTarget` (needed for Renode in M3; optional in M1)
| Field | Type | Notes |
|---|---|---|
| `board` | string? | Renode board `.repl`, e.g. `nxp-s32k388evb` |
| `cpu` | string? | e.g. `nxp-s32k388` (Cortex-M7 ×4) |
| `controllerModel` | string? | e.g. `CAN.S32K3XX_FlexCAN` |
| `notes` | string? | |

> Defaults to the S32K388 family (8× FlexCAN) since that's the in-tree reference node
> (§4 of the CAN doc). Customer can override per ECU.

#### `Ecu.busBindings[]` - `BusBinding`
| Field | Type | Notes |
|---|---|---|
| `busId` | ref→CanBus | which bus |
| `controllerInstance` | string | controller name on that node, e.g. `can0` / `fdcan1` |

> An ECU may bind to **multiple** buses (a gateway). This is what the Renode generator turns
> into `connector Connect sysbus.<controllerInstance> <hubForBus>`.

#### `Ecu.firmware` - `FirmwareRef` (metadata only in M1; no upload processing)
| Field | Type | Notes |
|---|---|---|
| `artifact` | string? | filename / hash / handle |
| `format` | `elf \| bin \| hex \| unknown` | |
| `encrypted` | bool | flags the M6 secure-boot track (§15) |
| `loadAddress` | int? | for `bin` |
| `entryPoint` | int? | optional |
| `notes` | string? | decryption/boot notes |

#### `Contract`
| Field | Type | Notes |
|---|---|---|
| `source` | `dbc \| arxml \| manual` | provenance |
| `sourceFile` | string? | original filename, for re-import |
| `messages[]` | `CanMessage[]` | |

#### `CanMessage`
| Field | Type | Notes |
|---|---|---|
| `id` | int | numeric arbitration ID |
| `idHex` | string | cached display value, e.g. `0x600` (derived) |
| `idFormat` | `standard \| extended` | 11-bit vs 29-bit |
| `name` | string | from DBC `BO_` |
| `dlc` | int | payload length (0–8 classic, 0–64 FD) |
| `protocol` | `classic \| fd` | |
| `brs` | bool | FD bit-rate switch (only meaningful if `fd`) |
| `direction` | `tx \| rx` | **relative to this ECU** |
| `txType` | `cyclic \| event \| cyclicEvent \| none` | `none` for `rx`; from DBC `GenMsgSendType` |
| `cycleTimeMs` | int? | from DBC `GenMsgCycleTime`; required if cyclic |
| `sender` | string? | DBC transmitter node name (informational) |
| `receivers` | string[]? | union of signal receivers (informational) |
| `comment` | string? | DBC `CM_` |
| `signals[]` | `CanSignal[]` | |

#### `CanSignal`
| Field | Type | Notes |
|---|---|---|
| `name` | string | |
| `startBit` | int | |
| `length` | int | bits |
| `byteOrder` | `littleEndian \| bigEndian` | Intel (1) / Motorola (0) in DBC |
| `valueType` | `unsigned \| signed \| float \| double` | sign from DBC `@..+/-`; float via extended attrs |
| `factor` | number | scale |
| `offset` | number | |
| `min`, `max` | number? | physical range |
| `unit` | string? | |
| `receivers` | string[]? | nodes that consume it |
| `mux` | `{ role: none\|multiplexor\|multiplexed, value?: int }` | DBC `m<n>`/`M` |
| `valueTable` | `Record<int,string>?` | from DBC `VAL_` (enums) |
| `comment` | string? | |

#### `Intent.heartbeats[]` - `HeartbeatSpec`
| Field | Type | Notes |
|---|---|---|
| `messageRef` | ref→message (by id) | the heartbeat frame |
| `direction` | `emit \| monitor` | ECU *emits* its own heartbeat, or *monitors* another node's |
| `periodMs` | int | expected period |
| `toleranceMs` | int | acceptable jitter |
| `missedThreshold` | int | N consecutive misses → fault |
| `expectedReaction` | string? | free text now; structured later (link to an Expectation) |

#### `Intent.expectations[]` - `Expectation` (the oracle: stimulus → required reaction)
| Field | Type | Notes |
|---|---|---|
| `id`, `name` | string | |
| `trigger` | `Trigger` | what we inject/observe as the stimulus |
| `expect` | `Reaction` | what the ECU must do |
| `withinMs` | int | deadline |
| `description` | string? | |

```
Trigger  = { kind: 'frame',   messageRef, signalConditions?: SignalCond[] }
         | { kind: 'silence', messageRef, forMs }          // e.g. stop sending MC heartbeat
         | { kind: 'sequence', steps: Trigger[] }
Reaction = { kind: 'frame',   messageRef, signalConditions?: SignalCond[] }
         | { kind: 'noFrame',  messageRef }                 // must NOT emit
SignalCond = { signal: string, op: '=='|'!='|'<'|'<='|'>'|'>='|'in', value }
```

#### `Intent.signalChecks[]` - `SignalCheck` (range / plausibility, for overload/out-of-range)
| Field | Type | Notes |
|---|---|---|
| `signalRef` | `{ messageId, signal }` | |
| `range` | `{ min, max }` | physical-value bounds |
| `onViolation` | `flag \| fail` | |

#### `Intent.diagnostics` - `Diagnostics`
| Field | Type | Notes |
|---|---|---|
| `isotp` | `{ reqId, respId, addressing: normal\|extended, padding?: int }?` | maps to Renode ISO-TP keywords |
| `udsServices` | `string[]?` | supported SIDs/DIDs (captured now, exercised in M4/M5) |

#### `Intent.faultScenarios[]` - `FaultScenario` (stub in M1; defines M5 campaigns)
| Field | Type | Notes |
|---|---|---|
| `type` | enum | `missedHeartbeat \| busFlood \| malformedFrame \| signalOutOfRange \| dropFrames \| idCollision` |
| `params` | object | type-specific |
| `expectedOutcome` | string? | |

### 5.4 Zod sketch (illustrative - not final code)

```ts
// src/lib/schema/ecu.ts
import { z } from "zod";

export const CanSignal = z.object({
  name: z.string(),
  startBit: z.number().int().min(0),
  length: z.number().int().min(1),
  byteOrder: z.enum(["littleEndian", "bigEndian"]),
  valueType: z.enum(["unsigned", "signed", "float", "double"]),
  factor: z.number().default(1),
  offset: z.number().default(0),
  min: z.number().optional(),
  max: z.number().optional(),
  unit: z.string().optional(),
  receivers: z.array(z.string()).optional(),
  mux: z.object({
    role: z.enum(["none", "multiplexor", "multiplexed"]).default("none"),
    value: z.number().int().optional(),
  }).default({ role: "none" }),
  valueTable: z.record(z.string()).optional(),
  comment: z.string().optional(),
});

export const CanMessage = z.object({
  id: z.number().int().min(0),
  idFormat: z.enum(["standard", "extended"]),
  name: z.string(),
  dlc: z.number().int().min(0).max(64),
  protocol: z.enum(["classic", "fd"]).default("classic"),
  brs: z.boolean().default(false),
  direction: z.enum(["tx", "rx"]),
  txType: z.enum(["cyclic", "event", "cyclicEvent", "none"]).default("none"),
  cycleTimeMs: z.number().int().positive().optional(),
  sender: z.string().optional(),
  receivers: z.array(z.string()).optional(),
  comment: z.string().optional(),
  signals: z.array(CanSignal).default([]),
})
// e.g. structural rules that come "for free":
.refine(m => m.idFormat === "extended" ? m.id <= 0x1FFFFFFF : m.id <= 0x7FF,
        { message: "ID out of range for its format" })
.refine(m => m.txType !== "cyclic" || m.cycleTimeMs != null,
        { message: "cyclic message needs cycleTimeMs" });

export const Ecu = z.object({
  identity: z.object({
    id: z.string().regex(/^[a-z0-9-]+$/),
    name: z.string(),
    role: z.enum(["BMS","MotorController","VCU","Telemetry","Gateway","BodyControl","Charger","Other"]),
    vendor: z.string().optional(),
    partNumber: z.string().optional(),
    description: z.string().optional(),
  }),
  target: z.object({
    board: z.string().optional(),
    cpu: z.string().optional(),
    controllerModel: z.string().optional(),
    notes: z.string().optional(),
  }).default({}),
  busBindings: z.array(z.object({
    busId: z.string(),
    controllerInstance: z.string(),
  })).default([]),
  firmware: z.object({
    artifact: z.string().optional(),
    format: z.enum(["elf","bin","hex","unknown"]).default("unknown"),
    encrypted: z.boolean().default(false),
    loadAddress: z.number().int().optional(),
    entryPoint: z.number().int().optional(),
    notes: z.string().optional(),
  }).default({}),
  contract: z.object({
    source: z.enum(["dbc","arxml","manual"]).default("manual"),
    sourceFile: z.string().optional(),
    messages: z.array(CanMessage).default([]),
  }).default({ source: "manual", messages: [] }),
  intent: z.object({
    heartbeats: z.array(HeartbeatSpec).default([]),
    expectations: z.array(Expectation).default([]),
    signalChecks: z.array(SignalCheck).default([]),
    diagnostics: Diagnostics.default({}),
    faultScenarios: z.array(FaultScenario).default([]),
  }).default({}),
});

export const Project = z.object({
  schemaVersion: z.literal(1),
  meta: z.object({
    id: z.string(),
    name: z.string(),
    description: z.string().optional(),
    createdAt: z.string(),   // ISO; stamped by API route
    updatedAt: z.string(),
  }),
  buses: z.array(CanBus).default([]),
  ecus: z.array(Ecu).default([]),
});
export type Project = z.infer<typeof Project>;
```

### 5.5 Worked example - BMS descriptor (JSON)

```json
{
  "schemaVersion": 1,
  "meta": { "id": "demo-ev", "name": "Demo EV", "createdAt": "2026-06-28T00:00:00Z", "updatedAt": "2026-06-28T00:00:00Z" },
  "buses": [
    { "id": "powertrain", "name": "Powertrain CAN", "protocol": "fd",
      "nominalBitrate": 500000, "dataBitrate": 2000000 }
  ],
  "ecus": [
    {
      "identity": { "id": "bms", "name": "Battery Management System", "role": "BMS" },
      "target": { "board": "nxp-s32k388evb", "cpu": "nxp-s32k388", "controllerModel": "CAN.S32K3XX_FlexCAN" },
      "busBindings": [ { "busId": "powertrain", "controllerInstance": "can0" } ],
      "firmware": { "artifact": "bms-v1.4.elf", "format": "elf", "encrypted": true },
      "contract": {
        "source": "dbc", "sourceFile": "powertrain.dbc",
        "messages": [
          { "id": 1536, "idFormat": "standard", "name": "BMS_Heartbeat", "dlc": 2,
            "direction": "tx", "txType": "cyclic", "cycleTimeMs": 100, "sender": "BMS",
            "signals": [ { "name": "State", "startBit": 0, "length": 8, "byteOrder": "littleEndian",
                          "valueType": "unsigned", "factor": 1, "offset": 0,
                          "valueTable": { "0": "Init", "1": "Ready", "2": "Fault" } } ] },
          { "id": 1537, "idFormat": "standard", "name": "BMS_PackVoltage", "dlc": 4,
            "direction": "tx", "txType": "cyclic", "cycleTimeMs": 50, "sender": "BMS",
            "signals": [ { "name": "PackVoltage", "startBit": 0, "length": 16, "byteOrder": "littleEndian",
                          "valueType": "unsigned", "factor": 0.01, "offset": 0, "min": 0, "max": 600, "unit": "V" } ] },
          { "id": 1026, "idFormat": "standard", "name": "MC_Heartbeat", "dlc": 2,
            "direction": "rx", "txType": "none", "sender": "MotorController" }
        ]
      },
      "intent": {
        "heartbeats": [
          { "messageRef": 1536, "direction": "emit",    "periodMs": 100, "toleranceMs": 20, "missedThreshold": 3 },
          { "messageRef": 1026, "direction": "monitor", "periodMs": 100, "toleranceMs": 30, "missedThreshold": 3,
            "expectedReaction": "BMS_Heartbeat.State -> Fault within 350 ms" }
        ],
        "expectations": [
          { "id": "mc-lost-trips-fault", "name": "MC heartbeat loss trips BMS fault",
            "trigger": { "kind": "silence", "messageRef": 1026, "forMs": 350 },
            "expect":  { "kind": "frame", "messageRef": 1536, "signalConditions": [ { "signal": "State", "op": "==", "value": 2 } ] },
            "withinMs": 400 }
        ],
        "signalChecks": [
          { "signalRef": { "messageId": 1537, "signal": "PackVoltage" }, "range": { "min": 0, "max": 600 }, "onViolation": "flag" }
        ],
        "diagnostics": { "isotp": { "reqId": 1957, "respId": 1958, "addressing": "normal" } },
        "faultScenarios": [ { "type": "missedHeartbeat", "params": { "messageId": 1026 }, "expectedOutcome": "BMS enters Fault" } ]
      }
    }
  ]
}
```

This single descriptor is enough to later: spin up a `CANHub` for `powertrain`, create the BMS
machine on `nxp-s32k388evb`, load its firmware, stand up a `CANTester` for the (absent) motor
controller, emit/stop the `0x402` heartbeat, and assert the BMS emits `0x600` with
`State == Fault`. See §11.

---

## 6. DBC import design

### 6.1 What a DBC contains (and how it maps)

A `.dbc` describes a **whole bus** - all nodes, messages, signals. Mapping to our schema:

| DBC construct | Example line | Maps to |
|---|---|---|
| `BU_` node list | `BU_: BMS MC VCU TELEM` | candidate ECUs (one per node) |
| `BO_` message | `BO_ 1536 BMS_Heartbeat: 2 BMS` | `CanMessage` {id, name, dlc, sender}; `id & 0x80000000` ⇒ extended |
| `SG_` signal | `SG_ State : 0\|8@1+ (1,0) [0\|2] "" VCU` | `CanSignal` {startBit,length,byteOrder=`@1`→little,sign=`+`→unsigned,factor,offset,min,max,unit,receivers} |
| `BA_ "GenMsgCycleTime"` | `BA_ "GenMsgCycleTime" BO_ 1536 100;` | `cycleTimeMs` |
| `BA_ "GenMsgSendType"` | `BA_ "GenMsgSendType" BO_ 1536 0;` | `txType` (cyclic/event mapping) |
| `VAL_` value table | `VAL_ 1536 State 0 "Init" 1 "Ready" 2 "Fault";` | `signal.valueTable` |
| `CM_` comment | `CM_ BO_ 1536 "...";` | `comment` |
| multiplex marker | `SG_ Mode M :` / `SG_ Data m0 :` | `signal.mux` |

### 6.2 Parser approach

- **Write our own focused DBC parser** in `src/lib/dbc/` rather than depend on an unmaintained
  npm package. The DBC grammar we need (BU_/BO_/SG_/BA_/VAL_/CM_) is line-oriented and
  well-documented; a targeted parser is more reliable and debuggable than a heavyweight dep.
- **Output is schema objects**, validated through Zod immediately - so a malformed DBC fails
  loudly at import, not later.
- **Coverage for M1**: standard + extended IDs, signed/unsigned ints, Intel/Motorola byte
  order, factor/offset/min/max/unit, cycle time, send type, value tables, basic multiplexing,
  comments. **Deferred**: SAE J1939 PGN decomposition, extended multiplexing
  (`SG_MUL_VAL_`), float/double signal attributes, signal groups - parsed-through or flagged,
  not blocked.

### 6.3 Import-to-project flow (the UX that makes one DBC populate many ECUs)

1. User uploads `powertrain.dbc`.
2. We parse it → a preview: the bus, the node list (`BU_`), and per-node message counts.
3. User picks **which nodes are ECUs under test** and maps each to a new or existing `Ecu`
   (and to a `CanBus`). For each chosen ECU node `N`:
   - `direction = tx` for messages where `sender == N`.
   - `direction = rx` for messages where `N` appears in any signal's receiver list.
4. We merge into the project, set `contract.source = "dbc"`, `sourceFile`, and leave `intent`
   untouched (or empty for new ECUs).
5. **Re-import** of an updated DBC: refresh `contract` only; preserve `intent` by re-binding
   annotations to messages by ID (warn on annotations whose message disappeared).

> This is the payoff of import-first: drop one network DBC, get a populated multi-ECU project,
> then spend your time on the *intent* layer - the part that's actually yours to define.

---

## 7. ARXML import (scoped)

AUTOSAR ARXML (System Description / ECU extract) carries the same information but as deep XML
with PDU/frame/cluster indirection. Full parsing is a substantial effort.

- **M1**: detect `.arxml`, surface it in the import wizard, and parse the *high-value subset*
  if cheap (cluster→bus, frame→message, ISignal→signal) **or** clearly mark it "preview /
  partial" and let the user fall back to manual. We will **not** claim full ARXML support in
  M1, and the UI will say so.
- **Fast-follow**: complete ARXML PDU/frame/signal resolution behind the same
  `parse(file) → Contract` interface the DBC parser implements, so the rest of the app is
  parser-agnostic.

---

## 8. Manual entry & annotation UX

### 8.1 Screens

| Screen | Purpose |
|---|---|
| **Project dashboard** | list/create projects; per project show buses + ECUs at a glance; import button; export/download JSON |
| **Import wizard** | upload DBC/ARXML → preview nodes/messages → map to ECUs/buses → merge (§6.3) |
| **ECU editor** | tabbed editor for one ECU |
| **Bus editor** | add/edit buses (protocol, bitrates) |

### 8.2 ECU editor tabs

1. **Identity** - id, name, role, vendor/part, description.
2. **Topology** - bus bindings (bus + controller instance); emulation target (board/cpu/
   controller, defaulted to S32K388).
3. **Firmware** - artifact ref, format, `encrypted` flag, load address, notes. *(Metadata
   only in M1 - no upload pipeline yet.)*
4. **Contract** - table of messages (id/name/dir/dlc/cycle), expand a row to edit signals.
   Editable by hand; rows imported from DBC are tagged with their source. This is the "what's
   on the wire" view.
5. **Intent** - the annotation layer, the product's value:
   - **Heartbeats**: pick a message, set emit/monitor, period, tolerance, missed-threshold.
   - **Expectations**: a small builder - trigger (frame/silence/sequence) → reaction
     (frame/noFrame) with signal conditions and a deadline.
   - **Signal checks**: pick message+signal, set range + on-violation.
   - **Diagnostics**: ISO-TP req/resp IDs + addressing; UDS service list.
   - **Fault scenarios**: pick type + params + expected outcome (stub; defines M5 work).

### 8.3 UX principles

- **Import does the heavy lifting; humans annotate.** Contract tables are pre-filled; the user
  spends time in the Intent tab.
- **Hex everywhere for IDs**, with validation against the chosen format (11/29-bit).
- **Annotations reference contract entities by ID/name**, so they survive contract re-import.
- **Everything is editable**, including imported rows (manual fallback is first-class).

---

## 9. Persistence & state

| Concern | M1 approach |
|---|---|
| Source of truth | the `Project` JSON (validated by the Zod `Project` schema) |
| Storage | file-based: `data/<projectId>.json` via Next.js API route handlers (`/api/projects`) - human-readable, diffable, git-trackable, and directly consumable by the M3 generator |
| Drafts/autosave | localStorage mirror so in-progress edits survive reloads |
| Interchange | export (download) / import (upload) a project JSON; lets a customer hand us a project without hosting |
| Concurrency | single-user assumption in M1; no locking/multi-tenant (revisit when hosted) |

---

## 10. Validation

**In M1 (free with Zod, structural):** required fields, enum membership, numeric ranges, ID
range vs format, `cycleTimeMs` present for cyclic, `dataBitrate` present for FD buses - these
are schema `.refine`s and block bad data at import/save.

**Deferred to M2 (cross-entity *lint*, the "Configurator + validation" option we did not pick
for M1):**
- duplicate TX message ID on the same bus (collision)
- signal bit ranges overlapping within a message
- signal layout exceeding `dlc * 8` bits
- heartbeat/expectation/signal-check references pointing at non-existent or wrong-direction
  messages
- BRS set on a classic (non-FD) message
- orphaned intent annotations after a contract re-import

These will run as a non-blocking **lint pass** surfaced as warnings/errors in the editor.

---

## 11. Forward map: schema → Renode (why the schema looks like it does)

Even though we generate nothing this milestone, every schema field exists to feed a specific
Renode construct later. Cross-referenced to [`../09-can-networking.md`](../09-can-networking.md):

| Schema element | Renode realization (M3) |
|---|---|
| `CanBus` | `emulation CreateCANHub "<bus>"` (one hub per bus) |
| `Ecu` + `target.board` + `firmware` | `mach create`; `LoadPlatformDescription @<board>.repl`; `sysbus LoadELF @<artifact>` |
| `busBinding {busId, controllerInstance}` | `connector Connect sysbus.<controllerInstance> <hubForBus>` |
| `CanMessage.direction=tx` on a **stub** ECU (no firmware) | `CANTester` `SendFrame` (cyclic loop at `cycleTimeMs`) |
| `CanMessage.direction=tx` on a **real-firmware** ECU | emitted by firmware; we *observe* it |
| `CanMessage.direction=rx` | firmware's RX acceptance filter (faithful in Renode) |
| `intent.heartbeats[emit]` | assert periodic frame present within tolerance |
| `intent.heartbeats[monitor]` + `expectations[silence→…]` | `CANTester` stops emitting; `Wait For Frame With Id` on the reaction |
| `expectations[].expect (frame + signalConditions, withinMs)` | `Wait For Frame With Id` + signal decode + deadline (the oracle) |
| `signalChecks[]` | decode each received frame; flag out-of-range |
| `diagnostics.isotp/uds` | `Send ISOTP Message` / `Send UDS Command And Wait For Positive Response` |
| `faultScenarios[]` | M5 campaigns (drop/flood/malform), built on the same primitives |
| determinism | `emulation SetGlobalQuantum`, `SetGlobalSerialExecution` (per CAN doc §6) |

**Known fidelity boundary (carried over from CAN doc §5b):** Renode's `CANHub` does **not**
model bit-level inter-node arbitration, destructive collisions, lost-arbitration retransmit,
or busload-dependent latency. So `faultScenarios` of type `busFlood`/`idCollision` that depend
on *physical* arbitration won't reproduce real timing out of the box - we either scope them to
functional effects or extend the hub. The schema can express them; the spec for M5 must note
which are faithfully simulatable.

---

## 12. App directory layout (target)

```
simev/
├── src/
│   ├── app/
│   │   ├── page.tsx                  # project dashboard
│   │   ├── projects/[id]/page.tsx    # project view (buses + ecus)
│   │   ├── projects/[id]/ecus/[ecuId]/page.tsx   # ECU editor (tabs)
│   │   ├── import/page.tsx           # DBC/ARXML import wizard
│   │   └── api/projects/route.ts     # GET/PUT project JSON in data/
│   ├── lib/
│   │   ├── schema/                   # Zod schema + inferred types (SOURCE OF TRUTH)
│   │   ├── dbc/                      # .dbc parser → Contract
│   │   ├── arxml/                    # scaffolded; partial parse
│   │   └── validation/              # structural now; lint pass in M2
│   └── components/                   # editor tables, builders, forms
├── data/                             # <projectId>.json (git-trackable); ships example(s)
├── package.json                      # pinned: next@14, react@18, tailwindcss@3, zod
└── README.md
```

---

## 13. Repo & infrastructure setup

### 13.1 Repository

- New directory **`simev/`** as its **own git repo** (the parent `initial/` is not a repo).
- `git init`; add remote **`origin → purge12/simev`** (e.g.
  `git remote add origin git@github.com:purge12/simev.git`).
- **No push** until explicitly requested.
- `.gitignore`: `node_modules/`, `.next/`, build artifacts; keep `data/` example projects.

### 13.2 Node / package versions (hard constraint)

The build host runs **Node 18.20.8** with no version manager. `create-next-app@latest` pulls
**Next 16 + Tailwind 4**, both requiring Node ≥20 - they will not run here. Therefore:

- **Pin** `next@14`, `react@18`, `tailwindcss@3`, `eslint-config-next@14`.
- **Cleanup note:** the current `simev/` on disk is a half-created **Next 16** scaffold from an
  aborted attempt; it must be removed and re-scaffolded at the pinned versions when we build.
- **Recommendation:** move the host to **Node 20 LTS** at some point so we can track current
  Next/Tailwind; not required for M1.

### 13.3 Renode vendoring policy

- **Not vendored in M1** (the configurator never touches it).
- When the simulation milestone (M3) needs it, add **`renode` and `renode-infrastructure` as
  git submodules** (they're large; submodules keep `simev` lean and pin exact revisions)
  rather than copying. Local clones already exist at `../renode` and `../renode-infrastructure`
  for reference.

---

## 14. Roadmap

| Milestone | Deliverable |
|---|---|
| **M1 (this spec)** | Descriptor schema + configurator (DBC import, manual entry, annotation, persistence, export) |
| **M2** | Cross-entity lint/validation; network/topology view; ARXML full parse |
| **M3** | Renode generation: `.resc`/`.repl` + `CANTester` stim + Robot oracle (thin end-to-end slice with open firmware, e.g. RAMN) |
| **M4** | Run orchestration; results dashboard (Wireshark/log ingest, pass/fail against expectations) |
| **M5** | Fault-injection campaigns (missed heartbeat, drop/flood/malform, signal out-of-range) |
| **M6** | Encrypted-firmware ingestion / secure-boot-in-emulator track |

---

## 15. Open questions & risks

1. **Encrypted firmware boot (biggest unknown).** How does an encrypted image run inside
   Renode? Options: customer provides a decrypted image under NDA; we emulate the secure-boot
   chain (need bootloader + keys/HSM behavior); or the demo uses open firmware (RAMN) and
   encrypted ingestion is a separate track (M6). **Recommendation for the demo: open
   firmware now, encrypted ingestion later.**
2. **ARXML depth.** How many customers hand us ARXML vs DBC? Drives how much M1/M2 ARXML effort
   is worth.
3. **Multi-bus gateways.** Schema supports an ECU on multiple buses; confirm the customer's
   topology actually needs it for the demo.
4. **UDS/diagnostics depth.** How central are UDS sessions to "wrong response" detection? If
   central, the oracle/diagnostics model needs more than M1's capture-only treatment.
5. **Signal-level oracle expressiveness.** Is the `SignalCond` grammar (compare ops + `in`)
   enough, or do we need computed/derived signal expectations?
6. **Hosting & multi-tenant.** M1 is single-user/file-based. A hosted product needs auth,
   per-customer isolation, and a real datastore - out of M1, but the JSON-as-truth design
   migrates cleanly into a DB later.
7. **Node 20 migration** (§13.2) - low risk, worth scheduling.

---

## 16. Glossary

| Term | Meaning |
|---|---|
| **Contract** | The CAN interface facts (IDs, signals, cycle times) - from DBC/ARXML. |
| **Intent** | Our test annotations (heartbeats, expectations, checks, faults) layered on the contract. |
| **Oracle** | The set of expectations that decides pass/fail for a stimulus. |
| **DBC** | Vector CAN database file - the de-facto CAN message/signal definition format. |
| **ARXML** | AUTOSAR XML system/ECU description. |
| **CANHub** | Renode's idealized broadcast CAN bus (one per bus). |
| **CANTester** | Renode host-side virtual node used to inject/await frames without firmware. |
| **ISO-TP / UDS** | Multi-frame CAN transport / diagnostic protocol over CAN. |
| **Heartbeat** | A periodic frame whose absence/lateness signals a fault. |

---

*End of Spec 01. Sibling reference: [`../09-can-networking.md`](../09-can-networking.md) - how
Renode models the CAN bus, controllers, stimulation, observability, and fidelity boundaries.*
