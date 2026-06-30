# 11 — Peripheral Registration Debugging: The Simulation Layer War Stories

> Everything that broke while building the SimEV simulation environment — the `.resc`
> generator, I2C sensor registration, peripheral name resolution, and the SSE streaming
> layer. Each section follows the same structure: *what the error said*, *why it happened*,
> *how it was fixed*, *what to watch for next time*.
>
> These errors compound on each other. Read all sections before editing
> `generator.ts` or any generated `.resc`.

---

## 0. The simulation layer at a glance

Before M3, SimEV generated Renode artefacts (`.resc`, `.robot`, network script) and
handed them to the user as files to copy. The simulation layer replaced that with:

1. A `/projects/[id]/simulate` page with a live test editor (left panel) and streaming
   output console (right panel).
2. A `POST /api/projects/[id]/simulate/run` route that spawns `renode-test` as a
   subprocess, streams SSE back to the browser.
3. The generator (`src/lib/renode/generator.ts`) populating the `.resc` and `.robot`
   artefacts into a temp directory at run time, with firmware ELFs copied alongside them.

All five errors below occurred while getting the first run to pass end-to-end.

---

## 1. Hyphen in peripheral identifiers — `Error E00: Syntax error, unexpected '-'`

### The error

```
Error E00: Syntax error, unexpected '-'; expected colon
  at line: cell-temp: Sensors.TMP103 @ lpi2c0 72
```

### Why

Renode `.repl` identifier syntax follows the same rules as C-family identifiers:
`[a-zA-Z_][a-zA-Z0-9_]*`. Hyphens are not allowed. The SimEV schema uses kebab-case IDs
(`"cell-temp"`, `"pack-monitor"`, `"batt-inlet-temp"`) throughout, so any peripheral ID
with a hyphen produces a parse error the moment it appears in a `.repl` fragment.

The error surfaces at `machine LoadPlatformDescriptionFromString` time, not at schema
validation time, so it only appears on first run.

### Fix

A `replId()` helper in the generator maps hyphens to underscores before any peripheral ID
appears in Renode syntax:

```typescript
// src/lib/renode/generator.ts
function replId(id: string): string {
  return id.replace(/-/g, "_");
}
```

Applied at every site where peripheral IDs appear in generated Renode output:

| Generator site | Before | After |
|---|---|---|
| `LoadPlatformDescriptionFromString` declaration | `cell-temp: Sensors.TMP103 ...` | `cell_temp: Sensors.TMP103 ...` |
| `LoadPlatformDescriptionFromString` bus supplement | `lpi2c-0: I2C...` | `lpi2c_0: I2C...` |
| `.resc` default-value command | `cell-temp Temperature 25` | `cell_temp Temperature 25` |
| Robot test `Execute Command` | `cell-temp Temperature 25` | `cell_temp Temperature 25` |

The schema ID (`"cell-temp"`) is unchanged — `replId()` is a display transform only,
applied at generator output time.

### Rule

**Never write a peripheral ID containing a hyphen into any Renode syntax.** Schema IDs
can be kebab-case; Renode identifiers cannot. Apply `replId()` at every generator output
site.

---

## 2. `lpi2c0` not defined — `Error E20: Undefined register`

### The error

```
Error E20: Undefined register '[ReferenceValue: lpi2c0]'
  at line: cell_temp: Sensors.TMP103 @ lpi2c0 72
```

### Why

The portable `renode_nightly` binary ships a **bundled copy** of
`tests/peripherals/mr_canhubk3.repl` compiled into the binary. This bundled copy has
`lpi2c0` and `lpi2c1` commented out:

```
// lpi2c0: I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40350000
//     ->nvic0@161
// lpi2c1: I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40354000
//     ->nvic0@162
```

Uncommenting them in the `renode/` submodule `.repl` file has **no effect** on a portable
build — the submodule source is not compiled into the portable binary. The portable reads
the bundled copy from its own extracted directory.

When `cell_temp: Sensors.TMP103 @ lpi2c0 72` is processed, `lpi2c0` is not in the machine,
so the `@`-reference is unresolvable.

### Fix

The generator maintains a `missingBusDecls` table keyed by board name. For every I2C
peripheral registered on a bus listed in this table, the bus controller declaration is
injected inline via a **separate** `LoadPlatformDescriptionFromString` call before any
sensor declarations (see §3 for why the calls must be separate):

