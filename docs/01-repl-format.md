# 01 — The `.repl` Platform Description Format

> `.repl` = **RE**node **PL**atform. A declarative description of *what hardware a
> machine has*: each peripheral's variable name, C# type, bus address, configuration,
> and interrupt wiring. It contains **no behavior and no firmware** — only structure.

> **Want to *generate* a whole platform for a chip Renode doesn't support yet?** This doc is the
> syntax reference; the end-to-end procedure (where each line comes from — SVD vs datasheet — and
> how to verify it) is the capstone, [doc 06](06-generating-a-new-board.md).

**Authoritative source** (all in the `renode` tree):
- Grammar: `src/Renode/PlatformDescription/Syntax/Grammar.cs` (a [Sprache](https://github.com/sprache/Sprache) parser-combinator grammar — it *is* the spec).
- Indentation/comment pre-pass: `src/Renode/PlatformDescription/PreLexer.cs`.
- Semantics (type resolution, ctor matching, registration, IRQ wiring): `src/Renode/PlatformDescription/CreationDriver.cs` (covered in [doc 04](04-repl-to-csharp-bridge.md)).
- Syntax-node classes: `src/Renode/PlatformDescription/Syntax/*.cs`.

---

## 1. The shape of a file

A `.repl` file is:

```
[ using "<path>" ... ]      # zero or more includes, at the top
<entry>
<entry>
...
```

Each **entry** describes one peripheral (or amends one). The canonical entry:

```
variableName: Category.TypeName @ registration as "alias"
    attribute: value
    attribute: value
    sourceIrq -> destination@inputIndex
```

Real example (`platforms/cpus/stm32h7.repl`):

```repl
nvic: IRQControllers.NVIC @ sysbus 0xE000E000
    priorityMask: 0xF0
    -> cpu@0
```

This declares a variable `nvic`, of C# type `Antmicro.Renode.Peripherals.IRQControllers.NVIC`,
mapped on `sysbus` at `0xE000E000`, with its `priorityMask` constructor/property set to
`0xF0`, and its default interrupt output wired to input `0` of `cpu`.

---

## 2. Lexical structure (the pre-lexer)

Before parsing, `PreLexer.Process` (`PreLexer.cs:95`) transforms the human-friendly
indented text into a brace/semicolon form that the grammar consumes. You never see this
form, but understanding it explains every syntax rule.

### Indentation → braces, newlines → semicolons
- **Exactly 4 spaces = one indent level** (`SpacesPerIndent = 4`, `PreLexer.cs:401`). Indent that isn't a multiple of 4 is an error (`GetIndentLevel`, `:361-370`). **Tabs are not indentation.**
- The **first non-empty line must be at indent 0** (`PreLexer.cs:124-127`).
- Increasing indent emits `{`; decreasing emits `}`; same-level lines are separated by `;` (`DecorateLineIfNecessary`, `:330-351`).

So this:
```repl
cpu: CPU.CortexM @ sysbus
    cpuType: "cortex-m7"
    nvic: nvic
```
is fed to the grammar as (approximately):
```
cpu: CPU.CortexM @ sysbus{
    cpuType: "cortex-m7";
    nvic: nvic};
```
That is why the grammar talks about `{ }` attribute blocks and `;` separators while you
write indentation and newlines.

### Comments
- **`//` single-line** comment — but only when the `//` is at the start of the line or **preceded by a space** (`PreLexer.FindInLine`, `:316-321`). This is deliberate: it means `http://...` inside a value is **not** treated as a comment (the slashes are preceded by `:`/`/`, not a space). Verify: URLs appear unescaped in real `.repl`/`init:` sections.
- **`/* ... */` multi-line** comment (`:258-285`). In indent mode a single-line `/* */` can't be the first non-whitespace element unless it spans the whole line, and a block comment must end at end-of-line — these are enforced (`:268-276`, `:213-216`).

### Strings
- `"..."` — single-line string. `\"` and `\\` are escapes (`Grammar.cs:139`).
- `'''...'''` — **multi-line** string (`Grammar.cs:149-153`, `MultilineStringDelimiter = "'''"`). Spans physical lines; handled in `PreLexer.HandleMultilineStrings` (`:17-66`).

---

## 3. `using` — including other `.repl` files

```repl
using "platforms/cpus/stm32f4.repl"
```

`using` lines come first and pull in other platform files (`Grammar.cs:155-164`). This is
how **boards compose CPUs**: a board file `using`s a CPU file, then adds board-specific
peripherals. Real example (`platforms/boards/stm32f4_discovery.repl`):

```repl
using "platforms/cpus/stm32f4.repl"

UserButton: Miscellaneous.Button @ gpioPortA
    -> gpioPortA@0

UserLED: Miscellaneous.LED @ gpioPortD

gpioPortD:
    12 -> UserLED@0
```

Note the last entry: `gpioPortD:` has **no type** — it *extends* the `gpioPortD` already
declared in the included CPU file (see the merge model, §9). It adds an IRQ connection
without re-declaring the peripheral.

**Path resolution** (`PlatformDescriptionMachineExtensions.UsingResolver.Resolve`,
`src/Renode/PlatformDescription/UserInterface/PlatformDescriptionMachineExtensions.cs:44-71`):
- Absolute paths used as-is.
- Paths starting with `.`/`..` are relative to the *including* file's directory.
- Otherwise each Monitor search-path prefix is tried (the Renode root is a default), so
  `platforms/cpus/stm32f4.repl` resolves from the repo root.

> `.repl` `using` (include a file) is **completely different** from Monitor `using`
> (add a name prefix) in [doc 02](02-resc-monitor.md).

---

## 4. The entry header

Grammar: `Grammar.cs:438-447`. An entry is:

```
[local] variableName : [TypeName] [registration] [as "alias"] [attribute-block]
```

| Part | Required? | Meaning |
|---|---|---|
| `local` | optional | Variable is confined to the current file's scope (not visible to includers). `LocalKeyword`, `Grammar.cs:120`. |
| `variableName` | **yes** | An identifier; the handle other entries and the Monitor use. |
| `TypeName` | optional | `Category.Class` (dotted). Present = *create* this object. Absent = *amend* an existing variable (merge/extend). |
| `registration` | optional | `@ ...` — where to attach it. Absent = create but don't register (used for objects referenced by others, e.g. `CombinedInput` fan-in). |
| `as "alias"` | optional | Register the peripheral under this name instead of `variableName`. Requires a (non-`none`) registration. `Grammar.cs:444`, validated `CreationDriver.cs:506-518`. |
| attribute block | optional | Indented `name: value` lines and IRQ lines. |

### Type names and the default namespace
`TypeName` is dotted identifiers (`Grammar.cs:134-137`), e.g. `UART.STM32F7_USART`,
`IRQControllers.NVIC`, `Memory.MappedMemory`.

Resolution (`CreationDriver.ResolveTypeOrThrow`, `:1913-1924`): the parser first tries the
name verbatim, then prepends the **default namespace `Antmicro.Renode.Peripherals.`**
(`DefaultNamespace`, `:1979`). So `UART.STM32F7_USART` →
`Antmicro.Renode.Peripherals.UART.STM32F7_USART`. The leading `Category` segment is just
the namespace tail after `Antmicro.Renode.Peripherals` — see the
[namespace↔category convention](03-csharp-peripherals.md#7-namespace--repl-category-convention).

You may also write a **fully-qualified** type (e.g. a peripheral outside that namespace, or
a test mock like `new Antmicro.Renode.UnitTests.Mocks.MockCPU`).

---

## 5. Registration — the `@` clause

> ⚠️ The `@` in a **registration** clause (`@ sysbus 0x...`) means a *bus address / attach
> point*. The `@` in an **IRQ** clause (`-> nvic@5`) means a *destination input index*.
> Same character, different meaning. Don't conflate them.

Grammar: `RegistrationInfo`/`RegistrationInfos`, `Grammar.cs:244-263`. Forms:

| Form | Example | Meaning |
|---|---|---|
| address (point) | `@ sysbus 0x40011000` | Map at a single address. Becomes a `BusPointRegistration`; the peripheral must be `IKnownSize` so its length is known. |
| range | `@ sysbus <0x58022800, +0x400>` | Map over an explicit range `[start, start+len)`. Becomes a `BusRangeRegistration`. (`<a, b>` is start/end; `<a, +n>` is start/length — the `+` form, `Grammar.cs:170-171`.) |
| bare | `@ sysbus` | Attach with no address (`NullRegistrationPoint`). Used for CPUs and for things addressed another way. |
| numbered | `@ gpioPortA` *(point on a non-bus parent)* or `@ i2c 0x20` | Attach to a non-bus parent at a number/slot (`NumberRegistrationPoint<T>`). |
| reference parent | `@ gpioPortD` | The parent can be any registered peripheral that exposes a suitable register interface, not just `sysbus`. |
| cancel | `@ none` | Cancel/skip registration for this variable (`NoneRegistrationInfo`, `Grammar.cs:251-254`). The object is created but not put on any bus. Common for `Miscellaneous.CombinedInput` IRQ-combiners. |
| multi | `@ { sysbus 0x...; sysbus new Bus.BusMultiRegistration {...} }` | Register the **same object at several points** (`RegistrationInfos`, `Grammar.cs:256-263`). Points separated by `;` inside `{ }`. |

Exactly how each form selects a registration-point constructor is in
[doc 04 §2](04-repl-to-csharp-bridge.md#2-the-registration-model). Real multi-registration
(`platforms/cpus/imxrt1064.repl`):

```repl
flex_spi: SPI.IMXRT_FlexSPI @ {
    sysbus 0x402A8000;
    sysbus new Bus.BusMultiRegistration { address: 0x60000000; size: 0xF000000; region: "ciphertext" }
}
```

Real `@ none` (`platforms/cpus/stm32h7.repl`) — a combiner that has no bus address but
fans several lines into one NVIC input:

```repl
nvicInput23: Miscellaneous.CombinedInput @ none
    numberOfInputs: 5
    -> nvic@23
```

---

## 6. Attributes — constructor args and properties

Inside the indented block, the most common attribute is `name: value`
(`ConstructorOrPropertyAttribute`, `Grammar.cs:265-269`). The **same syntax** is used for:

- **Constructor arguments** — matched to a C# constructor parameter *by name* (e.g.
  `frequency: 200000000` → ctor param `frequency`). See
  [doc 04 §… ctor selection](04-repl-to-csharp-bridge.md).
- **Properties** — matched to a public property *with a public setter* (e.g.
  `priorityMask: 0xF0`).

The parser decides which after type resolution: if the name matches a constructor
parameter it's a ctor arg; otherwise it must be a writable property
(`CreationDriver.cs:555-592`, `ValidateProperty` requires `GetSetMethod() != null`,
`:1312-1315`). You don't annotate which is which.

### Value types

| Value | Syntax | Notes / source |
|---|---|---|
| Decimal number | `480000000`, `1_000_000` | `_` digit separators allowed (`Grammar.cs:64-67`). Optional sign; optional `.frac`. |
| Hex number | `0xF0`, `0x5800_2800` | `Grammar.cs:80-93`. |
| String | `"cortex-m7"` | single-line, `\"`/`\\` escapes. |
| Multi-line string | `'''...'''` | `Grammar.cs:149`. |
| Boolean | `true` / `false` (also `True`/`False`) | `Grammar.cs:122-126,195-200`. |
| Enum (full) | `PrivilegedArchitecture.Priv1_10` | `Grammar.cs:175-178`. Namespace/type checked against the target (`CreationDriver.cs:1603-1624`). |
| Enum (shorthand) | `.Priv1_10` | leading dot, type inferred from the target (`Grammar.cs:180-183`). |
| Range | `<0x0, 0x1000>` or `<0x0, +0x1000>` | start/end or start/length. Converts to `Range`. |
| Reference | `nvic` (a bare identifier) | refers to another entry's object (`ReferenceValue`, `Grammar.cs:193`). E.g. `nvic: nvic` passes the `nvic` object as the ctor arg/property `nvic`. |
| Inline object | `new Bus.BusMultiRegistration { address: 0x...; size: 0x... }` | construct a nested object (`ObjectValue`, `Grammar.cs:187-191`). |
| List | `[1, 2, 3]`, `[]`, `[[0, 1], [1, 3]]` | `Grammar.cs:202-214`. Trailing comma OK; nested lists OK; `empty` allowed as an element. |
| Dictionary | `{ key: value; key: value }` | `Grammar.cs:230-235`. Pairs separated by `;`; keys are scalar values. |
| `none` | `name: none` | explicit null; during merge it *removes* a previously-set attribute (`Grammar.cs:128`). |
| `empty` | `name: empty` | the type's default value (`EmptyValue`, `Grammar.cs:130`; `CreationDriver.cs:1555-1558`). |

Real examples:

```repl
# numbers, strings, references (platforms/cpus/stm32h7.repl)
cpu: CPU.CortexM @ sysbus
    cpuType: "cortex-m7"
    numberOfMPURegions: 16
    nvic: nvic                       # 'nvic' is a reference to the nvic entry

# list of lists (platforms/cpus/stm32h7.repl)
gpioPortK: GPIOPort.STM32_GPIOPort @ sysbus <0x58022800, +0x400>
    numberOfAFs: 16
    invertedAFPins: [[0, 1], [1, 3]]

# inline object inside a registration (platforms/cpus/imxrt1064.repl)
flex_spi: SPI.IMXRT_FlexSPI @ {
    sysbus 0x402A8000;
    sysbus new Bus.BusMultiRegistration { address: 0x60000000; size: 0xF000000; region: "ciphertext" }
}
```

---

## 7. Interrupt (IRQ) wiring — the `->` clause

This is the most distinctive part of `.repl`. An IRQ attribute connects a **GPIO output**
of *this* peripheral to a **GPIO input** of another. Grammar:
`SimpleIrqAttribute`/`MultiIrqAttribute`/`NoneIrqAttribute`, `Grammar.cs:397-415`.

### Basic forms

| Form | Example | Meaning |
|---|---|---|
| Default source | `-> cpu@0` | This peripheral's *single* `GPIO` output (or the one tagged `[DefaultInterrupt]`) → input `0` of `cpu`. The source is omitted. |
| Named source | `IRQ -> nvic@27` | The `GPIO` property named `IRQ` → input `27` of `nvic`. |
| Numbered source | `0 -> exti@5` | Numbered output line `0` (from `INumberedGPIOOutput.Connections`) → input `5`. |
| Range → range | `[0-15] -> nvic@[0-15]` | Lines 0..15 → inputs 0..15, paired in order. Arity must match. |
| Multiplex (fan-out) | `IRQ -> nvic@27 \| dma@2 \| dma@4` | One source → several destinations, separated by `\|`. |
| To nothing | `-> none` | Explicitly leave the source unconnected (`NoneIrqAttribute`). |
| Local receiver | `[0-7] -> syscfg#10@[0-7]` | `dest#localIndex` selects a sub-receiver via `ILocalGPIOReceiver.GetLocalReceiver` (`Grammar.cs:380-383`, `CreationDriver.cs:957-960`). |

The number after `@` on the **destination** is the **input pin index** on that receiver, not
an address. The number/identifier before `->` identifies the **source** output.

Real, dense example (`platforms/cpus/stm32h7.repl`) — an EXTI controller routing many
lines to NVIC inputs, NVIC input combiners, and using ranges, lists, and singletons:

```repl
exti: IRQControllers.STM32H7_EXTI @ sysbus 0x58000000
    [0-4] -> nvic@[6-10]
    [5-9] -> nvicInput23@[0-4]
    [16-19] -> nvic@[1, 41, 2, 3]      # destination list need not be contiguous
    41 -> nvicInput86@0
    [85, 86] -> nvic@[94, 61]          # source list -> destination list
```

### How sources are resolved (important)
- **No source** before `->`: the parser looks for GPIO-typed properties. If there's exactly
  one, it's used; if several, the one with `[DefaultInterrupt]` is used; otherwise it's an
  ambiguity error (`CreationDriver.cs:1228-1256`).
- **Identifier source** (e.g. `IRQ`): must be a `public GPIO` property of that name
  (`:1275-1283`).
- **Numbered source** (e.g. `0`, `[0-15]`): the peripheral must implement
  `INumberedGPIOOutput`; the number indexes `Connections` (`:1286-1290`,
  `:938-945`).

### Fan-in is automatic (CombinedInput)
If **several sources target the same destination input**, the driver automatically inserts a
`CombinedInput` so they OR together correctly (`CreationDriver.cs:245-270`, `:966-977`).
You only insert an explicit `CombinedInput` (the `@ none` pattern in §5) when you need to
*name* it or cap the input count.

---

## 8. Monitor sections inside `.repl`: `preinit:`, `init:`, `reset:`

A `.repl` can embed **Monitor commands** (the `.resc` language, [doc 02](02-resc-monitor.md))
in three labeled sections. Grammar: `Grammar.cs:291-310`. Each can take an `add` suffix
(`init add:`) to *append* to a section inherited from an included file rather than replace it.

| Section | When it runs | Prefixing | Source |
|---|---|---|---|
| `preinit:` | **before** the peripheral is created (e.g. to compile/prepare something) | none — run as global Monitor commands | `CreationDriver.cs:205-219`; `MonitorScriptHandler.Execute` with `scriptable == null` (`MonitorScriptHandler.cs:29-38`) |
| `init:` | **after** the peripheral is created and registered | each line is **prefixed with the peripheral's name** | `CreationDriver.cs:304-310`; `MonitorScriptHandler.cs:40-55` |
| `reset:` | registered as a per-peripheral `reset` **macro**, replayed on every machine/peripheral reset | each line prefixed with the peripheral's name | `CreationDriver.cs:312-317`; `MonitorScriptHandler.RegisterReset`, `:57-84` |

So an `init:` on `cpu` like this (`platforms/cpus/nxp-k6xf.repl`):

```repl
cpu: ...
    init:
        ApplySVD @https://dl.antmicro.com/projects/renode/svd/MK64F12.svd.gz
```

executes the Monitor command `cpu ApplySVD @https://.../MK64F12.svd.gz` after creation.
A `reset:` (`platforms/cpus/egis_et171.repl`) can use Monitor backtick-expressions:

```repl
cpu: ...
    reset:
        PC `syscon ResetVector`        # -> "cpu PC `syscon ResetVector`" as a reset macro
```

> This is the key unification: **`.repl` `init`/`reset`/`preinit` sections are literally
> `.resc`/Monitor commands.** The `.repl` and `.resc` languages meet here.

---

## 9. The merge / extend model

`.repl` entries are **merged by variable name** across the whole `using` graph
(`CreationDriver.cs:131-174`, `variableStore.GetMergedEntries`). Rules of thumb:

- A variable is **declared once** with a type (declaring it twice is an error,
  `HandleDoubleDeclarationError`, `:176-189`). The declaration can live in any file in the
  include hierarchy.
- **Untyped entries amend** the declared variable: they add attributes, IRQ connections, or
  a registration. This is how a board file tweaks a CPU file's peripheral
  (`nvic:` with just `systickFrequency: ...`, or `gpioPortD:` adding an IRQ — §3).
- Setting an attribute to **`none`** in a later entry removes it.
- Already-registered peripherals and the machine itself are pre-seeded as variables
  (`sysbus`, `machine`, any previously created `cpu`, …) so you can reference them without
  declaring them (`PrepareVariables`, `:354-363`; details in
  [doc 04 §3](04-repl-to-csharp-bridge.md#3-why-sysbus-is-a-usable-variable-without-being-declared)).

The smallest possible "platform" leans entirely on this — `platforms/cpus/stm32h743.repl`
is just:

```repl
using "platforms/cpus/stm32h7.repl"

nvic:
    systickFrequency: 480_000_000
```

It includes the full STM32H7 and overrides one field of the already-declared `nvic`.

---

## 10. Worked example, fully annotated

```repl
# A board: take a CPU platform and add board-specific devices.
using "platforms/cpus/stm32f4.repl"            # include CPU + its peripherals

# A button wired to a GPIO port (registered ON gpioPortA, not on the bus):
UserButton: Miscellaneous.Button @ gpioPortA   # parent is a peripheral, not sysbus
    -> gpioPortA@0                              # Button's default GPIO output -> gpioPortA input 0

# An LED registered on gpioPortD:
UserLED: Miscellaneous.LED @ gpioPortD

# Extend the already-declared gpioPortD (no type => amend) to drive the LED:
gpioPortD:
    12 -> UserLED@0                             # gpioPortD output line 12 -> LED input 0
```

What the engine does with it (cross-ref [doc 04](04-repl-to-csharp-bridge.md)): resolves
`Miscellaneous.Button`/`LED` types, constructs them (auto-injecting the machine), registers
`UserButton` on the existing `gpioPortA` and `UserLED` on `gpioPortD`, then connects the
GPIO lines. The `gpioPortD:` entry merges into the port declared by the included CPU file.

---

## 11. Common errors & gotchas

- **Indent not a multiple of 4** → `WrongIndent` (`PreLexer.cs:364-367`). Tabs don't count as indent.
- **`//` not preceded by a space** is *not* a comment — but two slashes mid-value (like `http://`) are intentionally fine; a stray `x//y` may surprise you. Prefer a leading space before `//`.
- **Using a property without a public setter** → `PropertyNotWritable` (`CreationDriver.cs:1312-1315`). If a value should be settable from `.repl`, the C# needs `{ get; set; }` (not `{ get; private set; }`).
- **No matching constructor / ambiguous constructor** → the driver prints a detailed "constructor selection report" (`CreationDriver.cs:1666-1819`). Usually a misnamed attribute or a wrong value type.
- **IRQ arity mismatch** (`[0-3] -> x@[0-2]`) → `WrongIrqArity` (`:1264-1268`).
- **Destination isn't an IRQ receiver** (doesn't implement `IGPIOReceiver`) → `IrqDestinationIsNotIrqReceiver` (`:1296-1301`).
- **`@ sysbus 0xADDR` on a peripheral that isn't `IKnownSize`** → no point registration ctor matches; use a range `<addr, +size>` instead, or make the type `IKnownSize`.
- **`as "alias"` without a registration** → error (`:506-518`); aliases only make sense for registered peripherals.

---

Next: [`02-resc-monitor.md`](02-resc-monitor.md) — the `.resc`/Monitor language that
orchestrates these platforms (and that `init`/`reset`/`preinit` sections speak).
