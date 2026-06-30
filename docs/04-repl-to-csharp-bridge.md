# 04 - The `.repl` → C# Bridge (Runtime Plumbing)

> How a line like `uart0: UART.STM32F7_USART @ sysbus 0x40011000` becomes a live, registered
> C# object. This is the machinery between [doc 01 (`.repl`)](01-repl-format.md) and
> [doc 03 (C# peripherals)](03-csharp-peripherals.md).

**Two trees:**
- `renode` - the platform-description **driver** (`src/Renode/PlatformDescription/`).
- `renode-infrastructure` - core types (`Machine`, `SystemBus`, registration points,
  `TypeManager`) under `src/Emulator/Main/`, plus all peripherals. Mounted into the main
  build at `src/Infrastructure/` (`Renode.sln:16`).

Paths are within the `renode` tree unless prefixed otherwise; infrastructure paths are
explicitly marked.

> **Correction to common lore:** the registration contract is
> `IRegisterablePeripheral<TPeripheral, TRegistrationPoint>`, **not** `IPeripheralRegister<,>`.
> (`IPeripheralRegister<T>` in `Registers/PeripheralRegister.cs` is an unrelated *hardware*
> register abstraction.)

---

## 0. The entry point: `LoadPlatformDescription` → `CreationDriver`

`machine LoadPlatformDescription @x.repl` is an extension method on `Machine`
(`src/Renode/PlatformDescription/UserInterface/PlatformDescriptionMachineExtensions.cs`):
```csharp
public static void LoadPlatformDescription(this Machine machine, string file)
    => PrepareDriver(machine).ProcessFile(file);                      // :18-21
public static void LoadPlatformDescriptionFromString(this Machine machine, string s)
    => PrepareDriver(machine).ProcessDescription(s);                  // :23-26
```
`PrepareDriver` (`:28-35`) grabs the active `Monitor`, builds a `UsingResolver` (for `.repl`
`using` paths) and a `MonitorScriptHandler` (for `init`/`reset`/`preinit` sections), and
constructs `new CreationDriver(machine, usingResolver, monitorScriptHandler)`. The driver ctor
calls `PrepareVariables()` (§3).

The whole pipeline runs in `CreationDriver.ProcessInner` (`CreationDriver.cs:191-333`). The
phase list from [doc 00](00-overview.md#the-instantiation-pipeline-phase-list) maps directly
onto it; the sections below detail each piece.

---

## 1. TypeManager - type resolution & assembly scanning

**File:** `renode-infrastructure/src/Emulator/Main/Utilities/TypeManager.cs`
(`Antmicro.Renode.Utilities.TypeManager`).

### How a `.repl` type name resolves
`CreationDriver.ResolveTypeOrThrow` (`CreationDriver.cs:1913-1924`):
```csharp
var extendedTypeName = typeName.StartsWith(DefaultNamespace, ...) ? typeName : DefaultNamespace + typeName;
var result = TypeManager.Instance.TryGetTypeByName(typeName)        // verbatim
          ?? TypeManager.Instance.TryGetTypeByName(extendedTypeName); // with default ns
```
`DefaultNamespace = "Antmicro.Renode.Peripherals."` (`:1979`). So `UART.STM32F7_USART` tries
itself, then `Antmicro.Renode.Peripherals.UART.STM32F7_USART`. Fully-qualified names (test
mocks, types outside that namespace) resolve on the first try.

### Startup scan (directory glob, not a manifest)
`TypeManager` is a process-wide singleton built in its static constructor
(`TypeManager.cs:27-48`). In the normal dev build it computes the directory of the executing
assembly (the build output holding `Infrastructure.dll`, `Renode.dll`, …) and calls
`Scan(assemblyLocation)` (`:45-47`). `Scan` enumerates `*.dll`/`*.exe`, skips a blacklist of
system/GUI libs (`:270-326`), and `AnalyzeAssembly`s the rest (`:690-709`).

### Indexing (Mono.Cecil, metadata only)
`AnalyzeAssembly` (`:441-581`) reads each assembly's metadata **without loading it into the
CLR** (Cecil). For each type it records: peripherals (`: IPeripheral`), `[Plugin]`s,
`IAutoLoadType`s (eagerly loaded - this is how Monitor commands self-register), and
"interesting" types (namespace under `Antmicro.Renode`) indexed by full name into
`assemblyFromTypeName`. It also records, for each abstract base, its concrete subclasses
(backing `GetConcreteSubclasses`).

### `TryGetTypeByName` (`:124-157`) and lazy load
Looks up the name in `assemblyFromTypeName`; if exactly one assembly provides it, calls
`GetTypeWithLazyLoad` (`:669-682`) which does `Type.GetType` or, failing that,
`Assembly.LoadFrom(path)` + `assembly.GetType(name)`. **This is the lazy CLR load** that turns
a Cecil-indexed name into a real `System.Type` only when a `.repl` first needs it. Ambiguous
names (multiple assemblies) require a resolver callback.

### `GetConcreteSubclasses(Type)` (`:181-188`)
Used when a `.repl` names an **abstract** type - the driver lists concrete subclasses in the
error so you can pick one (`FindConstructor`, `CreationDriver.cs:1668-1673`).

---

## 2. The registration model

### The contract
**File:** `renode-infrastructure/src/Emulator/Main/Core/Structure/IRegisterablePeripheral.cs`:
```csharp
public interface IRegisterablePeripheral<TPeripheral, TRegistrationPoint> : …
    where TPeripheral : IPeripheral where TRegistrationPoint : IRegistrationPoint
{
    void Register(TPeripheral peripheral, TRegistrationPoint registrationPoint);
    void Unregister(TPeripheral peripheral);
}
```
A *parent* (the `sysbus`, a GPIO port, an I2C controller…) implements one or more of these,
one per `(childType, registrationPointType)` pair it accepts. `IRegistrationPoint` is just
`{ string PrettyString { get; } }` (`IRegistrationPoint.cs`).

### Registration-point types (these drive the `@ …` syntax)
All in `renode-infrastructure/src/Emulator/Main/`:

| Type | Ctor(s) (relevant) | Used by `.repl` form |
|---|---|---|
| `Core/Structure/NullRegistrationPoint.cs` | **private**; singleton `Instance` | `@ sysbus` (bare) |
| `Core/Structure/NumberRegistrationPoint.cs` | `NumberRegistrationPoint<T>(T address)` | `@ parent 5` (numeric, non-bus parent) |
| `Peripherals/Bus/BusPointRegistration.cs` | `BusPointRegistration(ulong address, ulong offset=0, IPeripheral cpu=null, …)` (`:17`) | `@ sysbus 0x40000000` |
| `Peripherals/Bus/BusRangeRegistration.cs` | `BusRangeRegistration(Range range, ulong offset=0, …)` (`:19`); `BusRangeRegistration(ulong address, ulong size, ulong offset=0, …)` (`:27`) | `@ sysbus <0xADDR, +0xSIZE>` |

### What `sysbus` accepts
`renode-infrastructure/src/Emulator/Main/Peripherals/Bus/IBusController.cs:25-27`:
```csharp
public interface IBusController :
    IPeripheralContainer<IBusPeripheral, BusRangeRegistration>,       // -> BusRangeRegistration
    IRegisterablePeripheral<IKnownSize, BusPointRegistration>,        // -> BusPointRegistration
    IRegisterablePeripheral<ICPU, CPURegistrationPoint>,             // -> CPURegistrationPoint
    IRegisterablePeripheral<IPeripheral, NullRegistrationPoint>,      // -> NullRegistrationPoint
    IRegisterablePeripheral<IBusPeripheral, BusMultiRegistration>, …
```
The candidate registration-point types for a given peripheral are the **second generic
arguments** of those interfaces whose **first** argument is assignable from the peripheral's
type. `SystemBus.Register(IKnownSize, BusPointRegistration)` forwards to the range overload via
`registrationPoint.ToRangeRegistration(peripheral.Size)` - which is **why a point registration
requires `IKnownSize`** (`SystemBus.cs:1214-1217`).

### How the driver picks the ctor - `FindUsableRegistrationPoints`
`CreationDriver.cs:829-874`. For each candidate registration-point type, enumerate its ctors:
- **value present** (e.g. `0x40000000` or `<a,+s>`): keep ctors where the **first** parameter
  is the value and any later parameters are optional (`parameters.Length == 1 ||
  parameters[1].HasDefaultValue`, `:846-855`), then try to convert the value to the first
  param's type. Literally *"find a ctor whose first param the value converts to."*
- **value null** (`@ sysbus` bare): keep ctors with **no required params** (`:838`).

### The `@ sysbus …` → registration-point mapping (verified end-to-end)

| `.repl` | AST value | Matched ctor | Resulting point |
|---|---|---|---|
| `@ sysbus 0x40000000` | `ulong` | `BusPointRegistration(ulong address, ulong offset=0, …)`. The `BusRangeRegistration(ulong,ulong size,…)` ctor is **rejected** because its 2nd param `size` is required. | **`BusPointRegistration`** → converted to a range using `peripheral.Size` at register time (needs `IKnownSize`). |
| `@ sysbus <0xADDR, +0xSIZE>` | `Range` (from `RangeValue`) | `BusRangeRegistration(Range range, ulong offset=0, …)` | **`BusRangeRegistration`** |
| `@ sysbus` (bare) | `null` | no Bus* ctor has all-optional params → 0 found → fallback selects `NullRegistrationPoint` (in candidates via `IRegisterablePeripheral<IPeripheral, NullRegistrationPoint>`) (`:648-651`) | **`NullRegistrationPoint.Instance`** |
| `@ someParent 5` | `int`/`ulong` | `NumberRegistrationPoint<T>(T address)` | **`NumberRegistrationPoint<T>`** |

The selection/validation wrapper is `ProcessEntryPostMerge` (`CreationDriver.cs:599-689`): it
computes the register's usable `IRegisterablePeripheral<,>` interfaces, derives the candidate
point types, runs `FindUsableRegistrationPoints`, errors on 0 or >1 matches, picks the
most-derived point + registree, and pins
`registrationInfo.RegistrationInterface = IRegisterablePeripheral<registree, pointType>`
(`:688`).

### Performing the registration - `TryRegisterFromEntry` (`:1035-1166`)
Builds the registration-point object (slot 0 = converted value; remaining slots filled by
`FillDefaultParameter`, which can inject `IMachine`), then the actual call:
```csharp
registrationInfo.RegistrationInterface.GetMethod("Register")
    .Invoke(register, new[] { entry.Variable.Value, registrationPoint });   // :1129
```
i.e. reflective `sysbus.Register(peripheral, point)`. Finally `machine.SetLocalName(...)` names
it (alias or variable name). Registration is **retried** until all parents are registered
(handles ordering, `:278-296`).

---

## 3. Why `sysbus` is a usable variable without being declared

`SystemBus` is created and named by **`Machine`'s constructor**, not by any `.repl`
(`renode-infrastructure/src/Emulator/Main/Core/Machine.cs`):
```csharp
SystemBus = new SystemBus(this);          // :54
SetLocalName(SystemBus, SystemBusName);   // :61   ("sysbus", :1430)
```
The driver seeds its variable table from the live machine in `PrepareVariables`
(`CreationDriver.cs:354-363`): it adds `machine` (`Machine.MachineKeyword == "machine"`) and
**every already-named peripheral** (`machine.GetRegisteredPeripherals()`). Because `sysbus` was
already named in the `Machine` ctor, it shows up here - that's why `@ sysbus` resolves though
`sysbus` is never declared. The same mechanism makes a previously-created `cpu` (or any earlier
peripheral) referenceable in a later `.repl`. There is **no special-casing of `cpu`**; it's
just whatever peripheral was named `cpu`.

---

## 4. Constructor selection for the peripheral itself

`FindConstructor` (`CreationDriver.cs:1666-1823`) is the symmetric logic for the peripheral's
own constructor (the registration-point logic above is for its *attach point*):

- Each `.repl` `name: value` attribute that is **not** a property is a candidate constructor
  argument. A ctor parameter is matched **by name** (or `[NameAlias]`,
  `ParameterNameMatches`/`NameOrAliasMatches`, `:1836-1864`).
- A matched value is converted to the parameter type (`TryConvertSimpleValue`, references and
  inline objects handled specially). An `IMachine` parameter is auto-filled and **cannot** be
  user-supplied (`:1732-1736`).
- A parameter with no matching attribute is filled with its C# default (or an injected
  `IMachine`). A ctor is **accepted** only if it consumes *all* provided attributes with no
  leftovers (`unusedAttributes.Count == 0`, `:1785-1789`).
- Exactly one acceptable ctor → use it; zero → `NoCtor` error; more than one → `AmbiguousCtor`.
  On failure the driver prints a detailed **"constructor selection report"** showing why each
  ctor was rejected (`:1806-1819`) - read it; it usually pinpoints a misnamed attribute or
  wrong value type.

Object creation: `CreateAndHandleError` invokes the chosen ctor with
`PrepareConstructorParameters` (`:735-812`). Properties are applied afterwards via their public
setter (`SetPropertiesAndConnectInterrupts`, `:876-900`).

---

## 5. How peripheral `.cs` files reach the assembly TypeManager scans

**File:** `renode-infrastructure/src/Infrastructure.csproj` - an SDK-style project
(`<Project Sdk="Microsoft.NET.Sdk">`). The .NET SDK **implicitly compiles every `**/*.cs`**
under the project directory; there are **no explicit `<Compile Include>` items**, only a few
**removals** (`:60-65`, e.g. `Plugins/**`, test dirs). Because the project root is
`renode-infrastructure/src/`, every peripheral under `Emulator/Peripherals/**` is globbed into
`Infrastructure.dll` automatically.

**This is exactly why "drop a `.cs` in the right folder and rebuild" works** - no manifest edit;
the file is compiled into `Infrastructure.dll`, which `TypeManager` then scans from the build
output (§1). The project is pulled into the main build via `Renode.sln:16`.

**Runtime addition (no rebuild):** the Monitor can ad-hoc compile a loose `.cs`
(`include @file.cs`) - `AdHocCompiler.Compile` → `Assembly.LoadFrom` →
`TypeManager.Instance.ScanFile(...)` (`renode-infrastructure/.../UserInterface/Monitor.cs:436-446`),
indexing that single assembly into the same dictionaries so a fresh peripheral is resolvable by
`.repl` immediately.

---

## 6. `IMachine`/`Machine` auto-injection

`Machine : IMachine` (`renode-infrastructure/src/Emulator/Main/Core/Machine.cs:40`;
`IMachine` at `…/Peripherals/IMachine.cs`). The driver fills any `IMachine`-typed parameter
with the current machine - `TryGetValueOfOurDefaultParameter` (`CreationDriver.cs:1825-1834`):
```csharp
if(typeof(IMachine).IsAssignableFrom(type)) { value = machine; return true; }
```
Used during ctor selection (`:1717-1730`), at instantiation (`FillDefaultParameter`, `:814-827`),
and for registration-point ctors (`:1067`). The user is **forbidden** from supplying an
`IMachine` argument from `.repl` (`:1732-1736`). Net effect: `public NVIC(IMachine machine, …)`
gets the owning machine automatically; the `.repl` supplies only the *other* arguments.

---

## 7. The full lifecycle, in order (`ProcessInner`)

`CreationDriver.cs:191-333`, annotated with where each concern is covered:

1. **Build the `using` graph & parse** each file: `PreLexer` → Sprache `Grammar` → syntax tree
   (`ParseDescription`, `:335-352`). ([doc 01](01-repl-format.md))
2. **Collect variable declarations** and **merge entries** by name across the graph
   (`ProcessVariableDeclarations`/`CollectVariableEntries`, `:109-174`; merge model in
   [doc 01 §9](01-repl-format.md#9-the-merge--extend-model)).
3. **Run `preinit:` sections** (raw Monitor commands; may even compile a needed type)
   (`:205-219`).
4. **Resolve types** for every entry and inline object (`ResolveTypeOrThrow`, §1) (`:221-235`).
5. **`ProcessEntryPostMerge`** for every entry: **find the peripheral constructor** (§4),
   **validate IRQ/connection** attributes, and **resolve registration points** (§2)
   (`:237-242`, `:555-691`).
6. **Topologically sort for creation** (an entry that references another must be created after
   it) (`SortEntriesForCreation`, `:365-369`).
7. **Create** each object via its ctor (`CreateFromEntry`, `:708-716`); `IMachine` injected (§6).
8. Pre-compute IRQ **fan-in combiners**: any destination input targeted by >1 source gets a
   `CombinedInput` (`:245-270`).
9. **Set properties and connect interrupts** (`SetPropertiesAndConnectInterrupts`, `:876-982`):
   property setters invoked; GPIO sources `.Connect(receiver, index)`; local receivers resolved
   via `ILocalGPIOReceiver`; combiners inserted where needed.
10. **Topologically sort for registration** and **register** each entry on its parent
    (`TryRegisterFromEntry`, §2), with retry until all parents are registered (`:278-296`),
    then set names.
11. **Run `init:` sections** (Monitor commands prefixed with the peripheral name) and **arm
    `reset:` macros** (`:304-318`; bridge in `MonitorScriptHandler`, [doc 01 §8](01-repl-format.md#8-monitor-sections-inside-repl-preinit-init-reset)).
12. `machine.PostCreationActions()` (`:332`).

If anything fails, `HandleError` disposes any objects created so far and throws a
`ParsingException` with file/line and a caret pointing at the offending token
(`:1882-1911`) - so a bad `.repl` doesn't leave a half-built machine.

---

## 8. End-to-end trace of one line

`uart0: UART.STM32F7_USART @ sysbus 0x40011000` with `frequency: 200000000` and `IRQ -> nvic@27`:

1. **Parse** → an `Entry`: variable `uart0`, type `UART.STM32F7_USART`, registration
   `@ sysbus 0x40011000`, attributes `frequency: 200000000` and an IRQ `IRQ -> nvic@27`.
2. **Resolve type** → `TypeManager.TryGetTypeByName("Antmicro.Renode.Peripherals.UART.STM32F7_USART")`
   → lazily loads the `System.Type` (§1).
3. **Find ctor** → a ctor `(IMachine machine, …, uint frequency, …)`; `frequency` bound by name,
   `machine` injected; others defaulted (§4, §6).
4. **Resolve registration point** → value `0x40011000` (ulong) matches
   `BusPointRegistration(ulong address, …)`; the type must be `IKnownSize` (§2).
5. **Create** → `new STM32F7_USART(machine, …, 200000000, …)` (§7.7).
6. **Connect IRQ** → the `GPIO IRQ` property → input `27` of the `nvic` object
   (`source.Connect(nvicReceiver, 27)`) (§7.9).
7. **Register** → `sysbus.Register(uart0, new BusPointRegistration(0x40011000))`, converted to a
   range via the peripheral's `Size`; name set to `uart0` (§2, §7.10).

The peripheral is now mapped at `0x40011000`, interrupts wired to the NVIC, and reachable in the
Monitor as `sysbus.uart0` (or `uart0` with the default `sysbus.` prefix).

---

## 9. File index

- Driver: `src/Renode/PlatformDescription/CreationDriver.cs` - type resolve `:1913-1924`
  (`DefaultNamespace` `:1979`); reg-point selection `:599-689`, `:829-874`; ctor selection
  `:1666-1823`; create `:708-764`; props/IRQ `:876-982`; register `:1035-1166`;
  `PrepareVariables` `:354-363`; `IMachine` inject `:1825-1834`; lifecycle `:191-333`.
- Entry point: `src/Renode/PlatformDescription/UserInterface/PlatformDescriptionMachineExtensions.cs`.
- Monitor bridge for sections: `src/Renode/PlatformDescription/UserInterface/MonitorScriptHandler.cs`.
- TypeManager: `renode-infrastructure/src/Emulator/Main/Utilities/TypeManager.cs`.
- Machine / IMachine / SystemBus: `renode-infrastructure/src/Emulator/Main/Core/Machine.cs`,
  `…/Peripherals/IMachine.cs`, `…/Peripherals/Bus/SystemBus.cs`, `…/Peripherals/Bus/IBusController.cs`.
- Registration types: `…/Core/Structure/IRegisterablePeripheral.cs`, `IRegistrationPoint.cs`,
  `NullRegistrationPoint.cs`, `NumberRegistrationPoint.cs`,
  `…/Peripherals/Bus/BusPointRegistration.cs`, `BusRangeRegistration.cs`.
- Build globbing: `renode-infrastructure/src/Infrastructure.csproj:1,5,60-65`; `renode/Renode.sln:16`.

---

Next: [`05-cheatsheet.md`](05-cheatsheet.md) - copy-pasteable recipes.