```typescript
const missingBusDecls: Record<string, Record<string, string>> = {
  mr_canhubk3: {
    lpi2c0: "I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40350000\n    ->nvic0@161",
    lpi2c1: "I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40354000\n    ->nvic0@162",
  },
};
```

Generated `.resc` output (BMS example with one I2C sensor on lpi2c0):

```
machine LoadPlatformDescriptionFromString """
lpi2c0: I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40350000
    ->nvic0@161

"""

machine LoadPlatformDescriptionFromString """
cell_temp: Sensors.TMP103 @ lpi2c0 72
pack_monitor: Sensors.PAC1934 @ lpi2c0 16
"""
```

### Submodule vs portable — what each source controls

| Source | Affects |
|---|---|
| `renode/tests/peripherals/mr_canhubk3.repl` | Source builds only |
| Portable binary bundled `.repl` | Portable builds |
| `missingBusDecls` in generator | Both (inline, overrides everything) |

For production, the `missingBusDecls` approach is the only reliable one because it works
regardless of whether the user runs portable or source.

---

## 3. `LoadPlatformDescriptionFromString` is single-pass — `Error E20` after "fixing" §2

### The error

Same `Error E20: Undefined register '[ReferenceValue: lpi2c0]'` — even after moving
`lpi2c0` and `cell_temp` into the same `LoadPlatformDescriptionFromString` block:

```
machine LoadPlatformDescriptionFromString """
lpi2c0: I2C.S32K3XX_LowPowerInterIntegratedCircuit @ sysbus 0x40350000
    ->nvic0@161

cell_temp: Sensors.TMP103 @ lpi2c0 72
"""
```

### Why

`LoadPlatformDescriptionFromString` (like `.repl` file loading) is **single-pass**.
Declarations are processed in order, top-to-bottom. When the `cell_temp` line is parsed,
`lpi2c0` has been *declared in this fragment* but has **not yet been committed to the
machine** — the entire fragment is assembled and type-checked before any of its objects
are registered in the machine's peripheral map.

The forward reference to `lpi2c0` in `@ lpi2c0 72` therefore fails with E20.

This is the same rule that governs standard `.repl` files: you cannot reference a
peripheral from within the same declaration block before it has been fully constructed.

### Fix

Two separate `LoadPlatformDescriptionFromString` calls:

1. **Pass 1** — bus controllers only. After this call returns, `lpi2c0` exists in the
   machine.
2. **Pass 2** — sensor registrations. `lpi2c0` is now a live object, so `@ lpi2c0 72`
   resolves correctly.

```typescript
// Pass 1: commit missing bus controllers to the machine
if (busSupplements.length > 0) {
  lines.push(`\nmachine LoadPlatformDescriptionFromString """`);
  for (const decl of busSupplements) {
    lines.push(decl);
    lines.push("");
  }
  lines.push(`"""`);
}

// Pass 2: register sensors — buses exist in the machine now
lines.push(`\nmachine LoadPlatformDescriptionFromString """`);
for (const p of peripherals) {
  const loc = p.busBinding.busType === "i2c"
    ? `@ ${p.busBinding.controller} ${p.busBinding.address}`
    : `@ ${p.busBinding.controller}`;
  lines.push(`${replId(p.id)}: ${p.model} ${loc}`);
}
lines.push(`"""`);
```

### Rule

**One `LoadPlatformDescriptionFromString` block = one pass.** Any peripheral that another
peripheral in the same block references as a bus must have been registered by a *prior*
call. If you need to add a bus that isn't in the base `.repl`, add it in its own call
before the sensors that use it.

---

## 4. I2C slaves are not in the machine's top-level name map — `No such command or device`

### The error

```
No such command or device: cell_temp
  at line: cell_temp Temperature 25
```

This error appeared in the `.resc` after the two-pass `LoadPlatformDescriptionFromString`
(§3) apparently succeeded — the sensor was declared without an E20 error, but then trying
to set its default value with `cell_temp Temperature 25` failed.

The same error appeared in the Robot test's `Bring Up Network`:

```
Execute Command    cell_temp Temperature 25
```

### Why — the `SimpleContainer<T>` name-map issue

Renode's Monitor resolves a bare name (e.g., `cell_temp`) by looking it up in the
machine's top-level peripheral name map. I2C slaves registered `@ lpi2c0 72` are **not
added to the top-level name map**. They are stored as children of the bus controller
(`lpi2c0`), which itself is a `SimpleContainer<II2CPeripheral>`.

