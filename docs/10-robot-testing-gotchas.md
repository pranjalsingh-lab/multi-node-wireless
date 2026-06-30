# 10 — Robot Framework Testing with Renode: Lessons from M3

> Every hard-won debugging lesson from wiring up the SimEV generator's Robot Framework
> output to a real Renode portable build. Topics: portable vs nightly builds, CAN keyword
> availability, `@`-path resolution, the `renode-test` CWD trap, named-argument semantics,
> loopback vs hub frames, and how to write tests that actually run.
>
> Each section records *what went wrong*, *why it went wrong*, and *the fix*. Future you
> will thank you for reading all of it before editing `integration.robot`.

---

## 0. What the stack looks like

```
renode-test (bash)
  └─ run_tests.py (Python)
       └─ robot_tests_provider.py
            ├─ spawns: renode --robot-framework-remote-server-port <N>
            │            cwd = <portable-dir>   ← THIS BITES YOU
            └─ Robot Framework talks to Renode via XML-RPC
                  └─ [RobotFrameworkKeyword] methods in Renode C# DLLs
```

Understanding this stack is the prerequisite for every section below.

---

## 1. Portable build dates matter — `CANKeywords` was not always there

### What happened

The first run produced:

```
No keyword with name 'Create CAN Tester' found.
```

### Why

`CANKeywords.cs` (the file that provides `Create CAN Tester`, `Wait For Frame With Id`,
`Send UDS Command And Wait For Positive Response`, etc.) was merged into upstream Renode on
**June 10, 2026** (commit `bf3d55e9`). The stable portable 1.16.1 release is from
**February 2026** — it predates the merge.

### Fix

Download a build dated **after June 10, 2026**.

```bash
# Nightly (always current):
mkdir ~/renode_nightly
curl -L https://builds.renode.io/renode-latest.linux-portable.tar.gz \
  | tar xz --strip-components=1 -C ~/renode_nightly

# Run tests with the nightly:
~/renode_nightly/renode-test tests/integration.robot
```

Or re-download `renode-latest.linux-portable.tar.gz` — the `-latest` URL always points
to the most recent build, so extracting it fresh over `renode_portable/` also works.

### How to verify a build has CANKeywords

```bash
strings /path/to/renode_portable/renode | grep -c "CANTester"
# returns 0 → old build, no keywords
# returns >0 → new build, keywords present
```

---

## 2. `renode-test` spawns Renode with its own install directory as CWD

### What happened

After fixing the keyword issue, the next error was:

```
File does not exist: scripts/single-node/bms.resc
```

even though `bms.resc` was clearly present at `renode/scripts/single-node/bms.resc`.

### Why

`renode-test` is a bash script that calls `run_tests.py` with:

```bash
--robot-framework-remote-server-full-directory=$ROOT_PATH
```

where `$ROOT_PATH` is the directory containing `renode-test` (i.e. `renode_portable/`).
`robot_tests_provider.py` then spawns Renode with `cwd=self.remote_server_directory`, so
the Renode process starts with its working directory set to `renode_portable/`, not to the
directory from which you ran `renode-test`.

Renode resolves `@`-prefixed paths (like `@scripts/single-node/bms.resc`) **relative to
the Renode process's CWD**, not relative to the `.robot` file, not relative to where
you ran `renode-test`.

So `include @scripts/single-node/bms.resc` resolves to:
```
renode_portable/scripts/single-node/bms.resc   ← does not exist
```
instead of:
```
simev/renode/scripts/single-node/bms.resc      ← what you wanted
```

### Fix

In the `Bring Up Network` keyword, add this as the **very first `Execute Command`**:

```robot
Execute Command    path add @${EXECDIR}
```

`${EXECDIR}` is a Robot Framework built-in variable equal to the directory from which
`renode-test` was invoked. Adding it to Renode's path search makes `@scripts/...` resolve
relative to your `renode/` directory.

**This must be the first command**, before `CreateCANHub` or any `include`. Renode's
path search is checked at `include` time, so adding the path after the first include
doesn't help.

```robot
*** Keywords ***
Bring Up Network
    Execute Command    path add @${EXECDIR}    # ← FIRST
    Execute Command    emulation CreateCANHub "${HUB}" False
    Execute Command    include @scripts/single-node/bms.resc
    ...
```

---

