# 12 — Renode Fork Build & the I²C Sensor-Registration Bug: Resolved

> **Status: RESOLVED.** The SimEV Renode fork builds, host-side `Send Frame` works,
> **and** the I²C sensor-registration failure during `Bring Up Network` is fixed.
>
> The original blocker was that I²C sensors (`cell_temp`, `pack_monitor`) failed to
> register during the full bring-up, with:
> ```
> Error E20: Undefined register '[ReferenceValue: lpi2c0]'
> No such command or device: sysbus.lpi2c0.cell_temp
> ```
> The first handoff blamed `runMacro $reset` "dropping" the sensors. **That theory was
> wrong** (disproven by experiment — see §5). The real cause was a generator heuristic
> (`replDeclaresBus`) that read the `.repl` *at generation time* while Renode loaded a
> *different copy* at run time. The fix removes the heuristic and always injects the bus
> controllers (§6). Verified end-to-end through `renode-test` (§7).
>
> Original handoff written 2026-06-29; resolved later the same day. If you only read two
> sections, read **§5 (the real root cause)** and **§6 (the fix)**.

---

## 1. Goal / context

We're building a demo for an EV company that does manual CAN testing on NXP S32K
boards. The pitch: emulate their CAN bus + run their firmware automatically. The
app is a scaffolding layer over Renode. For the demo to be end-to-end ("press the
button, watch the bus react") we needed the **SimEV Renode fork** built, because
the host-side `Send Frame` keyword (used to inject frames) exists only in the fork,
not in the upstream portable/nightly binary.

---

## 2. What WORKS (confirmed)

### 2a. The fork builds
- Toolchain: .NET 10 SDK, mono, cmake, gcc/g++, python3. No `global.json` pin. The
  build targets `net8.0` and the .NET 10 SDK builds it fine.
- Build command (headless): `cd renode && ./build.sh --no-gui`. Submodules auto-fetch
  on first run. Output: `renode/output/bin/Release/Renode.dll` → the app auto-prefers
  the fork (see §4).

### 2b. `Send Frame` works end-to-end
Minimal loopback test PASSED against the fork (`emulation CreateCANHub`, `Create CAN
Tester`, `Start Emulation`, `Send Frame 0x123 DE AD BE EF`, `Wait For Frame With Id
0x123` → `status OK`). Injection (the whole reason to build the fork) is functional.

### 2c. The I²C sensor bug is fixed
The `Bring Up Network` setup now registers `lpi2c0`/`lpi2c1` and the sensors on them,
through the full bring-up (CAN hub + `macro reset`/`runMacro $reset` + firmware
`LoadELF` + `connector Connect`). Verified with `renode-test` (§7).

---

## 3. Build blocker that had to be fixed first: missing `CANTester`

The build initially FAILED with:
```
CANKeywords.cs(18,50): error CS0246: 'CANTester' could not be found
```

**Root cause:** the fork's `renode/src/Renode/RobotFrameworkEngine/CANKeywords.cs`
(SimEV-added, has `SendFrame`) references `CANTester` from `Antmicro.Renode.Testing`,
but the pinned `src/Infrastructure` submodule commit (`8469db0c`) predates `CANTester`.

**Fix applied:** `CANTester` was added upstream in infra commit **`bf2081844`
"Add CANTester"**. Two files were checked out into the pinned submodule working tree:
```bash
cd renode/src/Infrastructure
git fetch --depth=200 origin
git checkout bf2081844 -- \
  src/Emulator/Main/Testing/CANTester.cs \
  src/Emulator/Extensions/Tools/Network/CANHub.cs   # adds CANHub.AttachTo()
```
`CANTester.cs` is self-contained (`ISOTP_PCI`, `CANMatcher` defined inline). Rebuild
with `./build.sh --no-gui --skip-fetch` (critical — a submodule update would `reset`
and wipe these two uncommitted files).

> ⚠️ **These two files are uncommitted working-tree changes in the submodule.** Any
> `git submodule update` reverts them. To make it durable, commit the gitlink bump
> (point `src/Infrastructure` at `bf2081844`+) or vendor the files into the fork.

---

## 4. App-integration changes (so the app uses the fork)

| File | Change | Why |
|---|---|---|
| `src/lib/renode/runner.ts` | `findRenodeTest()` + `forkRunnerAvailable()`. Prefers `renode/renode-test` when `renode/output/bin` exists, else `~/renode_nightly`, `~/renode_portable`. `RENODE_TEST_PATH` overrides. | Auto-use the fork once built. |
| `src/app/api/projects/[id]/simulate/run/route.ts` | Use shared `findRenodeTest`; always exclude `skip_firmware_required`; only exclude `skip_portable` when NOT on the fork. **Regenerates the `.resc` artifacts fresh every run** (`generateArtifacts` → temp dir). | On the fork, `Send Frame` works, so injection checks run. The fresh-regenerate means generator fixes take effect immediately (only the `.robot` file comes from the saved copy). |
| `src/app/api/projects/[id]/simulate/probe/route.ts` | Use shared `findRenodeTest`. | Inject & observe also runs on the fork. |
| `src/lib/renode/generator.ts` | **Always inject `lpi2c0`/`lpi2c1`** via the two-pass `LoadPlatformDescriptionFromString` (§6). The earlier `replDeclaresBus()` "skip if the board repl already declares it" heuristic was **removed** — it was the bug (§5). | See §5/§6. |

---

## 5. THE BUG — what it actually was (root cause)

### Symptom
Through the full bring-up, the sensor default-value line failed:
```
Error E20: Undefined register '[ReferenceValue: lpi2c0]'
  at: cell_temp: Sensors.TMP103 @ lpi2c0 72
…or one line later…
No such command or device: sysbus.lpi2c0.cell_temp
```
Both are the **same** condition: **`lpi2c0` was never registered**, so the sensors had
no bus to attach to (E20 at declaration), and addressing them later fails ("No such
command or device").

### The first handoff's theory was wrong
The first handoff (§6 in its original form) claimed: *"running a `reset` macro
re-initialises the machine from its `LoadPlatformDescription`, dropping any peripherals
added via `LoadPlatformDescriptionFromString`."* **This is false**, proven three ways:

1. **Source.** `Machine.Reset()`
   (`renode-infrastructure/src/Emulator/Main/Core/Machine.cs:800-824`) only calls
   `.Reset()` on each already-registered peripheral. It never unregisters or re-creates
   anything and never re-runs the platform description. The S32K3 I²C controller's
   `Reset()` (`…/Peripherals/I2C/S32K3XX_LowPowerInterIntegratedCircuit.cs:43-50`)
   resets registers/queues but **keeps `ChildCollection`**. Only `Dispose()`
   (`…/Core/Structure/SimpleContainer.cs:48-56`) clears children — and Dispose only
   runs when the machine/peripheral is torn down, not on reset.
2. **Experiment.** Register a `TMP103` on `lpi2c0`, then `machine Reset`, then read it:
   `sysbus.lpi2c0.cell_temp Temperature` returns **`0`** — the sensor is **still there**
   (its value reset to the default), *not* "No such command or device".
3. **Experiment.** Re-declaring `lpi2c0` does not silently replace it either — it throws
   a loud `Error E02: Variable 'lpi2c0' was already declared`.

So the CAN hub, `connector Connect`, and the `macro reset` indirection were all **red
herrings**. With `lpi2c0` present, the sensors survive the entire bring-up.

### The real root cause: a generation-time / run-time `.repl` mismatch
The generator used to decide whether to inject the `lpi2c0`/`lpi2c1` bus controllers by
**reading the board `.repl` from disk at generation time** (`replDeclaresBus()` →
`process.cwd()/renode/tests/peripherals/mr_canhubk3.repl`). If that file declared
`lpi2c0`, the generator **skipped** injecting it, trusting the platform to provide it.

But the `.repl` that **Renode loads at run time** (`machine LoadPlatformDescription
@tests/peripherals/mr_canhubk3.repl`, resolved against Renode's CWD / search path) is
**not guaranteed to be the same file**. The temp work dir does not contain a copy, so the
reference resolves to whatever the Renode install bundles — where `lpi2c0`/`lpi2c1` are
**commented out** (upstream/portable/nightly default):
```
// lpi2c0: I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40350000
// lpi2c1: I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40354000
```
When the *inspected* file had `lpi2c0` uncommented but the *loaded* file had it
commented, the generator skipped the injection **and** the platform didn't provide it →
`lpi2c0` absent → every sensor failed. That is the whole bug.

| Loaded `.repl` `lpi2c0` | Generator injects? | Result |
|---|---|---|
| commented | yes | ✅ works |
| **commented** | **no (old `replDeclaresBus` skip)** | ❌ **E20 / No such device — the bug** |
| uncommented | yes | ❌ `E02` already declared |
| uncommented | no | ✅ works (only if the loaded repl really has it) |

The old heuristic could land in row 2 (skip + commented) whenever the inspected file and
the loaded file disagreed — which is exactly what produced the intermittent,
"non-deterministic"-looking failures in the first handoff's diagnostic log.

---

## 6. THE FIX

`src/lib/renode/generator.ts`: **delete the `replDeclaresBus()` heuristic and always
inject the missing bus controllers** via the canonical two-pass
`LoadPlatformDescriptionFromString` (the approach already documented in
[doc 11 §2–§3](11-peripheral-registration-debugging.md)). The generator now *owns* the
`lpi2c0`/`lpi2c1` declarations; it does not guess from a file it can't guarantee is the
one loaded. (The now-unused `fs`/`path` imports were removed; the misleading "reset
drops peripherals" comment was corrected.)

Generated `bms.resc` (unchanged shape, but the bus pass is now always emitted):
```
mach create $name
machine LoadPlatformDescription @tests/peripherals/mr_canhubk3.repl

macro reset
"""
    sysbus LoadELF $bin false sysbus.cpu0
    sysbus.cpu0 VectorTableOffset `sysbus GetSymbolAddress "_vector_table" sysbus.cpu0`
"""
runMacro $reset

machine LoadPlatformDescriptionFromString """       # Pass 1: bus controllers
lpi2c0: I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40350000
    ->nvic0@161
"""

machine LoadPlatformDescriptionFromString """       # Pass 2: sensors
cell_temp: Sensors.TMP103 @ lpi2c0 72
pack_monitor: Sensors.PAC1934 @ lpi2c0 16
"""

# Peripheral default values
sysbus.lpi2c0.cell_temp Temperature 25
```

> ⚠️ **Contract:** because the generator owns these declarations, the `.repl` *loaded at
> run time* must keep `lpi2c0`/`lpi2c1` **commented** (the upstream default), or you hit
> the opposite clash (`E02 already declared`, row 3 above). If anyone uncommented them in
> the fork's `renode/tests/peripherals/mr_canhubk3.repl`, **re-comment them.** This keeps
> a single source of truth.

> Note on sensor *defaults* (the one true thing about reset): a reset **does** restore a
> sensor's value to its model default, so the generator registers sensors and sets their
> default values **after** the last reset (`runMacro $reset`) so values like
> `Temperature 25` stick. This is why peripheral registration is emitted after the
> firmware/reset block — *not* because reset would drop the peripheral.

---

## 7. Verification (all executed, not reasoned)

Reproduced on the upstream **Renode nightly** `v1.16.1` (build `202606290224`, .NET 8) —
the bug needs no `Send Frame`, only the `Bring Up Network` path, so it reproduces without
a fork build. The nightly's bundled `mr_canhubk3.repl` has `lpi2c0` commented (the
bug-triggering condition).

| Check | Result |
|---|---|
| `machine Reset` survival experiment | sensor stays registered, value → 0 (theory disproven) |
| Re-declare `lpi2c0` experiment | `E02` (does not silently replace) |
| Old behavior (skip inject) via real `renode-test` | ❌ `Setup failed … E20: Undefined register lpi2c0` |
| Fixed generator output (inject) via real `renode-test` | ✅ `cell_temp=25`, `pack_monitor present`, **OK** |
| **Verbatim** generated `bms.resc`, full bring-up (hub + reset macro + firmware + `connector Connect`), worst case (commented repl resolves at runtime) | ✅ "Tests finished successfully :)" |
| `tsc --noEmit` on the app | ✅ exit 0 |

### How to reproduce (no fork build needed)
```bash
# 1. nightly with CAN keywords:
curl -L https://builds.renode.io/renode-latest.linux-portable.tar.gz \
  | tar xz --strip-components=1 -C ~/renode_nightly
pip install --user -r ~/renode_nightly/tests/requirements.txt
# 2. an S32K3 ELF for the reset macro's LoadELF:
curl -L "https://dl.antmicro.com/projects/renode/mr_canhubk3--zephyr-can-counter.elf-s_1959844-b2284bfd7adff900c7d6ac7fa06bb5ba3291b0e4" -o firmware/bms.elf
# 3. build a workdir with the generated bms.resc + a Bring Up Network .robot, then:
~/renode_nightly/renode-test tests/integration.robot
```
Bug variant (no `lpi2c0` pass) fails at setup with E20; fixed variant passes.

---

## 8. Secondary / known issues (NOT the I²C bug — still open)

1. **Stub "Emits X_Heartbeat" tests are semantically broken.** For a no-firmware ECU, the
   generator emits `Send Frame 0x402` then `Wait For Frame With Id 0x402` on the *same*
   tester, with the hub created **non-loopback**. A non-loopback hub does not echo a frame
   back to its sender, so these **time out even when injection works**. Options: loopback
   hub for these, two testers, or rethink what a stub "emits" means.
2. **`skip_firmware_required`** still excludes cross-ECU fault reactions and UDS tests —
   they need real ECU firmware. `renode/firmware/` now contains ELFs for all nodes
   (`bms/mc/vcu/tcu/gw/obc/telem.elf`), but `data/demo-ev.json` only wires `bms` to
   firmware; others are stubs. Wiring the rest is untested.
3. **Signal-level assertions** (e.g. "LampStatus == 1") are documented-only (comments),
   not executed. Injected-frame payloads are sent as `00 00` (no signal encoding yet).
4. **Saved `data/demo-ev-tests.robot`** is a user-owned copy of the generated `.robot`
   (per [doc 11 §8](11-peripheral-registration-debugging.md)). This bug's fix is in
   `.resc` generation (regenerated fresh every run), so the saved `.robot` isn't made
   stale by it — but if you change `generateRobotTest`, delete the saved file so the
   GET endpoint regenerates it.

---

## 9. File inventory (what changed across both sessions)

**Fork (uncommitted — see §3 warning):**
- `renode/src/Infrastructure/src/Emulator/Main/Testing/CANTester.cs` (added from `bf2081844`)
- `renode/src/Infrastructure/src/Emulator/Extensions/Tools/Network/CANHub.cs` (updated from `bf2081844`)
- `renode/output/**` (build artifacts)
- `renode/tests/peripherals/mr_canhubk3.repl` — **must keep `lpi2c0`/`lpi2c1` commented** (§6 contract)

**App:**
- `src/lib/renode/runner.ts` (new)
- `src/app/api/projects/[id]/simulate/run/route.ts`, `…/simulate/probe/route.ts`
- `src/lib/renode/generator.ts` — **removed `replDeclaresBus`; always inject `lpi2c0`/`lpi2c1`** (the fix); corrected the reset comment

---

## 10. TL;DR for whoever picks this up
1. The fork builds and `Send Frame` works — **don't redo that.** Protect the two
   submodule files (§3) from `git submodule update`.
2. The I²C sensor bug is **fixed.** It was never about reset — it was a
   generation-time/run-time `.repl` mismatch. The generator now always injects the bus
   controllers (§6). Keep `lpi2c0`/`lpi2c1` **commented** in the loaded `.repl`.
3. Remaining work is the **stub-heartbeat loopback** issue (§8.1) so the demo's green
   checks are meaningful, and wiring real firmware for the cross-ECU/UDS tests (§8.2).