The `S32K3XX_LowPowerInterIntegratedCircuit` class hierarchy confirms this:

```csharp
public class S32K3XX_LowPowerInterIntegratedCircuit
    : SimpleContainer<II2CPeripheral>, IDoubleWordPeripheral, ...
```

`TMP103` is a valid child:

```csharp
public class TMP103 : II2CPeripheral, IProvidesRegisterCollection<ByteRegisterCollection>,
    ITemperatureSensor
```

The registration succeeds (no E20), but `cell_temp` does not appear in the machine's
top-level symbol table. Trying to address it by short name fails with "No such command
or device."

### Evidence from upstream Renode tests

The `SHT45.robot` test in the Renode source (`tests/peripherals/SHT45.robot`) demonstrates
the correct access syntax:

```robot
Execute Command    sysbus.i2c1.sht45 Temperature 25
Execute Command    sysbus.i2c1.sht45 Humidity 60
```

The path is: `sysbus` → bus controller → slave name. This works because `sysbus` always
has a complete view of all registered controllers, and each controller exposes its
registered slaves via the sysbus peripheral path.

### Fix

In `generator.ts`, wherever an I2C peripheral's property is set via Monitor command,
prefix the name with `sysbus.<busName>.<peripheralId>` instead of just the bare name:

```typescript
// generateEcuResc — .resc default value commands
const prefix = p.busBinding.busType === "i2c"
  ? `sysbus.${replId(p.busBinding.controller)}.${replId(p.id)}`
  : replId(p.id);
lines.push(`${prefix} ${dv.property} ${formatPeripheralValue(dv.value)}`);
```

```typescript
// generateRobotTest — Bring Up Network default values
const prefix = p.busBinding.busType === "i2c"
  ? `sysbus.${replId(p.busBinding.controller)}.${replId(p.id)}`
  : replId(p.id);
lines.push(`    Execute Command    ${prefix} ${dv.property} ${formatPeripheralValue(dv.value)}`);
```

```typescript
// generateRobotTest — per-test peripheralSetup overrides
const periph = project.ecus
  .flatMap((e) => e.peripherals ?? [])
  .find((p) => p.id === entry.peripheralId);
const prefix = periph?.busBinding.busType === "i2c"
  ? `sysbus.${replId(periph.busBinding.controller)}.${replId(entry.peripheralId)}`
  : replId(entry.peripheralId);
lines.push(`    Execute Command    ${prefix} ${entry.property} ${formatPeripheralValue(entry.value)}`);
```

Generated output for the BMS example:

```
# .resc
sysbus.lpi2c0.cell_temp Temperature 25

# Robot test — Bring Up Network
    Execute Command    sysbus.lpi2c0.cell_temp Temperature 25

# Robot test — per-test override
    Execute Command    mach set "bms"
    Execute Command    sysbus.lpi2c0.cell_temp Temperature 85
```

### Rule

**I2C (and SPI) slaves have two names: a schema ID and a sysbus path.** For Monitor
commands, always use the full sysbus path: `sysbus.<controller>.<slave>`. The short name
only works for top-level peripherals declared directly on `sysbus` (e.g., `can0`,
`lpuart2`, `nvic0`).

The pattern generalises to SPI: `sysbus.<spi_controller>.<sensor_name>`.

---

## 5. Firmware artifact path and format mismatch — `Parameters did not match the signature of LoadELF`

### The error

```
Parameters did not match the signature of LoadELF
Parsing line 'sysbus LoadELF $bin false sysbus.cpu0' failed
```

The sub-errors showed the file validator throwing before `LoadELF` even ran.

### Why — three compounding issues

**5a. Wrong filename.** `demo-ev.json` had `"artifact": "firmware/bms-main.elf"` but the
compiled binary in `renode/firmware/` is `bms.elf`. The path validator threw because
`firmware/bms-main.elf` does not exist in the temp work directory.

**5b. `encrypted: true` flag.** The schema passes `encrypted` to the generator, which
used to add an extra argument to `LoadELF`. The firmware is not encrypted; the flag was
a leftover from scaffolding. This produced an argument-count mismatch.

**5c. ELFs not in the temp directory.** The run API wrote generated `.resc` and `.robot`
files to a temp directory but did not copy the actual ELF binaries. At LoadELF time,
`$bin` resolved to a path inside the temp dir (`temp/firmware/bms.elf`) that didn't exist.