## 3. `@`-path resolution in `.resc` files — the `$bin` variable pattern

### What happened

Early versions of `bms.resc` hard-coded `@firmware/bms-v1.4.elf` directly in the
`sysbus LoadELF` call. This produced:

```
Parameters did not match the signature of LoadELF
```

### Why (two sub-causes)

**Sub-cause A: `ReadFilePath.Validate()` throws at parse time.**
Renode validates `@path` arguments when it parses the Monitor command — before the
command even runs. If the file does not exist on disk at that moment, it throws:

```
RecoverableException("File does not exist: {path}")
```

That exception surfaces as the confusing "Parameters did not match the signature" message
because it's caught in the argument-parsing layer.

**Sub-cause B: the path is resolved from the Renode process CWD** (see §2 above),
not from the `.resc` file's location, so `@firmware/bms-v1.4.elf` resolves to
`renode_portable/firmware/bms-v1.4.elf`.

### Fix — use the RAMN/mr_canhubk3 variable pattern

Never hard-code ELF paths in `.resc` files. Use conditional-default variables:

```
$name?="bms"
$bin?=@firmware/can-counter.elf

mach create $name
machine LoadPlatformDescription @tests/peripherals/mr_canhubk3.repl
```

The caller (Robot test or `network.resc`) sets `$bin` **before** `include`-ing the
`.resc`:

```robot
Execute Command    $name="bms"
Execute Command    $bin=${BMS_BIN}
Execute Command    include @scripts/single-node/bms.resc
```

This way, validation is deferred to the `LoadELF` call inside the macro, and the caller
can override the path to any real ELF without editing the `.resc`.

---

## 4. The `macro reset` + `VectorTableOffset` pattern for S32K3xx / Cortex-M7

### What happened

An early `bms.resc` used a plain `sysbus LoadELF $bin` line. The machine booted but the
CPU started from the wrong address, or execution went wrong immediately.

### Why

The S32K388 is a Cortex-M7 with 4 cores (`cpu0`…`cpu3`). The ELF for it:

1. Must be loaded specifying the primary core: `sysbus LoadELF $bin false sysbus.cpu0`
   (`false` = use physical addresses, not virtual).
2. The vector table is **not** at address 0. The IVT is in flash and Renode needs to be
   told where it starts so it can read the initial SP and PC.

The upstream `mr_canhubk3.resc` handles both via the `macro reset` pattern:

```
macro reset
"""
    sysbus LoadELF $bin false sysbus.cpu0
    sysbus.cpu0 VectorTableOffset `sysbus GetSymbolAddress "_vector_table" sysbus.cpu0`
"""

runMacro $reset
```

The backtick expression evaluates at macro-run time and reads the `_vector_table` symbol
from the ELF to find the correct IVT base address. Cortex-M reads `SP` from offset 0 and
`PC` from offset 4 of that table.

### Fix

All generated `bms.resc` (and any `.resc` for S32K3xx boards) **must** use this exact
pattern. The generator (`src/lib/renode/generator.ts`) emits it for ELF-format firmware
whenever the board is `mr_canhubk3` or any other multi-core Cortex-M target.

### Where the reference `.repl` actually is

The `mr_canhubk3` platform description is **not** in `platforms/boards/`. It lives at:

```
tests/peripherals/mr_canhubk3.repl
```

The generator has a `knownTestBoards` map for this:

```typescript
const knownTestBoards: Record<string, string> = {
  "mr_canhubk3": "tests/peripherals/mr_canhubk3.repl",
};
const replPath = knownTestBoards[board] ?? `platforms/boards/${board}.repl`;
```

---

## 5. `SendFrame` is not available as a Robot keyword in the upstream binary

### What happened

Tests calling `Send Frame    0x402    00 00    ${MC_TESTER}` produced:

```
Arguments types do not match any available keyword "SendFrame" : [0x402, 00 00, testerId=0]
```

After removing `testerId=`:

```
Arguments types do not match any available keyword "SendFrame" : [0x402, 00 00, 0]
```

After removing the tester handle entirely:

```
ArgumentException: Type "Nullable`1" does not have a "Parse" method with the requested parameters
```

### Why — the full picture

**`SendFrame` is NOT in `CANKeywords.cs` upstream.** The upstream file (`bf3d55e9`, June
2026) provides these Robot keywords:

- `Create CAN Tester`
- `Wait For Frame With Id`
- `Wait For ISOTP Message Hex`
- `Set Default CAN Timeout`
- `Send UDS Command And Wait For Positive Response`
- `Send ISOTP Message`

There is **no `Send Frame`**. SimEV's fork of Renode added it manually to
`renode/src/Renode/RobotFrameworkEngine/CANKeywords.cs`:

```csharp
[RobotFrameworkKeyword]
public void SendFrame(uint id, string data, int? testerId = null)
{
    var tester = GetTesterOrThrowException(testerId);
    var bytes = data.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                    .Select(b => Convert.ToByte(b, 16))
                    .ToArray();
    tester.SendFrame(new CANMessageFrame(id, bytes));
}
```

Because source files in the fork submodule are **not compiled into the portable binary**,
the portable never sees this method. Instead, it matches an internal Renode method named
`SendFrame` (on a CAN peripheral or hub) through the Monitor command fallback. That
internal method has a different signature, hence every type-mismatch variant.

**Named arguments (`testerId=${MC_TESTER}`) vs. positional:** Renode handles named
arguments for `[RobotFrameworkKeyword]` methods. Monitor command fallbacks do not support
named arguments — the keyword dispatcher passes them as positional string literals
(`"testerId=0"`), which also causes type failures.

### How `Create CAN Tester` returns a handle

`CreateCANTester` returns an `int` — the zero-based index of the registered tester in the
`TestersProvider`. Subsequent keywords like `Wait For Frame With Id` accept `int? testerId`
as a named arg to select which tester to use. With `testerId=null` (default), the first
registered tester (index 0) is used.

This means: if you create exactly one CANTester, you never need to pass `testerId` to
`Wait For Frame With Id` — the default selects it automatically.

### Fix options

| Option | Effort | Notes |
|--------|--------|-------|
| **Build Renode from the fork** | High (~30 min build) | Gives full `SendFrame` support |
| **Tag tests `skip_portable`** | Zero | `renode-test` auto-excludes them |
| **Use `Execute Command` Monitor workaround** | Medium | Fragile, undocumented API |

For M3, tests requiring `Send Frame` are tagged `skip_portable`. The `renode-test` script
passes `--exclude "skip_portable"` automatically, so they are silently skipped on portable
builds and will run when `renode-test` is called from a source build of the fork.

To build the fork (when needed):
```bash
cd simev/renode
./build.sh
```

---

## 6. Named keyword arguments: what works and what doesn't

### Rule

**Named arguments work for `[RobotFrameworkKeyword]` methods. They do NOT work for
Monitor command fallbacks.**

| Call site | Mechanism | Named args | Example |
|-----------|-----------|-----------|---------|
| `Wait For Frame With Id` | `[RobotFrameworkKeyword]` | ✅ Works | `Wait For Frame With Id    0x600    timeout=5` |
| `Wait For Line On Uart` | `[RobotFrameworkKeyword]` | ✅ Works | `Wait For Line On Uart    text    testerId=${T}    timeout=10` |
| `Send Frame` (upstream) | Monitor fallback | ❌ Breaks | passes `testerId=0` as a string |

Named args for `timeout=`, `testerId=`, `pauseEmulation=`, `machine=`, etc. are all safe
when the keyword is registered via `[RobotFrameworkKeyword]`.

---

## 7. CAN loopback ELF vs hub-visible frames

### What happened

`Wait For Frame With Id    0x600    timeout=5` timed out even though the firmware
(can-counter.elf) was running fine (confirmed via UART).

### Why

The downloaded sample `mr_canhubk3--zephyr-can-counter.elf` is the **loopback variant**.
Zephyr configures the FlexCAN peripheral in `CAN_MODE_LOOPBACK`. In this mode, frames are
echoed back inside the CAN controller — they do not propagate to the `CANHub`. The
`CANTester` attached to the hub never sees these frames.

The two available sample ELFs:

| File (suffix) | Mode | Frames go to hub? |
|---|---|---|
| `...-can-counter.elf-s_1959844-...` | CAN loopback (single machine) | ❌ No |
| `...-can-counter--no-loopback.elf-s_1959384-...` | Normal (two-machine exchange) | ✅ Yes |

The loopback ELF is what the `S32K3XX_FlexCAN.robot` "Should Receive CAN Frames On
Loopback" test uses — but it verifies via **UART** (`Wait For Line On Uart    Counter
received: 0`), not via CAN frame capture.

### Fix

For protocol-level frame verification, you need either:

1. **Real firmware** that implements your protocol and runs in normal (non-loopback) mode, OR
2. **Two-machine exchange** with the no-loopback ELF (see `S32K3XX_FlexCAN.robot`), OR
3. **UART verification** for sanity-checking that the firmware boots correctly.

SimEV's integration test uses option 3 for the placeholder firmware:

```robot
Battery Management System Firmware Boots
    [Setup]    Bring Up Network
    Wait For Line On Uart    Counter received: 0    testerId=${BMS_UART_TESTER}    timeout=10
