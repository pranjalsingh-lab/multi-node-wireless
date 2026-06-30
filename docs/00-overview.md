# 00 — Overview & Mental Model

> Read this first. It gives you the vocabulary and the end-to-end picture so the
> detailed docs make sense.

## What Renode is

Renode is a **full-system functional emulator** for embedded/IoT systems. You point it at
a description of a board (CPU + memory + peripherals) and a firmware binary, and it runs
that firmware against simulated hardware — including multi-node networks of boards.

A running Renode session contains an **Emulation** which holds one or more **Machines**.
A *Machine* is one virtual board: it owns a **system bus** (`sysbus`) onto which
**peripherals** (CPU, memory, UART, timers, IRQ controllers, …) are registered at
addresses.

## The three kinds of artifacts (this is the core split)

| Artifact | Extension | Role | "What" vs "How" | Language |
|---|---|---|---|---|
| **Platform description** | `.repl` | *Static* description of the hardware: which peripherals exist, what type each is, where it sits on the bus, how interrupts are wired. | **What** the board *is*. | A small declarative DSL (custom grammar). |
| **Renode script** | `.resc` | *Orchestration*: create a machine, load a `.repl`, load firmware, configure logging/analyzers, define the reset behavior, start. | **How** to *set up and run*. | Monitor commands (imperative). |
| **C# peripheral model** | `.cs` | The *behavior*: a class that models a real device's registers, timers, IRQ lines, etc. | **How** the hardware *behaves*. | C# (in `renode-infrastructure`). |

Mnemonic:
- **re**node **pl**atform → `.repl` = the *wiring diagram*.
- **re**node **sc**ript → `.resc` = the *setup procedure*.
- C# peripheral → the *chip's datasheet, implemented*.

A `.repl` never contains behavior; it only *names a C# type and configures it*. The C#
classes never contain addresses; addresses live in the `.repl`. The `.resc` ties a
`.repl` to a firmware image and presses "go".

## How they connect (the one diagram to remember)

```
 renode <script>.resc
        │  (Monitor parses each line; see doc 02)
        ▼
   mach create "board"                 ← make an empty Machine (owns sysbus)
   machine LoadPlatformDescription @board.repl
        │
        ▼  PlatformDescriptionMachineExtensions.LoadPlatformDescription
   CreationDriver.ProcessFile(board.repl)        ← the .repl engine (doc 01 + 04)
        │   parse → merge → resolve types → pick ctors → create → set props → wire IRQs → register
        ▼
   for each entry  "uart0: UART.STM32F7_USART @ sysbus 0x40011000":
        TypeManager.TryGetTypeByName("Antmicro.Renode.Peripherals.UART.STM32F7_USART")
        │   (default namespace "Antmicro.Renode.Peripherals." is prepended)
        ▼
        new STM32F7_USART(machine, …)             ← the C# peripheral (doc 03)
        │   machine is auto-injected; other ctor args come from the .repl
        ▼
        sysbus.Register(uart0, new BusPointRegistration(0x40011000))
        │
        ▼
   sysbus LoadELF @firmware.elf                   ← back in the .resc
   start                                          ← run
```

So the dependency direction is: **`.resc` drives → `.repl` describes → C# implements.**
The bridge from a `.repl` type name like `UART.STM32F7_USART` to a live C# object is the
`CreationDriver` + `TypeManager`, documented in [doc 04](04-repl-to-csharp-bridge.md).

## Where everything lives in the source

| Concern | Tree | Path |
|---|---|---|
| `.repl` grammar & parser | `renode` | `src/Renode/PlatformDescription/` (`Syntax/Grammar.cs`, `PreLexer.cs`, `CreationDriver.cs`) |
| `.repl` → Monitor bridge (init/reset sections, `LoadPlatformDescription`) | `renode` | `src/Renode/PlatformDescription/UserInterface/` |
| Monitor & `.resc` execution | `renode-infrastructure` | `src/Emulator/Extensions/UserInterface/` (`Monitor.cs`, `MonitorCommands.cs`, `Commands/*.cs`, `Tokenizer/`) |
| Launcher & CLI | both | `renode/renode`, `renode/src/Renode/Program.cs`, `renode-infrastructure/src/UI/` |
| Core types (`Machine`, `SystemBus`, registration points, `GPIO`, `TypeManager`) | `renode-infrastructure` | `src/Emulator/Main/` |
| Register infrastructure | `renode-infrastructure` | `src/Emulator/Main/Core/Structure/Registers/` |
| The peripherals themselves | `renode-infrastructure` | `src/Emulator/Peripherals/Peripherals/<Category>/` |
| Example platforms | `renode` | `platforms/cpus/*.repl`, `platforms/boards/*.repl` |
| Example scripts | `renode` | `scripts/single-node/*.resc`, `scripts/multi-node/*.resc` |

## Glossary