### Fix

All three issues:

- `demo-ev.json`: corrected `artifact` to `"firmware/bms.elf"`, set `encrypted: false`.
- Run API (`run/route.ts`): added ELF copy step after writing generated files:

```typescript
const renodeFirmwareDir = path.join(process.cwd(), "renode", "firmware");
const tempFirmwareDir   = path.join(dir, "firmware");
await fs.mkdir(tempFirmwareDir, { recursive: true });
const elfs = (await fs.readdir(renodeFirmwareDir)).filter((f) => f.endsWith(".elf"));
await Promise.all(
  elfs.map((f) => fs.copyFile(
    path.join(renodeFirmwareDir, f),
    path.join(tempFirmwareDir, f)
  ))
);
```

### Rule

The run API creates a self-contained temp work directory. Every file that a `.resc` or
`.robot` file references — ELFs, Python scripts, the platform `.repl` — must either be
resolved via `path add @${EXECDIR}` (which adds the temp dir to Renode's path search) or
be physically copied into the temp directory. ELFs are not path-searched; they must be
present at the resolved path.

---

## 6. PAC1934 — non-existent default value properties

### The error

No explicit Renode error — but the demo-ev.json had:

```json
"defaultValues": [
  { "property": "Voltage1", "value": 390 },
  { "property": "Current1", "value": 45 }
]
```

for the PAC1934 peripheral. The PAC1934 model in Renode (`Sensors.PAC1934`) does not
expose `Voltage1` or `Current1` as settable properties (these appear to be register-read
outputs, not settable from the Monitor). Attempting `pack_monitor Voltage1 390` would
produce "No such property" or silently fail depending on the Renode version.

### Fix

Cleared `defaultValues` for the PAC1934 in `demo-ev.json`. If you need to drive pack
voltage/current for tests, it must be done via register-level injection or a custom
Python peripheral, not via property assignment.

### Rule

Before adding a `defaultValues` entry for any peripheral, verify that the Renode model
exposes the property name as a `[RobotFrameworkKeyword]`-accessible property. Check the
C# source for the model and look for `public <type> <PropertyName>` with a public setter.
Properties that are read-only (sensor outputs computed from registers) cannot be set from
the Monitor.

---

## 7. SSE stream `ERR_INVALID_STATE` — writing to a closed ReadableStream controller

### The error (Next.js server console)

```
TypeError [ERR_INVALID_STATE]: Invalid state: Controller is already closed
    at ReadableStreamDefaultController.enqueue (node:internal/streams/webstreams.js:...)
```

### Why

The `ReadableStream` in the run API route was structured as:

```typescript
const stream = new ReadableStream({
  start(controller) {
    const child = spawn(...);

    child.stdout.on("data", (chunk) => {
      controller.enqueue(sse("line", ...));  // ← (A)
    });

    child.on("close", (code) => {
      controller.enqueue(sse("done", ...));
      controller.close();                    // ← (B)
    });
  },
});
```

Node.js EventEmitter callbacks are not ordered relative to each other after the `close`
event fires. In practice, the `close` event fires as soon as the child process exits, but
there can still be buffered `data` events in the event queue that have not fired yet. When
those buffered `data` callbacks run (A) after `controller.close()` (B), the attempt to
`enqueue` into a closed controller throws.

The same race can occur with `stderr.data` and `error` events.

### Fix

A `closed` boolean flag guards every `enqueue` and `close` call:

```typescript
const stream = new ReadableStream({
  start(controller) {
    let closed = false;
    const enqueue = (chunk: Uint8Array) => { if (!closed) controller.enqueue(chunk); };
    const close   = () => { if (!closed) { closed = true; controller.close(); } };

    const child = spawn(...);

    child.stdout.on("data", (chunk) => {
      for (const line of chunk.toString("utf-8").split("\n")) {
        enqueue(sse("line", line));
      }
    });

    child.on("close", (code) => {
      enqueue(sse("status", code === 0 ? "passed" : "failed"));
      enqueue(sse("done", String(code ?? -1)));
      close();
      fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
    });

    child.on("error", (err) => {
      enqueue(sse("line", `Error: ${err.message}`));
      enqueue(sse("status", "failed"));
      enqueue(sse("done", "-1"));
      close();
    });
  },
});
```

The `closed` flag also prevents `child.on("error")` from trying to re-close a controller
that was already closed by `child.on("close")` if both events fire.

### Rule

Any `ReadableStream` backed by a child process must guard `enqueue` and `close` with an
idempotency flag. Node.js EventEmitter event ordering across different event types is not
guaranteed, and buffered I/O events routinely arrive after the process `close` event.

---

## 8. Stale saved test file after generator changes

### What happened

The generator was updated (fix for §4 — I2C sysbus path), but the saved test file in
`data/demo-ev-tests.robot` was regenerated before the fix. It continued to contain the
old short-name syntax (`cell_temp Temperature 25` instead of
`sysbus.lpi2c0.cell_temp Temperature 25`). Each run used the stale file and continued to
fail.

### Why

The simulate page's GET endpoint returns the saved file from `data/<id>-tests.robot` if
it exists, falling back to a fresh generator run only if the file is absent. Once a file
has been saved — even automatically — it is never re-regenerated unless the user clicks
**Reset**.

### Fix

Delete `data/demo-ev-tests.robot` after any generator change that affects the Robot test
output. On next page load the GET endpoint regenerates from the updated generator.

```bash
rm data/demo-ev-tests.robot
```

The user sees the new content immediately; it is not persisted until they click **Save**.

### Rule

The generator is the source of truth. The saved `data/<id>-tests.robot` file is a
user-owned fork of that generated content. Any generator change that affects the Robot
test's peripheral commands (§4 level of change) requires deleting the saved test file
to take effect. Document generator breaking changes and instruct users to hit **Reset**.

---

## 9. Quick diagnosis additions for §11 of doc 10

The following entries extend the checklist in [doc 10, §11](./10-robot-testing-gotchas.md):

```
9.  "Error E00: Syntax error, unexpected '-'"
    → Peripheral ID contains a hyphen. Hyphens are not valid in .repl identifiers.
      The generator's replId() must be applied at every output site.

10. "Error E20: Undefined register '[ReferenceValue: lpi2cN]'"
    → lpi2c0/lpi2c1 are commented out in the portable build's bundled mr_canhubk3.repl.
      The missingBusDecls table in the generator must declare them inline.
      Also check: are bus and sensor in the same LoadPlatformDescriptionFromString block?
      (See §3 — single-pass rule.)

11. "No such command or device: <sensor_name>"
    → I2C (and SPI) slaves are not in the machine's top-level name map.
      Use the sysbus path: sysbus.<controller>.<sensor_name> Property value
      Confirm with: grep -r "sysbus\." in upstream Renode .robot tests for the sensor model.

12. "Parameters did not match the signature of LoadELF" (artifact-related variant)
    → The ELF file doesn't exist at the resolved path in the temp work directory.
      Check: firmware artifact path in the project JSON matches renode/firmware/<file>.elf
      Check: run API copies ELFs from renode/firmware/ to the temp dir's firmware/ subdir.

13. ERR_INVALID_STATE: Controller is already closed (Next.js server log)
    → SSE stream controller was closed by the process 'close' event but a buffered
      stdout/stderr 'data' event fired after it. Add a closed-flag guard (see §7).
```

---

## 10. Summary table — errors, root causes, fixes

| # | Error message | Root cause | Fix location |
|---|---|---|---|
| 1 | `E00: unexpected '-'` | Hyphen in peripheral ID | `replId()` helper in `generator.ts` |
| 2 | `E20: Undefined register lpi2c0` | Portable bundled `.repl` lacks lpi2c0/lpi2c1 | `missingBusDecls` table in generator |
| 3 | `E20` persists in same block | `LoadPlatformDescriptionFromString` is single-pass | Two-call split in generator |
| 4 | `No such command or device` | I2C slaves not in machine top-level name map | `sysbus.<bus>.<sensor>` prefix in all 3 generator sites |
| 5 | `Parameters did not match LoadELF` | Wrong artifact path + `encrypted` flag + ELFs not in temp dir | Fixed JSON + ELF copy step in run API |
| 6 | PAC1934 properties missing | Properties don't exist on model | Cleared `defaultValues` in project JSON |
| 7 | `ERR_INVALID_STATE` controller closed | Buffered I/O events after stream close | `closed` flag guard in run API |
| 8 | Old sensor syntax after generator fix | Stale saved test file | Delete `data/<id>-tests.robot` after generator changes |