```

The UART for mr_canhubk3 is `sysbus.lpuart2`. Register it as:

```robot
${BMS_UART_TESTER}=    Create Terminal Tester    sysbus.lpuart2    machine=bms
```

---

## 8. `SetGlobalSerialExecution` and quantum — when to use them

`emulation SetGlobalSerialExecution True` forces all machine cores to advance in lockstep.
`emulation SetGlobalQuantum "0.00001"` sets the time slice per synchronisation round.

**Use both when you have two or more machines exchanging frames.** Without them, one
machine can race ahead in emulated time and miss frames from the other. The `ramn.resc`
reference uses `0.000025` for a 4-machine network.

**Single-machine loopback tests don't need them.** The upstream `S32K3XX_FlexCAN.robot`
"Should Receive CAN Frames On Loopback" does not set quantum or serial execution.
Adding them to a single-machine test is harmless but may obscure timing issues.

The SimEV generator always emits both (conservative default for multi-ECU networks). If
you strip out stub ECUs and run a single-firmware test, you can remove these lines.

---

## 9. `Create CAN Tester` return value and tester indexing

```robot
${MC_TESTER}=    Create CAN Tester    ${HUB}
```

Returns an integer (0, 1, 2, …) — the tester index. Subsequent calls to
`Wait For Frame With Id`, `Send ISOTP Message`, etc. accept this as the optional
`testerId` named argument. With `testerId` omitted, tester 0 (the first one created) is
used.

```robot
# Uses tester 0 implicitly — only valid if you created exactly one tester
Wait For Frame With Id    0x600    timeout=5

# Explicit — required when you have multiple testers
Wait For Frame With Id    0x600    testerId=${MC_TESTER}    timeout=5
```

The tester is attached to the named `CANHub` string. You must use the same hub name that
you passed to `emulation CreateCANHub`:

```robot
Execute Command    emulation CreateCANHub "canHub" False
${T}=    Create CAN Tester    canHub
```

---

## 10. `skip_portable` tag — automatically excluding tests that need a source build

The `renode-test` bash script always passes `--exclude "skip_portable"` to Robot
Framework. Any test tagged `skip_portable` is silently skipped when running with the
portable build.

Use this tag for tests that depend on `Send Frame` (which requires building the SimEV
Renode fork) or other features not yet in upstream:

```robot
Motor Controller Emits MC_Heartbeat
    [Tags]    skip_portable
    [Documentation]    Requires Send Frame keyword — build Renode from simev/renode fork.
    [Setup]    Bring Up Network
    Start Emulation
    Send Frame    0x402    00 00
    Wait For Frame With Id    0x402    timeout=1
```

When a proper source build is available, these tests run automatically without any
change to the `.robot` file.

---

## 11. Quick diagnosis checklist

When a Robot test fails against Renode, run through this list:

```
1. "No keyword with name 'X' found"
   → Build date too old. Re-download renode-latest. Check: strings renode | grep CANTester

2. "File does not exist: scripts/..."
   → Missing `path add @${EXECDIR}` as first Execute Command in Bring Up Network.

3. "Parameters did not match the signature of LoadELF"
   → ELF file doesn't exist on disk at parse time. Use $bin?= variable pattern.
      Never hard-code @firmware/... in sysbus LoadELF.

4. "Arguments types do not match any available keyword 'SendFrame'"
   → SendFrame is not a Robot keyword in the upstream binary. Tag test skip_portable
      or build from the simev/renode fork.

5. "Type Nullable`1 does not have a Parse method"
   → Same root cause as #4. The Monitor fallback for SendFrame has a nullable parameter
      that can't be type-converted from the positional string argument.

