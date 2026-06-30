# 03 — Authoring C# Peripherals

> The behavioral models that a `.repl` instantiates. A peripheral is a C# class in the
> **`renode-infrastructure`** tree that models a real device's registers, timers, and
> interrupt lines. It contains behavior but **no bus addresses** (those live in the `.repl`).

**Where peripherals live:**
`renode-infrastructure/src/Emulator/Peripherals/Peripherals/<Category>/<Name>.cs`
(categories: `UART`, `Timers`, `GPIOPort`, `IRQControllers`, `SPI`, `I2C`, `Memory`,
`Miscellaneous`, `DMA`, `Sensors`, …). Core/base types live under
`renode-infrastructure/src/Emulator/Main/`.

All paths below are within the `renode-infrastructure` tree unless noted.

---

## 1. Core interfaces & base classes

Declared under `src/Emulator/Main/`.

### `IPeripheral` — the root
`src/Emulator/Main/Peripherals/IPeripheral.cs:22-25`:
```csharp
[Icon("box")]
public interface IPeripheral : IEmulationElement, IAnalyzable
{
    void Reset();
}
```
Every peripheral implements `Reset()`. `IEmulationElement` provides the logging extension
methods (`this.Log(...)`, `this.DebugLog(...)`, §5). The same file's `IPeripheralExtensions`
(`:27-120`) gives `GetGPIOs`, `HasGPIO`, `GetMachine` — used by the framework to discover a
peripheral's GPIO outputs by reflection.

### `IBusPeripheral` — "mappable on the system bus"
`src/Emulator/Main/Peripherals/Bus/IBusPeripheral.cs:10-12` — a pure marker
(`interface IBusPeripheral : IPeripheral {}`). The access-width interfaces extend it.

### Access-width interfaces — how the bus reads/writes you
In `src/Emulator/Main/Peripherals/Bus/`:
- `IDoubleWordPeripheral.cs:11-16` — `uint ReadDoubleWord(long offset)` / `void WriteDoubleWord(long, uint)`
- `IWordPeripheral.cs:11-16` — 16-bit
- `IBytePeripheral.cs:11-16` — 8-bit
- `IQuadWordPeripheral` — 64-bit

Implement the width(s) the hardware actually uses. If the guest accesses a width you didn't
implement, the class attribute `[AllowedTranslations(...)]` lets the bus synthesize it from a
width you did (e.g. `RiscVMachineTimer.cs:16` translates dword↔quadword).