- **Emulation** — the top-level container; holds all machines, the global clock/quantum, shared media (network/UART hubs). Bound in the Monitor as `emulation`.
- **Machine** — one virtual board. Implements `IMachine`. Creates and names its `sysbus` in its constructor. Bound in the Monitor as `machine`; selected via `mach`.
- **`sysbus` (system bus)** — the address space onto which peripherals are mapped. An `IBusController`/`SystemBus`. Available in `.repl` as the implicit variable `sysbus` and in the Monitor as the peripheral name `sysbus`.
- **Peripheral** — any device model implementing `IPeripheral`. Bus-mappable ones implement `IBusPeripheral` + a width interface (`IDoubleWordPeripheral`, …) and usually `IKnownSize`.
- **Registration / registration point** — *where* a peripheral attaches to its parent. On the bus: an address (`BusPointRegistration`), an address range (`BusRangeRegistration`), or nothing (`NullRegistrationPoint`). Under a non-bus parent (e.g. a GPIO port): a number (`NumberRegistrationPoint<T>`).
- **GPIO / IRQ line** — `GPIO` objects model interrupt/signal lines. A peripheral exposes outputs (`public GPIO IRQ { get; }` or a numbered `Connections` bank) and receives inputs via `OnGPIO`. `.repl` `->` syntax wires them.
- **Monitor** — Renode's command interpreter/REPL. A `.resc` file is just a sequence of Monitor commands fed line-by-line (same parser as typing at the prompt).
- **CreationDriver** — the engine that turns a parsed `.repl` into live, registered C# objects. (`renode/src/Renode/PlatformDescription/CreationDriver.cs`.)
- **TypeManager** — process-wide index of all types in the loaded assemblies; resolves a `.repl` type name to a C# `System.Type` and lazily loads it. (`renode-infrastructure/src/Emulator/Main/Utilities/TypeManager.cs`.)
- **`using`** — overloaded term: in a `.repl` it means *include another `.repl` file*; in the Monitor it means *add a name prefix* (e.g. `using sysbus` lets you write `uart0` instead of `sysbus.uart0`). These are unrelated mechanisms.

## The instantiation pipeline (phase list)

When `machine LoadPlatformDescription @x.repl` runs, `CreationDriver.ProcessInner`
([doc 04](04-repl-to-csharp-bridge.md)) executes these phases in order
(`CreationDriver.cs:191-333`):

1. **Pre-lex** indentation into braces and strip comments (`PreLexer.cs`).
2. **Parse** the brace/semicolon form into a syntax tree (`Grammar.cs`, Sprache-based).
3. **Resolve the `using` graph** and **merge** entries (same variable name = one object, attributes combined; later files can extend earlier ones).
4. Run any **`preinit:`** sections (raw Monitor commands).
5. **Resolve types** for every entry and inline object (`TypeManager`).
6. **Verify** connections and **find constructors** (match `.repl` attributes to ctor params by name).
7. **Topologically sort** entries by creation dependencies.
8. **Create** each object (invoke the chosen constructor; auto-inject `IMachine`).
9. **Set properties** and **connect interrupts** (GPIO wiring; build `CombinedInput` combiners when several sources target one input).
10. **Sort by registration dependencies** and **register** each on its parent (`sysbus.Register(...)`), setting its name.
11. Run **`init:`** sections (Monitor commands, prefixed with the peripheral name) and arm **`reset:`** macros.

Keep this list handy; the detailed docs map onto it.

## The two directions: consuming vs. generating

The arc of this documentation set has two halves that meet:

- **Consuming** (docs [01](01-repl-format.md)–[04](04-repl-to-csharp-bridge.md)) — how Renode
  *reads* a `.repl`/`.resc` and runs it: the formats, the C# models, and the
  `CreationDriver`/`TypeManager` bridge (the pipeline above).
- **Generating** (doc [06](06-generating-a-new-board.md)) — the *inverse* problem: producing a
  correct `.repl` for a chip Renode doesn't support yet, from primary sources (SVD + reference
  manual + datasheet), and selecting which C# model each peripheral maps to.

These halves are coupled by a feedback loop. The consumption pipeline is *aggressively
validating* — loading a `.repl` resolves every type, matches every constructor, checks IRQ
arity, and registers every peripheral, emitting localized errors (`file:line` + a caret + a
constructor-selection report). So the **generator uses the consumer as its oracle**: generate →
load in Renode → read the structured errors → fix → repeat, then boot a reference firmware to
confirm. Doc 06 builds directly on [01](01-repl-format.md) (what to emit),
[03](03-csharp-peripherals.md) (when you must write a model), and
[04](04-repl-to-csharp-bridge.md) (how to read the load errors), and is verified end-to-end
against a real STM32F103 SVD.

```
   docs 01–04: how Renode CONSUMES a platform  ─────────────┐
                                                            │ (the load errors are the signal)
   doc 06: how to GENERATE a platform  ◄────── feedback ────┘
           generate ──► load in Renode ──► read errors ──► fix ──► boot firmware
```

---

## Reading paths

- **Understand the machinery:** [01](01-repl-format.md) → [02](02-resc-monitor.md) →
  [03](03-csharp-peripherals.md) → [04](04-repl-to-csharp-bridge.md).
- **Bring up a new chip:** skim this overview, then [06](06-generating-a-new-board.md) (capstone),
  dipping into 01/03/04 as it references them.
- **Quick lookup either way:** [05](05-cheatsheet.md).

Next: [`01-repl-format.md`](01-repl-format.md) — the `.repl` language in full.