6. "CANTester failed, no matching frame found"
   → Two possibilities:
      a) Firmware uses CAN loopback mode → frames don't reach the hub. Use UART check.
      b) Firmware doesn't implement the expected protocol. Replace placeholder firmware.

7. "CANTester failed, no matching ISOTP message"
   → Firmware has no ISO-TP / UDS stack. Use real ECU firmware.

8. Machine hangs, no UART output
   → Check the .log file for lpspi3/SPI errors or unmapped peripheral reads.
      These are usually non-fatal warnings; the firmware recovers. If UART is also
      silent, the firmware may be stuck in a spin-wait on a modeled peripheral.
```

---

## 12. Full working `integration.robot` structure

The canonical shape of the test file, as of M3:

```robot
*** Settings ***
Library    Collections

*** Variables ***
${HUB}              canHub
${QUANTUM}          0.00001
${BMS_UART}         sysbus.lpuart2
${BMS_BIN}          @firmware/can-counter.elf
${MC_TESTER}        ${NONE}
${BMS_UART_TESTER}  ${NONE}

*** Keywords ***
Bring Up Network
    Execute Command    path add @${EXECDIR}          # resolve @scripts/ from renode/ dir
    Execute Command    emulation CreateCANHub "${HUB}" False
    Execute Command    $name="bms"
    Execute Command    $bin=${BMS_BIN}
    Execute Command    include @scripts/single-node/bms.resc
    Execute Command    connector Connect sysbus.can0 ${HUB}
    ${BMS_UART_TESTER}=    Create Terminal Tester    ${BMS_UART}    machine=bms
    Set Suite Variable    ${BMS_UART_TESTER}
    ${MC_TESTER}=    Create CAN Tester    ${HUB}
    Set Suite Variable    ${MC_TESTER}
    Execute Command    emulation SetGlobalQuantum "${QUANTUM}"
    Execute Command    emulation SetGlobalSerialExecution True

*** Test Cases ***
BMS Firmware Boots
    [Setup]    Bring Up Network
    Wait For Line On Uart    Counter received: 0    testerId=${BMS_UART_TESTER}    timeout=10

BMS Emits Heartbeat
    [Tags]    skip_firmware_required
    [Setup]    Bring Up Network
    Start Emulation
    Wait For Frame With Id    0x600    timeout=5

MC Emits Heartbeat
    [Tags]    skip_portable    skip_firmware_required
    [Setup]    Bring Up Network
    Start Emulation
    Send Frame    0x402    00 00
    Wait For Frame With Id    0x402    timeout=1
```

---

## 13. `bms.resc` canonical form

```
$name?="bms"
$bin?=@firmware/can-counter.elf

mach create $name
machine LoadPlatformDescription @tests/peripherals/mr_canhubk3.repl

macro reset
"""
    sysbus LoadELF $bin false sysbus.cpu0
    sysbus.cpu0 VectorTableOffset `sysbus GetSymbolAddress "_vector_table" sysbus.cpu0`
"""

runMacro $reset
```

Key points:
- `$name?=` and `$bin?=` — conditional defaults; caller overrides before `include`
- `machine LoadPlatformDescription` — note `tests/peripherals/`, not `platforms/boards/`
- `false` in `LoadELF` — use physical addresses (not virtual)
- `sysbus.cpu0` — must specify the primary core for multi-core S32K388
- `VectorTableOffset` — required; IVT is not at 0x0 for S32K3xx ELF

---

## 14. Where things live in the SimEV repo

```
simev/
├── renode/                          # fork submodule (source, not the running binary)
│   ├── firmware/
│   │   └── can-counter.elf          # Zephyr CAN counter sample (loopback variant)
│   ├── scripts/
│   │   └── single-node/
│   │       └── bms.resc             # per-ECU Renode script
│   └── tests/
│       ├── integration.robot        # generated Robot Framework test suite
│       ├── logs/                    # per-test Renode logs (written by renode-test)
│       └── snapshots/               # per-test emulation snapshots on failure
├── src/lib/renode/
│   └── generator.ts                 # generates all of the above from Project schema
└── renode_portable/   (sibling dir, not tracked)
    └── renode-test                  # run tests from here
```

The generator (`generator.ts`) is the single source of truth. Edit intent annotations
in the UI, regenerate, and the robot test, resc files, and network script all update.