### `IKnownSize` — declares the MMIO window length
`src/Emulator/Main/Peripherals/IKnownSize.cs:13-16`:
```csharp
public interface IKnownSize : IBusPeripheral { long Size { get; } }
```
Implement this (usually a one-liner, `public long Size => 0x100;`) so the `.repl` can map you
with just `@ sysbus 0xADDR` (a `BusPointRegistration`, which needs your size to compute the
range — see [doc 04](04-repl-to-csharp-bridge.md#2-the-registration-model)). Without it you
must use a range registration `@ sysbus <addr, +size>`.

### `IProvidesRegisterCollection<T>` — exposes the register table
`src/Emulator/Main/Core/Structure/Registers/RegisterCollection.cs:548-551`:
```csharp
public interface IProvidesRegisterCollection<T> where T : IRegisterCollection
{ T RegistersCollection { get; } }
```
Implementing this (with a `DoubleWordRegisterCollection`, etc.) unlocks the fluent
`Registers.X.Define(this)…` helpers and register-dump/hook tooling.

### GPIO interfaces (under `src/Emulator/Main/Core/`)
- `IGPIOReceiver.cs:14-17` — `void OnGPIO(int number, bool value)`: how you **receive** a line.
- `INumberedGPIOOutput.cs:14-17` — `IReadOnlyDictionary<int, IGPIO> Connections { get; }`: how
  you **expose a numbered bank** of outputs (IRQ controllers, GPIO ports).
- `ILocalGPIOReceiver.cs:10-13` — `IGPIOReceiver GetLocalReceiver(int index)`: front many
  sub-receivers behind one object (the `.repl` `dest#localIndex` syntax).

### `IPeripheralContainer<TPeripheral, TRegistrationPoint>` — hosts child peripherals
`src/Emulator/Main/Core/Structure/IPeripheralContainer.cs:17-24` — implemented by parents that
can have children registered under them (a bus, an I2C/SPI controller, a GPIO port). It
extends `IRegisterablePeripheral<,>` (the `Register`/`Unregister` contract used by the
`.repl` engine — [doc 04 §2](04-repl-to-csharp-bridge.md#2-the-registration-model)).

---

## 2. Register infrastructure

### Register collections
`src/Emulator/Main/Core/Structure/Registers/RegisterCollection.cs:18-44` declares four sealed
collections: `QuadWordRegisterCollection`, `DoubleWordRegisterCollection`,
`WordRegisterCollection`, `ByteRegisterCollection`. Each is built with the owning peripheral
(for logging) and an optional `offset → register` map. The engine,
`BaseRegisterCollection` (`:146`):
- `Read(offset)` / `Write(offset, value)` dispatch to the register at `offset`; a miss calls
  `parent.LogUnhandledRead/Write` (`:175-234`).
- `DefineRegister(offset, resetValue=default, softResettable=true)` (`:436-455`).
- `Reset()` resets every register (`:276`).

### Registers and field-definition methods
`src/Emulator/Main/Core/Structure/Registers/PeripheralRegister.cs` defines the per-width
registers (`DoubleWordRegister` `:162`, `WordRegister` `:192`, `ByteRegister` `:222`,
`QuadWordRegister`) and the field helpers:
- `DefineFlagField(int position, FieldMode mode=Read|Write, …callbacks…, name)` → `IFlagRegisterField` (`:323`).
- `DefineValueField(int position, int width, FieldMode mode=Read|Write, …)` → `IValueRegisterField` (`:354`).
- `DefineEnumField<TEnum>(int position, int width, …)` → `IEnumRegisterField<TEnum>` (`:386`).
- `Reserved` / `Tag` / `TaggedFlag` document bits without modeling them.

Callback semantics (documented inline at `PeripheralRegister.cs:344-352`):
- **`valueProviderCallback`** runs on read and *supplies* the value returned.
- **`writeCallback`** runs on write; `arg1` = value before, `arg2` = value written.
- **`changeCallback`** runs when the field's value actually changes.
- **`name`** is a comment only ("Ignored parameter, for convenience", `:353`).

### Fluent `With…` extensions (the common style)
`src/Emulator/Main/Core/Structure/Registers/PeripheralRegisterExtensions.cs` wraps the
`Define…` methods to **return the register** for chaining:
`WithValueField`, `WithFlag`, `WithEnumField` (and `out IxxxRegisterField` overloads to
capture a handle), `WithFlags`/`WithValueFields` (banks), `WithReservedBits`, `WithTag`,
`WithTaggedFlag`, and register-wide `WithReadCallback`/`WithWriteCallback`/`WithChangeCallback`.
`FieldMode` (`Registers/FieldMode.cs:15-29`) includes `Read`, `Write`, `Set`,
`WriteOneToClear`, `WriteZeroToClear`, `ReadToClear`, … (default `Read | Write`).

### `BasicDoubleWordPeripheral` — the usual starting point
`src/Emulator/Main/Peripherals/BasicDoubleWordPeripheral.cs:17-49`:
```csharp
public abstract class BasicDoubleWordPeripheral : IDoubleWordPeripheral,
    IProvidesRegisterCollection<DoubleWordRegisterCollection>, IHasMappedRegisters
{
    public BasicDoubleWordPeripheral(IMachine machine)
    {
        this.machine = machine;
        sysbus = machine.GetSystemBus(this);
        RegistersCollection = new DoubleWordRegisterCollection(this);
        mapper = new RegisterMapper(this.GetType());
    }
    public virtual void Reset()                        => RegistersCollection.Reset();
    public virtual uint ReadDoubleWord(long offset)    => RegistersCollection.Read(offset);
    public virtual void WriteDoubleWord(long o, uint v)=> RegistersCollection.Write(o, v);
    public DoubleWordRegisterCollection RegistersCollection { get; private set; }
    protected readonly IMachine machine; …
}
```
It wires the collection, the bus accessors, `Reset`, and a `RegisterMapper` (so offsets log as
register names). `BasicWordPeripheral` / `BasicBytePeripheral` are the analogues. The same file
(`:51-145`) provides the `Registers.X.Define(this)…` enum-extension helpers used in example B.

---

## 3. GPIO / IRQ model

### The `GPIO` class
`src/Emulator/Main/Core/GPIO.cs:18` — `[Convertible] public sealed class GPIO : IGPIOWithHooks`.
`IGPIO` (`Core/IGPIO.cs:12-30`) has `IsSet`, `Set(bool)`, `Toggle()`, `Connect/Disconnect`.
Crucially, `Set` only propagates on an **edge** and pushes to every connected receiver
(`GPIO.cs:42-58`):
```csharp
public void Set(bool value)
{
    lock(sync)
    {
        if(state == value) return;          // edge-filtered
        state = value;
        for(var i = 0; i < targets.Count; ++i)
            targets[i].Receiver.OnGPIO(targets[i].Number, state);
        stateChangedHook(value);
    }
}
```

### Exposing a single interrupt output
The idiomatic pattern — a read-only auto-property initialized once:
```csharp
public GPIO IRQ { get; } = new GPIO();      // RiscVMachineTimer.cs:64
```
Raise/lower it from one `UpdateInterrupts()` choke-point:
```csharp
private void UpdateInterrupts()             // RiscVMachineTimer.cs:74-79
{
    bool shouldInterrupt = mTimer.Value >= mTimer.Compare;
    this.Log(LogLevel.Noisy, "Setting IRQ: {0}", shouldInterrupt);
    IRQ.Set(shouldInterrupt);
}
```
A peripheral may expose several `GPIO` properties (e.g. an IRQ line and a DMA-request line).
The framework finds them by reflecting over public `GPIO`-typed properties.

### `[DefaultInterrupt]` — disambiguating multiple outputs
`src/Emulator/Main/Peripherals/DefaultInterruptAttribute.cs:19-22`. When a peripheral has
several `GPIO` outputs, mark one with `[DefaultInterrupt]` so a `.repl` can connect to it with
the bare `-> dest@n` form (no source name). Used e.g. `RenesasDA14_GPT.cs:84-85`.

### Numbered output banks — `INumberedGPIOOutput.Connections`
For a bank of outputs, populate `Connections` in the constructor:
```csharp
var innerConnections = new Dictionary<int, IGPIO>();   // STM32H7_EXTI.cs:21-26
for(var i = 0; i < CoreCount * LinesPerCore; i++)
    innerConnections[i] = new GPIO();
Connections = new ReadOnlyDictionary<int, IGPIO>(innerConnections);
```
In `.repl` these are addressed by index: `[0-15] -> exti@[0-15]`.

### Receiving an IRQ — `OnGPIO`
Implement `IGPIOReceiver.OnGPIO(int number, bool value)`. Canonical body
(`GPIOPort/BaseGPIOPort.cs:26-34`): validate the pin, store state.

### `[GPIO]` class attribute — declare input/output counts
`src/Emulator/Main/Core/GPIOAttribute.cs:13-33` — `[GPIO(NumberOfInputs = 1)]` (default 0 =
unbounded). Used by `GPIO.Validate` to reject out-of-range connections.

---

## 4. Constructor convention & how `.repl` attributes map

### `IMachine machine` is auto-injected
By convention the **first ctor parameter is `IMachine machine`** (`RiscVMachineTimer.cs:19`,
`BasicDoubleWordPeripheral.cs:19`, `BaseGPIOPort.cs:91`). The `.repl` never supplies it — the
platform engine fills any `IMachine`-typed parameter with the current machine and **forbids**
the user from setting it (`CreationDriver.cs:1825-1834`, `:1732-1736`; see
[doc 04 §6](04-repl-to-csharp-bridge.md#6-imachinemachine-auto-injection)).

### Other parameters map by name
A `.repl` `name: value` is matched to a constructor parameter **by name** (case-sensitive, or
via `[NameAlias]`), then converted to the parameter type (`CreationDriver.cs:1737-1751`). If no
attribute matches a parameter, the C# default value is used. So:
```csharp
public RiscVMachineTimer(IMachine machine, ulong frequency) { … }
```
is configured by:
```repl
clint: Timers.RiscVMachineTimer @ sysbus 0x...
    frequency: 1000000        # -> ctor param 'frequency'; machine is implicit
```

### What makes a *property* settable from `.repl`
A **public setter** — nothing else. The engine rejects assigning a property whose
`GetSetMethod()` is null (`CreationDriver.cs:1312-1315`) and otherwise invokes the setter
(`:889`). So `public T Foo { get; set; }` is `.repl`-settable; `{ get; }` or
`{ get; private set; }` is not.

### `[NameAlias]`
`src/Emulator/Main/Peripherals/NameAliasAttribute.cs:15-27` — an alternative name a ctor
parameter or enum type can be referred to by in `.repl` (checked in
`CreationDriver.NameOrAliasMatches`, `:1846-1854`).

---

## 5. Reset, logging, read/write plumbing

### `Reset()`
With a register collection it's typically `RegistersCollection.Reset()`. When subclassing a
base that has its own reset, call `base.Reset()` first:
```csharp
public override void Reset() { base.Reset(); RegistersCollection.Reset(); }   // Murax_GPIO.cs:34-38
```

### Logging
Extension methods on `IEmulationElement` (`src/Emulator/Main/Logging/Logger.cs`):
`this.Log(LogLevel.X, msg, args…)` (`:306-326`) and shortcuts `this.NoisyLog`,
`this.DebugLog`, `this.InfoLog`, `this.WarningLog`, `this.ErrorLog`. Levels: `Noisy(-1)`,
`Debug(0)`, `Info(1)`, `Warning(2)`, `Error(3)`. Unmodeled register accesses are logged
automatically (with register names when the peripheral is `IHasMappedRegisters`).

### Read/Write wiring
With a collection, the body is mechanical — forward the offset:
```csharp
public uint ReadDoubleWord(long offset)         => RegistersCollection.Read(offset);
public void WriteDoubleWord(long offset, uint v) => RegistersCollection.Write(offset, v);
```
Two construction styles: build an `offset → register` `Dictionary` keyed by an `enum : long`
and pass it to the collection ctor (example A), or call `Registers.X.Define(this)…` fluently
in a `DefineRegisters()` method (example B).

---

## 6. Two complete, annotated real peripherals

### Example A — a timer with an IRQ output: `RiscVMachineTimer`
`src/Emulator/Peripherals/Peripherals/Timers/RiscVMachineTimer.cs` (~102 lines):
```csharp
namespace Antmicro.Renode.Peripherals.Timers          // category = "Timers"
{
    [AllowedTranslations(AllowedTranslation.DoubleWordToQuadWord)]  // 32-bit accesses hit 64-bit handlers
    public class RiscVMachineTimer : IQuadWordPeripheral, IKnownSize, IHasFrequency
    {
        public RiscVMachineTimer(IMachine machine, ulong frequency)   // machine auto-injected; 'frequency:' from .repl
        {
            mTimer = new ComparingTimer(machine.ClockSource, frequency, this, nameof(mTimer),
                direction: Time.Direction.Ascending, workMode: Time.WorkMode.Periodic,
                eventEnabled: true, enabled: true);
            mTimer.CompareReached += () => { UpdateInterrupts(); };

            var registersMap = new Dictionary<long, QuadWordRegister>();
            registersMap.Add((long)Registers.Time, new QuadWordRegister(this)
                .WithValueField(0, 64, name: "TIME",
                    valueProviderCallback: _ => TimerValue,             // read = current value
                    writeCallback: (_, value) => mTimer.Value = value)  // write = set value
                .WithWriteCallback((_, __) => UpdateInterrupts()));
            registersMap.Add((long)Registers.Compare, new QuadWordRegister(this)
                .WithValueField(0, 64, name: "COMPARE",
                    valueProviderCallback: _ => mTimer.Compare,
                    writeCallback: (_, value) => mTimer.Compare = value)
                .WithWriteCallback((_, __) => UpdateInterrupts()));
            RegistersCollection = new QuadWordRegisterCollection(this, registersMap);
            this.machine = machine;
        }

        public void Reset() { mTimer.Reset(); UpdateInterrupts(); }
        public ulong ReadQuadWord(long offset)  => RegistersCollection.Read(offset);
        public void  WriteQuadWord(long o, ulong v) => RegistersCollection.Write(o, v);

        public QuadWordRegisterCollection RegistersCollection { get; }
        public GPIO IRQ { get; } = new GPIO();         // interrupt output (.repl: "IRQ -> nvic@7")
        public long Size => 0x10;                       // IKnownSize -> can map with @ sysbus 0xADDR
        public ulong Frequency { get => mTimer.Frequency; set => mTimer.Frequency = value; }

        private void UpdateInterrupts()
        {
            bool shouldInterrupt = mTimer.Value >= mTimer.Compare;
            this.Log(LogLevel.Noisy, "Setting IRQ: {0}", shouldInterrupt);
            IRQ.Set(shouldInterrupt);
        }
        private readonly IMachine machine;
        private readonly ComparingTimer mTimer;
        enum Registers { Time = 0x00, Compare = 0x08, }   // offsets, cast to (long)
    }
}
```
Takeaways: (1) `IMachine` + a real param (`frequency`) both map to `.repl`; (2) register map
keyed by an `enum : long`; (3) `valueProviderCallback`/`writeCallback` model live behavior;
(4) the IRQ is a single `GPIO` property driven from one `UpdateInterrupts()`.

### Example B — a GPIO port: `Murax_GPIO` (uses `BaseGPIOPort` + register collection)
`src/Emulator/Peripherals/Peripherals/GPIOPort/Murax_GPIO.cs` (~77 lines):
```csharp
namespace Antmicro.Renode.Peripherals.GPIOPort         // category = "GPIOPort"
{
    public class Murax_GPIO : BaseGPIOPort,             // gives Connections[], OnGPIO, State[], machine
        IProvidesRegisterCollection<DoubleWordRegisterCollection>, IDoubleWordPeripheral, IKnownSize
    {
        public Murax_GPIO(IMachine machine) : base(machine, 32)   // 32 GPIO lines
        {
            RegistersCollection = new DoubleWordRegisterCollection(this);
            DefineRegisters();
        }
        public uint ReadDoubleWord(long offset)  => RegistersCollection.Read(offset);
        public void WriteDoubleWord(long offset, uint value) => RegistersCollection.Write(offset, value);
        public override void Reset() { base.Reset(); RegistersCollection.Reset(); }
        public long Size => 0xC;
        public DoubleWordRegisterCollection RegistersCollection { get; private set; }

        private void DefineRegisters()
        {
            Registers.Output.Define(this)              // enum-extension Define() from BasicDoubleWordPeripheral.cs
                .WithValueField(0, 32, out output,
                    writeCallback: (_, val) => RefreshConnectionsState(),
                    valueProviderCallback: _ => BitHelper.GetValueFromBitsArray(
                        Connections.Where(x => x.Key >= 0).OrderBy(x => x.Key).Select(x => x.Value.IsSet)));
            Registers.OutputEnable.Define(this)
                .WithValueField(0, 32, out outputEnable,
                    writeCallback: (_, val) => RefreshConnectionsState());
        }
        private void RefreshConnectionsState()
        {
            var outputBits = BitHelper.GetBits((uint)outputEnable.Value);
            var bits       = BitHelper.GetBits((uint)output.Value);
            for(var i = 0; i < 32; i++)
                Connections[i].Set(bits[i] && outputBits[i]);   // drive each output line
        }
        private IValueRegisterField outputEnable, output;
        private enum Registers { Input = 0x0, Output = 0x4, OutputEnable = 0x8 }
    }
}
```
Takeaways: (1) `Registers.Output.Define(this)` works because the class provides a
`DoubleWordRegisterCollection`; (2) `out output` captures the field handle for later reads;
(3) the GPIO bank (`Connections`, `State[]`, `OnGPIO`, `Reset`) comes free from `BaseGPIOPort`.

For a `BasicDoubleWordPeripheral` subclass that *only* adds registers, see
`src/Emulator/Peripherals/Peripherals/Miscellaneous/MAX32650_PWRSEQ.cs` — `: base(machine)`,
`IKnownSize`, one register defined with `WithTag`/`WithReservedBits`/`WithTaggedFlag`/`WithFlag`.

---

## 7. Namespace ↔ `.repl` category convention

The namespace is always `Antmicro.Renode.Peripherals.<Category>`, and **the `.repl` prefix is
exactly the namespace segment after `Antmicro.Renode.Peripherals`** (which matches the
directory by convention). Verified pairings:

| Source file | Namespace | `.repl` reference |
|---|---|---|
| `…/UART/STM32F7_USART.cs` | `…Peripherals.UART` | `UART.STM32F7_USART` |
| `…/IRQControllers/NVIC.cs` | `…Peripherals.IRQControllers` | `IRQControllers.NVIC` |
| `…/GPIOPort/STM32_GPIOPort.cs` | `…Peripherals.GPIOPort` | `GPIOPort.STM32_GPIOPort` |
| `…/Miscellaneous/CombinedInput.cs` | `…Peripherals.Miscellaneous` | `Miscellaneous.CombinedInput` |
| `…/Memory/MappedMemory.cs` | `…Peripherals.Memory` | `Memory.MappedMemory` |

So a class `RiscVMachineTimer` in `namespace Antmicro.Renode.Peripherals.Timers` is referenced
as `Timers.RiscVMachineTimer`. The resolver keys off the **namespace** (via the default-prefix
logic in [doc 04 §1](04-repl-to-csharp-bridge.md#1-typemanager--type-resolution--assembly-scanning)),
not the directory — but keep them aligned.

A complete `.repl` entry annotated against the C#:
```repl
usart1: UART.STM32F7_USART @ sysbus 0x40013800   # var : Category.Class @ bus 0xADDR
    frequency: 200000000                          #   ctor param 'frequency' (by name)
    IRQ -> nvic@27 | dma@2 | dma@4                #   GPIO property 'IRQ' -> receiver@input
```

---

## 8. Making a new peripheral available

A new `.cs` file in the right category folder is compiled into `Infrastructure.dll`
automatically (the project globs `**/*.cs`), and `TypeManager` then indexes it — so **"drop a
`.cs` in the right folder, rebuild, reference it from `.repl`"** just works. The Monitor can
also ad-hoc compile a loose `.cs` at runtime via `include @file.cs`. Mechanics in
[doc 04 §5](04-repl-to-csharp-bridge.md#5-how-peripheral-cs-files-reach-the-assembly-typemanager-scans).

---

## 9. Authoring checklist

1. `namespace Antmicro.Renode.Peripherals.<Category>;` — drives the `.repl` prefix (§7).
2. Pick a base: subclass `BasicDoubleWordPeripheral` for plain register devices, or implement
   `IDoubleWord/Word/Byte/QuadWordPeripheral` directly; add `IKnownSize` (§1).
3. Constructor `public Foo(IMachine machine, …)` — `machine` is auto-injected; other params
   and `{ get; set; }` properties come from `.repl` (§4).
4. Build registers: an `enum : long` of offsets + a `…RegisterCollection`, using
   `WithValueField`/`WithFlag`/`WithEnumField`/`WithReservedBits`/`WithTaggedFlag` and the
   `valueProviderCallback`/`writeCallback`/`changeCallback` hooks (§2).
5. Implement `Read*/Write*` as `RegistersCollection.Read/Write(offset)`, and `Reset()` as
   `RegistersCollection.Reset()` (call `base.Reset()` first if subclassing) (§5).
6. Interrupts: `public GPIO IRQ { get; } = new GPIO();` (optionally `[DefaultInterrupt]`),
   driven from one `UpdateInterrupts()` via `IRQ.Set(bool)`; expose
   `INumberedGPIOOutput.Connections` for banks; implement `OnGPIO` to receive lines (§3).
7. Log with `this.Log(LogLevel.…, …)`; unmodeled accesses log automatically (§5).

### Key files
- Interfaces: `…/Main/Peripherals/IPeripheral.cs`, `…/Peripherals/Bus/IDoubleWordPeripheral.cs` (+ Word/Byte/QuadWord), `…/Peripherals/IKnownSize.cs`, `…/Core/IGPIO.cs`, `…/Core/IGPIOReceiver.cs`, `…/Core/INumberedGPIOOutput.cs`, `…/Core/ILocalGPIOReceiver.cs`, `…/Core/Structure/IPeripheralContainer.cs`.
- Registers: `…/Core/Structure/Registers/RegisterCollection.cs`, `PeripheralRegister.cs`, `PeripheralRegisterExtensions.cs`, `FieldMode.cs`; bases `…/Main/Peripherals/BasicDoubleWordPeripheral.cs` (+ Word/Byte).
- GPIO/attrs: `…/Core/GPIO.cs`, `…/Core/GPIOAttribute.cs`, `…/Main/Peripherals/DefaultInterruptAttribute.cs`, `…/Main/Peripherals/NameAliasAttribute.cs`, `…/Main/Peripherals/GPIOPort/BaseGPIOPort.cs`.
- Logging: `…/Main/Logging/Logger.cs`, `LogLevel.cs`.
- Worked examples: `…/Peripherals/Timers/RiscVMachineTimer.cs`, `…/Peripherals/GPIOPort/Murax_GPIO.cs`, `…/Peripherals/Miscellaneous/MAX32650_PWRSEQ.cs`, `…/Peripherals/IRQControllers/STM32H7_EXTI.cs`, `…/Peripherals/UART/MiV_CoreUART.cs`.

---

Next: [`04-repl-to-csharp-bridge.md`](04-repl-to-csharp-bridge.md) — how a `.repl` type name
becomes one of these live, registered C# objects.
