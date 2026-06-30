# 05 - Cheatsheet & Recipes

Copy-pasteable patterns. Each links to the full explanation. Synthetic snippets are labeled;
others are adapted from real `renode`/`renode-infrastructure` files.

---

## Quick value-syntax table (`.repl`)

| You want | Write |
|---|---|
| Hex / decimal number | `0x40011000` / `200000000` / `480_000_000` |
| String | `cpuType: "cortex-m7"` |
| Multi-line string | `script: '''line1`<br>`line2'''` |
| Boolean | `wideRegisters: true` |
| Enum (full / shorthand) | `mode: PrivilegedArchitecture.Priv1_10` / `mode: .Priv1_10` |
| Address range (start,end) | `<0x0, 0x1000>` |
| Address range (start,+len) | `<0x58022800, +0x400>` |
| Reference to another peripheral | `nvic: nvic` (RHS is a variable name) |
| List / nested list | `invertedAFPins: [[0, 1], [1, 3]]` |
| Inline object | `new Bus.BusMultiRegistration { address: 0x...; size: 0x... }` |
| Unset / default | `foo: none` / `foo: empty` |

Full grammar: [doc 01 §6](01-repl-format.md#6-attributes--constructor-args-and-properties).

---

## Registration forms (`.repl`)

```repl
peri: Cat.Type @ sysbus 0x40011000          # single address (needs IKnownSize)  -> BusPointRegistration
peri: Cat.Type @ sysbus <0x40000000, +0x1000> # explicit range                  -> BusRangeRegistration
cpu:  CPU.CortexM @ sysbus                   # no address                        -> NullRegistrationPoint
led:  Miscellaneous.LED @ gpioPortD          # attach to another peripheral
slave: Sensors.Foo @ i2c 0x20                # numeric slot on a parent          -> NumberRegistrationPoint
multi: SPI.X @ {                             # several points at once
    sysbus 0x402A8000;
    sysbus new Bus.BusMultiRegistration { address: 0x60000000; size: 0xF000000; region: "ciphertext" }
}
combiner: Miscellaneous.CombinedInput @ none # created but not bus-mapped
peri: Cat.Type @ sysbus 0x... as "myname"    # register under a custom name
```

Mapping details: [doc 04 §2](04-repl-to-csharp-bridge.md#2-the-registration-model).

---

## IRQ wiring (`.repl`)

```repl
-> cpu@0                    # default GPIO output -> input 0 of cpu
IRQ -> nvic@27              # named GPIO property 'IRQ' -> input 27 of nvic
0 -> exti@5                 # numbered output line 0 -> input 5
[0-15] -> nvic@[0-15]       # range -> range (arity must match)
[16-19] -> nvic@[1, 41, 2, 3]   # range -> explicit list
IRQ -> nvic@27 | dma@2 | dma@4  # fan-out (multiplex) with '|'
[0-7] -> syscfg#10@[0-7]    # destination local receiver via #localIndex
-> none                    # leave the source unconnected
```

`@n` on the **destination** = input pin index, not an address. Fan-in (several sources → one
input) auto-inserts a `CombinedInput`.
Full rules: [doc 01 §7](01-repl-format.md#7-interrupt-irq-wiring--the---clause).

---

## Recipe: add a peripheral to an existing board

```repl
# my_board.repl  (synthetic)
using "platforms/cpus/stm32f4.repl"          # inherit a CPU + its peripherals

# new memory-mapped device:
myuart: UART.STM32F7_USART @ sysbus 0x40011000
    frequency: 8000000
    IRQ -> nvic@53

# extend an inherited peripheral (no type => amend, don't redeclare):
gpioPortD:
    12 -> myLed@0

myLed: Miscellaneous.LED @ gpioPortD
```

Merge/extend model: [doc 01 §9](01-repl-format.md#9-the-merge--extend-model).

---

## Recipe: a minimal `.resc`

```
:name: My Board
:description: Run firmware on my board
$name?="MyBoard"
mach create $name
machine LoadPlatformDescription @platforms/boards/my_board.repl
$bin?=@/path/to/firmware.elf
showAnalyzer sysbus.myuart
macro reset
"""
    sysbus LoadELF $bin
"""
runMacro $reset
# then: `start` (or run with  renode my.resc -e start)
```

Command reference: [doc 02 §6](02-resc-monitor.md#6-command-reference-the-ones-youll-actually-see-in-resc).

---

## Recipe: inline `.repl` from a `.resc`

```
machine LoadPlatformDescriptionFromString """
using "platforms/boards/nucleo_h753zi.repl"
nvic:
    priorityMask: 0xFF
"""
```

---

## Recipe: a new C# peripheral (skeleton)

```csharp
// renode-infrastructure/src/Emulator/Peripherals/Peripherals/Miscellaneous/MyDevice.cs  (synthetic)
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure.Registers;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Miscellaneous   // -> .repl prefix "Miscellaneous"
{
    public class MyDevice : BasicDoubleWordPeripheral, IKnownSize
    {
        public MyDevice(IMachine machine, uint resetValue = 0) : base(machine)  // machine auto-injected; resetValue from .repl
        {
            DefineRegisters();
        }

        public long Size => 0x100;                     // map with @ sysbus 0xADDR
        public GPIO IRQ { get; } = new GPIO();         // interrupt output

        public override void Reset()
        {
            base.Reset();                              // resets register collection
            UpdateInterrupts();
        }

        private void DefineRegisters()
        {
            Registers.Control.Define(this)
                .WithFlag(0, out enable, name: "ENABLE",
                    writeCallback: (_, __) => UpdateInterrupts())
                .WithReservedBits(1, 31);
            Registers.Status.Define(this)
                .WithFlag(0, FieldMode.Read, valueProviderCallback: _ => pending, name: "PENDING")
                .WithReservedBits(1, 31);
        }

        private void UpdateInterrupts() => IRQ.Set(enable.Value && pending);

        private IFlagRegisterField enable;
        private bool pending;
        private enum Registers : long { Control = 0x00, Status = 0x04 }
    }
}
```

Reference it from `.repl`:
```repl
mydev: Miscellaneous.MyDevice @ sysbus 0x50000000
    resetValue: 0x1
    IRQ -> nvic@42
```

Authoring detail: [doc 03](03-csharp-peripherals.md). Why a new `.cs` "just works" after a
rebuild: [doc 04 §5](04-repl-to-csharp-bridge.md#5-how-peripheral-cs-files-reach-the-assembly-typemanager-scans).

---

## Recipe: compose a board from a CPU file

```repl
# board.repl
using "platforms/cpus/<soc>.repl"   # the SoC: CPU, NVIC, memories, on-chip peripherals
# add board-level parts (buttons, LEDs, external flash, sensors), and amend inherited
# peripherals (no type) to wire board IRQs/GPIOs.
```

Real example: `platforms/boards/stm32f4_discovery.repl`
([doc 01 §3](01-repl-format.md#3-using--including-other-repl-files)).

> Bringing up a chip Renode doesn't support yet (writing the CPU `.repl` itself, not just a
> board on top of it)? That's the full playbook in
> [doc 06](06-generating-a-new-board.md) - where each line comes from (SVD vs datasheet) and how
> to verify it by loading it in Renode.

---

## "Where do I look?" map

| Question | Doc |
|---|---|
| Exact `.repl` syntax / a parse error | [01](01-repl-format.md) |
| What a Monitor/`.resc` command does | [02](02-resc-monitor.md) |
| How to write/extend a C# peripheral | [03](03-csharp-peripherals.md) |
| Why my `.repl` won't resolve a type / pick a ctor / register | [04](04-repl-to-csharp-bridge.md) |
| `@ sysbus 0x…` vs `<a,+s>` vs bare | [04 §2](04-repl-to-csharp-bridge.md#2-the-registration-model) |
| `IMachine` injection / `sysbus` available without declaring | [04 §3,§6](04-repl-to-csharp-bridge.md) |
| **Generate a `.repl` for an unsupported board/CPU** | [**06**](06-generating-a-new-board.md) |
| Which facts come from the SVD vs the datasheet | [06 §2](06-generating-a-new-board.md#2-provenance-table-verified-against-stm32f103) |
| Verify a generated `.repl` (load + boot loop) | [06 §6](06-generating-a-new-board.md#6-verifying-a-generated-repl-the-closed-loop) |

---

## Top gotchas (consolidated)

- `.repl` indentation is **exactly 4 spaces**; tabs don't count.
- `.repl` `//` comments must be at line start or preceded by a space (so `http://` is safe).
- `@` means **bus address** in a registration but **input index** in an IRQ - don't conflate.
- `@ sysbus 0xADDR` needs the peripheral to be `IKnownSize`; otherwise use `<addr, +size>`.
- A property is `.repl`-settable only with a **public setter** (`{ get; set; }`).
- `.resc`/Monitor: `reset` is a **macro** (`macro reset """…"""` + `runMacro $reset`), not a command.
- `.resc` numbers print/parse in **hex** by default (`numbersMode` toggles).
- `$x ?= value` sets only if undefined - the override hook for `-e '$x=...'`.
- `.repl` `using` = include a file; Monitor `using` = add a name prefix. Unrelated.
