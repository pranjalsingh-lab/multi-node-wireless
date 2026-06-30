# 06 - Generating a `.repl` for an Unsupported Board / CPU

> A playbook for producing a working `.repl` for a chip Renode doesn't ship yet, from
> primary sources (SVD + reference manual + datasheet), plus a closed-loop way to verify it
> by running it in Renode and feeding the results back. Assumes you've read
> [01 (`.repl`)](01-repl-format.md), [03 (C# peripherals)](03-csharp-peripherals.md), and
> [04 (the bridge)](04-repl-to-csharp-bridge.md).

This doc is **grounded in a real end-to-end verification**: I reverse-mapped the in-repo
`platforms/cpus/stm32f103.repl` against the actual `STM32F103.svd` and confirmed exactly which
lines come from the SVD and which require the reference manual / datasheet. The evidence is in
§2 and §8. It was then **cross-checked a second time, cross-vendor**, against the live Nordic
`NRF52840.svd`: 27/27 NVIC interrupt numbers and 28/30 peripheral bases match exactly - and the
2 that don't exposed a real gap in the naive base rule (the GPIO **register-block offset**),
written up in **§2.1**. (Honesty note: `dotnet`/Renode are not installed in the authoring
environment, so the *execution* loop in §6 is documented with exact commands but was not run
here; the *data-provenance* methodology in §2 **was** verified against both real SVDs over the
network.)

---

## 1. The core idea: every `.repl` line has a provenance

A `.repl` is a fusion of three kinds of facts. Generation = collect each kind from the right
source, then assemble. **You cannot produce a working `.repl` from the SVD alone** - roughly
half the content (interrupt grouping, DMA routing, pin alternate functions, clock frequency,
memory regions, and *which model to instantiate*) is **not** in the SVD.

The left-hand box below is drawn as "SVD" because that's the worked STM32 example, but the SVD is
just the **Cortex-M instance of a generic machine-readable hardware description**. For silicon
without an SVD (most niche parts - see [§3.1](#31-when-theres-no-svd--alternative-primary-sources))
the *same* deterministic facts come from a device tree, a BSP/SDK header, the SoC generator's
output, a SystemRDL model, or the HDL itself. Read every "SVD" below as "the machine-readable
source you actually have."

```
   Machine-readable HW description*          Reference Manual / Datasheet (human docs)
   ┌──────────────────────────────┐     ┌──────────────────────────────────────────────┐
   │ peripheral base addresses     │     │ memory-region map (flash/SRAM/external banks) │
   │ peripheral register sizes     │     │ EXTI→NVIC line grouping (CombinedInput sizes) │
   │ NVIC interrupt numbers         │     │ DMA request routing (which req → which chan)  │
   │ NVIC priority bits (cpu)       │     │ GPIO alternate-function tables (AF mesh)      │
   │ register reset values          │     │ silicon AF quirks (invertedAFPins)            │
   └──────────────────────────────┘     │ system/SysTick clock frequency (clock tree)   │
                  │                       │ which IP block each peripheral actually is    │
                  ▼                       └──────────────────────────────────────────────┘
         ┌─────────────────────────────────────────────────────────────┐
         │  Human/LLM judgment: map each peripheral to an existing       │
         │  Renode C# model (Category.Class) - or write a new one (03).  │
         └─────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                                board.repl  ──►  verify in Renode (§6)  ──►  iterate
```

> \* **Machine-readable HW description** = SVD for Cortex-M; otherwise a device tree (`.dts`),
> a BSP/SDK C header, the SoC generator's output (LiteX/OpenTitan), a SystemRDL model, or the
> RTL - [§3.1](#31-when-theres-no-svd--alternative-primary-sources). It supplies the same
> deterministic facts (bases, sizes, IRQ numbers, reset values) whatever its form.

---

## 2. Provenance table (verified against STM32F103)

This is the heart of the method. For each `.repl` construct, where the fact comes from, and
the **verification result** from cross-checking `stm32f103.repl` against `STM32F103.svd`. Where
the Source column says **SVD**, read it as "the machine-readable description you have" - for
non-Cortex-M / SVD-less parts the identical facts come from a device tree, BSP header, SoC
generator, SystemRDL, or HDL ([§3.1](#31-when-theres-no-svd--alternative-primary-sources)).

| `.repl` construct | Example (F103) | Source | Verified? |
|---|---|---|---|
| Peripheral **base address** | `usart1: … @ sysbus <0x40013800, +0x100>` | **SVD** `<peripheral><baseAddress>` - but ⚠️ the *registration* base is SVD base **+ the model's register-block offset** ([§2.1](#21-caveat--the-model-base-can-be-svd-base--register-block-offset)) | ✅ SVD USART1 = `0x40013800`, I2C1 = `0x40005400`, TIM1 = `0x40012C00`, DMA1 = `0x40020000`, EXTI = `0x40010400`, AFIO = `0x40010000`, RCC = `0x40021000` - all match (STM32 register blocks start at offset 0). |
| Peripheral **window size** | `<0x40013800, +0x100>` | **SVD** `<addressBlock><size>` (or known IP size) | ✅ matches IP block sizes. |
| **NVIC interrupt number** | `usart1 -> nvic@37` | **SVD** `<interrupt><value>` | ✅ SVD USART1=37, USART2=38, USART3=39, UART4=52, UART5=53, I2C1_EV=31, I2C1_ER=32, TIM1_BRK=24/UP=25/TRG_COM=26/CC=27, TIM2=28/TIM3=29/TIM4=30 - all match. |
| **NVIC priority bits** | `priorityMask: 0xF0` (top 4 bits) | **SVD** `<cpu><nvicPrioBits>` | ✅ SVD `<nvicPrioBits>4</nvicPrioBits>` → mask `0xF0`. |
| **Register reset value** | `Tag … "RCC_CR" 0x…` baseline | **SVD** `<register><resetValue>` | ✅ SVD RCC_CR resetValue = `0x00000083`. |
| **SysTick / system clock** | `systickFrequency: 72000000` | **Datasheet clock tree** (max SYSCLK) | ✅ **0 occurrences** of `systick`/`72000000` in the SVD - confirmed *not* SVD-derivable. |
| **EXTI→NVIC grouping** + `CombinedInput` size | `[5-9] -> nvicInput23@[0-4]`; `nvicInput23 … numberOfInputs: 5 -> nvic@23` | **Reference manual** vector-table grouping (EXTI5–9 share vector 23; EXTI10–15 share 40). SVD gives the *numbers* (23, 40) but not the *fan-in*. | ✅ SVD has `EXTI9_5=23`, `EXTI15_10=40` (numbers), but the "5 lines → 1 vector" fan-in is RM knowledge. |
| **DMA request routing** | `usart1 … DMARequest -> dma1@4 \| dma1@5`; `timer1 … UpdateInterrupt -> nvic@25 \| dma1@5` | **Reference manual** DMA request-mapping tables | ✅ Not in SVD; pure RM. |
| **GPIO alternate-function mesh** (AF tables) | `timer1: 0 -> gpioPortA#08@01 \| …`; `gpioPortA: 7 -> timer1@00 \| timer3@01 \| timer14@00` | **Datasheet** alternate-function / pin-mapping tables | ✅ Not in SVD; pure datasheet. |
| **Silicon AF quirks** | `gpioPortA: invertedAFPins: [[7, 1]]` | **Datasheet/errata or empirical** (AF polarity) | ✅ Not in SVD. |
| **Memory-region map** | `flash @ 0x00000000 size 0x20000000`; `sram @ 0x20000000`; `fsmcBank1 @ 0x60000000` | **Reference manual** memory map (≠ SVD peripheral base!) | ✅ SVD's `FSMC` *register block* base is `0xA0000000`; the FSMC memory *bank* is `0x60000000` - different facts. |
| **Which C# model to instantiate** | `UART.STM32_UART`, `Timers.STM32_Timer`, `DMA.STM32G0DMA`, `IRQControllers.STM32F4_EXTI`, `GPIOPort.STM32F1GPIOPort` | **Judgment** - match SVD/RM IP to an existing Renode model | ✅ F103 *reuses* `STM32F4_EXTI` and `STM32G0DMA` - cross-family model reuse (see §5). |
| **Model tuning params** | `timerN frequency: 10000000`, `initialLimit: 0xFFFF`, `numberOfChannels: 7`, `numberOfOutputLines: 19` | **Model API** (doc 03) + RM (channel/line counts) | ✅ counts from RM; defaults are modeling choices. |
| **Boot-bring-up Tag overrides** | `Tag <0x40021000,…> "RCC_CR" 0x0A020083` | **Running firmware** (force clock-ready bits) - *not* the cold-reset value | ✅ Cold reset is `0x00000083` (SVD); the Tag forces `0x0A020083` so firmware's clock-init busy-wait completes. |

**Conclusion (the methodology is true):** the SVD deterministically yields base addresses
(*modulo* the §2.1 offset caveat), window sizes, NVIC numbers, priority bits, and register reset
values. Everything else - interrupt fan-in, DMA routing, AF tables, AF inversions, memory
regions, clock frequency, and model selection - comes from the reference manual / datasheet and
engineering judgment. A generator must consume **both**.

---

## 2.1 Caveat - the model base can be *SVD base + register-block offset*

The "base ← SVD `<baseAddress>`" rule is exact **for STM32** because every STM32 peripheral's
register block starts at offset 0 from the SVD base (STM32F4 `GPIOA` SVD base `0x40020000`, first
register `MODER` at `addressOffset 0x00`; corroborated by ST's reference manual). That is **not
universal.** A Renode model is registered where *its* register map starts - which is the SVD base
**plus a fixed offset** whenever the SVD models a larger "peripheral" with a reserved header that
the C# model skips. A generator that copies `<baseAddress>` verbatim will mis-place such a
peripheral.

**Verified cross-vendor example - Nordic nRF52840 (Cortex-M4).** I fetched the exact SVD the
repl's `ApplySVD` points at (`dl.antmicro.com/projects/renode/svd/NRF52840.svd.gz`) and
cross-checked it against `platforms/cpus/nrf52840.repl`:

- **27/27 NVIC interrupt numbers match** the SVD `<interrupt><value>` (`uart0 -> nvic@2`,
  `radio -> nvic@1`, `timer3 -> nvic@26`, `egu0..5 -> nvic@20..25`, `i2s -> nvic@37`, …). The §2
  IRQ rule generalises cleanly to a non-ST vendor.
- **28/30 peripheral bases match** the SVD `<baseAddress>` exactly.
- **The 2 that "don't" are the GPIO ports - and the repl is right, the naive rule is wrong.**
  The repl uses `gpio0 @ 0x50000500` and `gpio1 @ 0x50000800`, but the SVD says `P0 = 0x50000000`
  and `P1 = 0x50000300` (`P1` is `derivedFrom="P0"`). The nRF GPIO port reserves bytes
  `0x000–0x4FF`; its **first real register `OUT` is at SVD offset `+0x504`** (abs `0x50000504`),
  confirmed against Nordic's product spec. The Renode model `NRF52840_GPIO`
  (`GPIOPort/NRF52840_GPIO.cs`: `Size => 0x300`, register enum `Out = 0x4`) maps **only** the
  register block, so it is registered at SVD base **+ 0x500**. Had a generator emitted
  `gpio0 @ 0x50000000` with the model's `0x300` window, the window would cover
  `0x50000000–0x500002FF` and **never reach the real registers at `0x50000504+`** - silently
  breaking every GPIO access.

**Rule, corrected:** the *peripheral* base is the SVD `<baseAddress>`; the **registration** base
is `SVD base + (SVD's first-register offset − model's first-register offset)` - i.e. you *add* the
amount by which the SVD pushes the real registers past the base. For the nRF GPIO that is
`0x50000000 + (0x504 − 0x4) = 0x50000500` (✓ the shipped repl). The robust way to compute it: pick a
register that **both** the SVD and the chosen model name (here `OUT`), then
`registration base = SVD_absolute_addr(reg) − model_offset(reg) = 0x50000504 − 0x4 = 0x50000500`.
Resolve it by reading the model's register enum (doc 03) against the SVD's first non-reserved
`addressOffset`. Most peripherals (and all of STM32) have a 0 offset so the two coincide; the
nRF GPIO ports are the exception that proves you must check. (This matches the §10 formula; do
**not** subtract in the other direction - `model − SVD` would land the port `0x500` *below* the
base at `0x4FFFFB00` and silently break every GPIO access.)

*(Aside - `nvicPrioBits` also generalised: the nRF52840 SVD `<cpu><nvicPrioBits>` is `3` → top-3
bits → `priorityMask: 0xE0`. Note the shipped `nrf52840.repl` actually **omits** `priorityMask`
and relies on the NVIC model default `0xFF` (`Arm-M/NVIC.cs:32`) - a small fidelity gap, not a
break: priorityMask only governs which low priority bits the model honours.)*

---

## 3. Inputs you need before starting

> **Not sure which of these actually exist for your part, or where to get them?**
> [Doc 07 (Source Router)](07-source-router.md) routes a new CPU/architecture to the exact documents
> to fetch (by family: Cortex-M/-A/-R, RISC-V hard & soft, x86, SPARC, PowerPC, MSP430, Xtensa),
> including the in-tree `dts2repl`/`PeakRDL-repl` converters. Use it to *assemble this list*; use the
> rest of doc 06 to turn the fetched facts into a `.repl`.

1. **A machine-readable hardware description** - supplies bases, register sizes, IRQ numbers, and
   reset values (§2's left column). For Cortex-M this is the **SVD** (`*.svd`, often gzipped -
   CMSIS System View Description; vendors like ST/NXP/Nordic publish them, also bundled in CMSIS
   `.pack` = zip → `*.svd`). **If no SVD exists** (most niche parts), substitute the next-best
   machine-readable source - device tree, BSP header, SoC-generator output, SystemRDL, or the
   HDL: see **[§3.1](#31-when-theres-no-svd--alternative-primary-sources)**.
2. **Reference Manual (RM)** - the big PDF: memory map, NVIC vector table (interrupt grouping),
   DMA request maps, EXTI wiring, clock tree. Source for the "RM" rows. (Soft-SoCs may have no RM
   at all - the generator config and HDL stand in; §3.1.)
3. **Datasheet (DS)** - pinout & **alternate-function tables**, max clock speeds. Source for the
   AF mesh, `invertedAFPins`, and `systickFrequency`.
4. **The existing Renode C# peripheral catalog** - to pick `Category.Class` models
   (`renode-infrastructure/src/Emulator/Peripherals/Peripherals/<Category>/`). See §5.
5. **A known-good firmware image** (`.elf`/`.bin`) for the part - ideally a vendor "blinky" or
   a Zephyr/HAL sample - to smoke-test boot (§6.4). For SVD-less soft-SoCs this is doubly
   important: the §6 load→boot→access-log loop is often your *primary* source of truth.
6. *(optional)* the vendor **HAL headers** - `stm32f1xx.h` etc. give base-address `#define`s and
   IRQn enums that corroborate the SVD (and *replace* it when there's no SVD - §3.1).

## 3.1 When there's no SVD - alternative primary sources

A CMSIS-SVD is the **Arm/Cortex-M vendor convention**; the genuinely niche parts lack *that file*
but almost always expose the same facts somewhere else. Empirically (grepping the provenance
comments the Renode authors left in `platforms/cpus/*.repl`), here are the substitutes, best
first - read each as "this fills the SVD column of §2":

1. **The SoC's own generator output** - a soft-SoC has no datasheet because the address map is
   whatever the build *assigned*, so it's emitted by the tool. Often the repl is literally
   auto-generated: `opentitan-earlgrey.repl:1` → `// Auto-generated renode platform config for
   OpenTitan at commit f243e680…`. Renode even ships a converter: **`tools/PeakRDL-repl`** -
   *"Generate Renode REPL platform files from a SystemRDL model"* (SystemRDL is the RTL-flow
   register-description language; a different machine-readable source than SVD). LiteX similarly
   emits a CSR map (`csr.csv`/`.json`).
2. **Device tree (`.dts`/`.dtsi`)** - for Linux/Zephyr-class parts, `reg = <base size>` and
   `interrupts` are exactly what a repl needs. `sifive-fu540.repl:100` →
   `// The registration address value is taken from the device tree. // It is different in the
   documentation (0x10140000).` (they trusted the DTS *over* the datasheet);
   `litex_vexriscv_zephyr.repl:1` is based on Zephyr's `riscv32-litex-vexriscv.dtsi`.
3. **Vendor BSP / SDK C headers** (`#define BASE 0x…`, IRQn enums) - `mimxrt798s.repl:567` →
   `// All peripherals tags come from zephyr's …/MIMXRT798S_cm33_core[01].h`;
   `xtensa-sample-controller.repl:1` → `// instram0, dataram0 and dataram1 are defined in
   'core-isa.h'` (Xtensa cores are configurable, so the toolchain *generates* `core-isa.h`).
4. **Non-SVD vendor register docs (HTML/PDF)** - LEON/GR716 (Gaisler GRLIB manual), MSP430 (TI
   SLAU family guide), Tegra/Zynq all have register references that simply aren't SVDs:
   `zynqmp.repl:246` → `// Based on https://docs.amd.com/r/en-US/ug1087-zynq-ultrascale-registers`.
5. **The HDL / RTL itself** - when nothing else exists, read the address decoder. The model names
   give the source away: `UART.Murax_UART` (SpinalHDL Murax demo SoC), `UART.Potato_UART`
   (microwatt's VHDL UART), `Timers.LiteX_*`, `GPIOPort.Murax_GPIO` - each modeled directly from
   named open-source gateware.
6. **Reference firmware / HAL source + the empirical §6 loop** - read the vendor HAL and *run*
   firmware: `ambiq-apollo4.repl` matches the HAL's `am_hal_delay_us`; `opentitan-earlgrey-cw310.repl:2`
   cites a specific OpenTitan C file. With no docs, the load→boot→watch-the-access-log loop (§6)
   *becomes* the spec.
7. **Reuse an in-tree model + sibling repl** (§5) - the chosen C# model already encodes a register
   layout someone reverse-engineered earlier; new repls copy the structure
   (`// …for more details see stm32l071.repl`).

> **Where to look first**, by part type: *soft-SoC* (LiteX/OpenTitan/Murax/microwatt) → generator
> output / HDL (1, 5) + firmware loop (6); *Linux/Zephyr SoC* (SiFive, Renesas RZ, Zynq) → device
> tree (2) + BSP header (3); *vendor MCU without SVD* (MSP430, LEON/GR716, older Cortex-M) →
> non-SVD manual (4) + HAL header (3). In all cases §2's *right* column (memory map, IRQ grouping,
> DMA/AF meshes) and the model-matching judgment (§5) are unchanged - only the *machine-readable*
> column changes form.

---

## 4. Step-by-step generation procedure

Order matters: declare CPU/NVIC first (others reference them), then memories, then peripherals,
then the wiring meshes.

### Step 0 - Core & NVIC basics (SVD `<cpu>` + DS)
From the SVD `<cpu>` node: `name` (→ `cpuType`, e.g. `cortex-m3`), `nvicPrioBits` (→
`priorityMask`: top *N* bits set, e.g. 4 → `0xF0`), `fpuPresent`, `mpuPresent`. Emit:
```repl
nvic: IRQControllers.NVIC @ sysbus 0xE000E000    // NVIC is always at the Cortex-M PPB address
    priorityMask: 0xF0
    systickFrequency: 72000000                   // from DS clock tree, NOT the SVD
    IRQ -> cpu@0
cpu: CPU.CortexM @ sysbus
    cpuType: "cortex-m3"
    nvic: nvic
```
(The NVIC base `0xE000E000` and `IRQ -> cpu@0` are architectural constants for Cortex-M.)

### Step 1 - Memory map (RM)
From the RM memory-map chapter, not the SVD: flash, SRAM, and any external/special regions.
```repl
flash: Memory.MappedMemory @ sysbus 0x00000000
    size: 0x20000000
sram:  Memory.MappedMemory @ sysbus 0x20000000
    size: 0x10000000
```
(Use `Memory.MappedMemory` for RAM/flash regions, `Memory.ArrayMemory` for small register-like
backing. Sizes are region sizes from the RM, frequently rounded up to the aliased window.)

### Step 2 - Instantiate peripherals (SVD base/size/IRQ + §5 model choice)
For each peripheral in the SVD: pick a model (§5), use its base address and size, and wire its
interrupt(s) to the NVIC by the SVD interrupt number:
```repl
usart1: UART.STM32_UART @ sysbus <0x40013800, +0x100>
    -> nvic@37                                   // SVD interrupt 'USART1' = 37
```
Multi-interrupt peripherals map each SVD interrupt to the model's named GPIO output (the model
decides the property names - see doc 03; e.g. I2C exposes `EventInterrupt`/`ErrorInterrupt`):
```repl
i2c1: I2C.STM32F1_I2C @ sysbus 0x40005400
    EventInterrupt -> nvic@31                     // SVD I2C1_EV
    ErrorInterrupt -> nvic@32                     // SVD I2C1_ER
```

### Step 3 - EXTI → NVIC muxing + `CombinedInput` fan-in (RM)
The RM's EXTI/NVIC chapter says how external lines collapse onto shared vectors. Lines that map
1:1 connect directly; groups that share a vector go through a `Miscellaneous.CombinedInput`
sized to the group:
```repl
exti: IRQControllers.STM32F4_EXTI @ sysbus 0x40010400
    numberOfOutputLines: 19
    [0-4]   -> nvic@[6-10]                         // EXTI0..4 are individual vectors 6..10
    [5-9]   -> nvicInput23@[0-4]                   // EXTI5..9 share vector 23
    [10-15] -> nvicInput40@[0-5]                   // EXTI10..15 share vector 40

nvicInput23: Miscellaneous.CombinedInput @ none
    numberOfInputs: 5
    -> nvic@23
nvicInput40: Miscellaneous.CombinedInput @ none
    numberOfInputs: 6
    -> nvic@40
```
The vector numbers (23, 40) are in the SVD as `EXTI9_5`/`EXTI15_10`; the **fan-in counts**
(5, 6) are RM knowledge. (Recall from [doc 01 §7](01-repl-format.md#7-interrupt-irq-wiring--the---clause):
multiple sources → one input would auto-insert a combiner, but here you want an *explicit*,
*named*, sized combiner.)

### Step 4 - DMA controllers + request routing (SVD base + RM request map)
Instantiate the DMA controller(s) (base + channel→NVIC from SVD), then wire each peripheral's
DMA request to the correct controller channel from the RM's DMA-request table:
```repl
dma1: DMA.STM32G0DMA @ sysbus 0x40020000
    numberOfChannels: 7
    [0-6] -> nvic@[11-17]                          // SVD DMA1_Channel1..7 = 11..17

usart1: …
    DMARequest -> dma1@4 | dma1@5                  // RM: USART1 RX/TX on DMA1 ch5/ch4
```
> ⚠️ **Channel index base**: Renode `@n` uses the model's 0-based connection index. RM tables
> usually number DMA channels from 1. Confirm the model's convention (here channel "5" in the
> RM is index `dma1@5` because the model's `Connections` are keyed to match). Mismatches here are
> the #1 silent bug.

### Step 5 - GPIO ports, AFIO, and the AF mesh (DS alternate-function tables)
Instantiate each GPIO port (SVD base) and the AFIO/pin-mux peripheral; feed the EXTI mux through
AFIO; then encode the alternate-function tables. F103 uses a bidirectional notation where timer
channels drive GPIO pins and GPIO pins feed timer inputs:
```repl
gpioPortA: GPIOPort.STM32F1GPIOPort @ sysbus <0x40010800, +0x400>
    invertedAFPins: [[7, 1]]                       // DS/errata silicon quirk

afio: GPIOPort.STM32F1AFIO @ sysbus 0x40010000
    gpioPorts: [gpioPortA, gpioPortB, …]
    [0-15] -> exti@[0-15]                           // AFIO routes pins to EXTI lines

// AF table: timerChannel -> gpioPort#pin@timer  (see the comment block in the real repl)
timer1:
    0 -> gpioPortA#08@01 | gpioPortE#09@01 | … | dma1@2
gpioPortA:
    7 -> timer1@00 | timer3@01 | timer14@00
```
These connections come straight from the DS "alternate function mapping" tables - there is no
SVD or RM shortcut. This is usually the bulkiest, most error-prone part; generate it from the DS
AF table programmatically if you can.

### Step 6 - Register reset Tags & boot workarounds (SVD resetValue + firmware)
Most reset values are handled by the models or by `ApplySVD` (§6.3). Add explicit `Tag`s only
where firmware needs a specific value that the model doesn't provide - classically clock-ready
bits so a clock-init busy-wait completes:
```repl
sysbus:
    init:
        ApplySVD @https://…/STM32F103.svd.gz        # name+reset-value fallback for unmodeled regs
        Tag <0x40021000, 0x40021003> "RCC_CR" 0x0A020083   # force HSE/PLL ready bits for boot
```

### Step 7 - Compose for a board
A *CPU* `.repl` (everything above) is reused by *board* `.repl`s that `using` it and add board
peripherals (LEDs, buttons, external flash, sensors) - see
[doc 01 §3/§9](01-repl-format.md#3-using--including-other-repl-files). Keep the SoC in
`platforms/cpus/<soc>.repl` and the board in `platforms/boards/<board>.repl`.

---

## 5. The model-matching problem (which `Category.Class`?)

The SVD/RM tells you a peripheral *exists*; you must map it to a Renode C# model. Strategy:

1. **List candidates** in the catalog:
   `ls renode-infrastructure/src/Emulator/Peripherals/Peripherals/<Category>/` and grep names
   (e.g. `grep -ril "stm32.*uart" .../UART/`). At runtime, the Monitor `peripherals` and tab
   completion enumerate available types ([doc 02 §5](02-resc-monitor.md), `TypeManager`).
2. **Prefer same-IP reuse, even across families.** Renode models are by IP block, not by part
   number. F103 reuses `IRQControllers.STM32F4_EXTI` and `DMA.STM32G0DMA` despite being an
   F1 - because the EXTI/DMA IP is compatible enough. Look for `<Vendor><IP>` or
   `<Family>_<IP>` classes and read the class to confirm register layout matches your RM.
3. **Close-but-not-exact:** pick the nearest model and lean on `ApplySVD` + `Tag` (§6.3) to
   satisfy the registers it doesn't implement, so firmware still boots. Watch the logs for
   "unhandled access" floods (§7) to find where the mismatch hurts.
4. **Nothing fits:** write a new C# peripheral ([doc 03](03-csharp-peripherals.md)); drop the
   `.cs` in the right category folder, rebuild (auto-globbed -
   [doc 04 §5](04-repl-to-csharp-bridge.md#5-how-peripheral-cs-files-reach-the-assembly-typemanager-scans)),
   then reference it. For fast iteration you can `include @my.cs` to ad-hoc compile without a
   full rebuild.

A practical first pass: model the CPU, NVIC, memories, the UART you'll watch, the SysTick/timer,
and the clock controller (RCC) just enough to boot; `ApplySVD` the rest. Add fidelity where the
firmware actually depends on it.

---

## 6. Verifying a generated `.repl` (the closed loop)

> Not executed in this environment (no `dotnet`); these are the exact commands the loop uses.

### 6.1 Static load test (fastest signal)
The `CreationDriver` validates aggressively at load time (types, constructors, IRQ arity,
registration). Just loading the platform surfaces most structural errors:
```bash
renode --console --disable-xwt -e \
  "mach create; machine LoadPlatformDescription @platforms/cpus/myboard.repl; quit"
```
- **Clean exit** ⇒ the platform parses, all types resolve, all ctors match, all IRQs/regs wire.
- **Error** ⇒ the driver prints `Error Enn:`, the **file:line**, a caret under the offending
  token, and (for ctor failures) a full **"constructor selection report"** explaining why each
  candidate was rejected ([doc 04 §4](04-repl-to-csharp-bridge.md#4-constructor-selection-for-the-peripheral-itself)).
  These messages are precise - they are the ideal thing to feed back to an LLM.

> **No source build / `dotnet` needed for this oracle.** A **portable / nightly** Renode binary runs
> the load test directly - and even `cpu Step` single-stepping of a hand-loaded program. Verified on the
> Mindgrove MGS2401 (Shakti C-class) bring-up: against the bundled portable, `mgs2401.repl` loaded clean
> (CPU/CLINT/PLIC/memories registered, every unmodeled peripheral `Tag`-ged) and the RV64 core executed
> a two-instruction test (`addi` ×2 → registers and PC advanced correctly). So you can iterate the §6.5
> loop without building from source.

### 6.2 Reading the errors (map message → fix)
| Symptom | Likely cause | Fix |
|---|---|---|
| `Could not resolve type 'X.Y'` | model name/category wrong, or part not modeled | fix `Category.Class`, or pick another model / write one (§5) |
| `Could not find suitable constructor` + report | a `name:` attribute doesn't match any ctor param / wrong value type | rename the attribute, fix the value, or move it to a property |
| `Property 'P' does not have a public setter` | P is `{get;}`/`{get;private set;}` | it's not settable from `.repl`; use a ctor arg or a different model |
| `Irq arity does not match` | `[a-b] -> x@[c-d]` lengths differ | align ranges/lists |
| `… does not implement IGPIOReceiver` | destination isn't an IRQ sink | wrong target, or wrong direction |
| registration error / `Are all parents registered?` | a parent peripheral isn't registered, or `@ sysbus 0xADDR` on a non-`IKnownSize` type | use `<addr,+size>`, fix parent order, or make type `IKnownSize` |

### 6.3 Bring-up aids: `ApplySVD`, `Tag`, access logging
- `ApplySVD @file.svd[.gz]` - for every address the SVD covers but you didn't model, reads
  return the SVD **reset value** and accesses are **logged with register/field names** instead
  of raw "unhandled access" (`SystemBus.ApplySVD` → `SVDParser`). Lets firmware progress past
  unmodeled peripherals.
- `sysbus Tag <start, end> "NAME" value` - pin a fixed value/label on a small region (clock
  ready bits, chip-ID, etc.) (`SystemBus.Tag`). Use for the few registers firmware spins on.
- `sysbus LogAllPeripheralsAccess true` and `logLevel -1` - turn on noisy access logging to see
  exactly where firmware reads/writes and where the model is missing behavior.

### 6.4 Firmware smoke test (does it boot?)
Write a tiny `.resc` and watch a UART:
```
mach create "myboard"
machine LoadPlatformDescription @platforms/cpus/myboard.repl
sysbus LoadELF @firmware.elf
showAnalyzer sysbus.usart1            # the UART you modeled
cpu PC `sysbus GetSymbolAddress "Reset_Handler"`   # or rely on the vector table
sysbus LogAllPeripheralsAccess true  # while bringing up; turn off once stable
start
emulation RunFor "0.5"
```
Healthy signs: PC advances through `main`, UART emits expected banner, no endless
"unhandled read/write" storm on a critical peripheral, IRQs fire. Inspect with `cpu PC`,
`cpu IsHalted`, the analyzer window, and the log.

### 6.5 The agent loop (generate → load → feed back → repeat)
1. Generate `myboard.repl` from §2–§5.
2. Run the §6.1 load test; capture stdout.
3. If errors: feed the **exact** `Error Enn` block (with file:line + caret + ctor report) back to
   the LLM along with the offending repl lines; apply the fix; goto 2.
4. When it loads clean: run §6.4; feed the access log / UART output back; add models/Tags where
   firmware stalls; repeat until boot.
This is exactly the loop you described - each Renode message is structured and localized, which
makes it a good closed-loop signal for an LLM.

---

## 7. Pitfalls & pre-flight checklist

**Pitfalls**
- `@ sysbus 0xADDR` requires the model to be `IKnownSize`; otherwise use `<addr, +size>`.
- DMA/timer **channel index base** (0- vs 1-based) - confirm against the model's `Connections`.
- EXTI/IRQ **fan-in**: size `CombinedInput.numberOfInputs` to the RM group exactly.
- **Memory regions ≠ SVD peripheral bases** (FSMC bank `0x60000000` vs FSMC regs `0xA0000000`).
- **Registration base ≠ SVD base** when the model maps only the register block: nRF52840 GPIO
  SVD `P0 = 0x50000000` but the model registers at `0x50000500` (SVD base + 0x500, because the
  port reserves `0x000–0x4FF`) - [§2.1](#21-caveat--the-model-base-can-be-svd-base--register-block-offset).
  STM32 is offset-0, which is why this never bites there.
- **FPGA-prototype values ≠ silicon values** for a soft-SoC that was later fabricated (Shakti, some
  SiFive parts). The in-tree DTS is often the **FPGA bring-up board's** tree, so its `clock-frequency`,
  `timebase-frequency`, and `memory` node describe the prototype, not the chip. Mindgrove MGS2401
  (Shakti C-class): `c-class.dts` says `timebase-frequency = 10 MHz` and a **256 MB** DDR
  `memory@80000000`, but the silicon is **700 MHz** with **128 KB** SRAM at that same base. A generator
  that trusts the DTS mis-sets the CLINT `frequency:` and over-sizes RAM ~2000×. Cross-check clocks,
  timebase, and memory sizes against the **datasheet**; treat the DTS as authoritative for *addresses
  and wiring*, not for *clocks and sizes*.
- **Clock-ready Tags**: firmware often busy-waits on RCC/PLL ready bits the model doesn't set -
  Tag them (the F103 `RCC_CR 0x0A020083` trick).
- **AF table direction**: F103 wires both `timer -> gpio#pin` and `gpio pin -> timer`; get both.
- `priorityMask` is the **top** N bits (`nvicPrioBits=4` → `0xF0`), not `0x0F`.
- Indentation is **exactly 4 spaces**; `//` comments need a leading space ([doc 01](01-repl-format.md)).
- **Comment char:** in the **repl body** use `//` or `/* … */` - **`#` is *not* a repl comment** (it's the
  IRQ local-index char, e.g. `gpioPortA#08`). `#` is a comment **only inside** `init:`/`reset:` blocks and
  `.resc` files (those are *Monitor* commands). The inline `#` annotations in this doc's snippets are
  illustrative - in a real repl body they must be `//`. (Verified: `PreLexer.cs` strips only `//` and `/* */`.)

**Checklist**
- [ ] CPU `cpuType` + NVIC `priorityMask` + `systickFrequency` set (SVD cpu + DS clock).
- [ ] All memory regions from the RM map present and sized.
- [ ] Every SVD peripheral either modeled or covered by `ApplySVD`.
- [ ] Every modeled peripheral's IRQ(s) wired to the SVD interrupt number.
- [ ] EXTI lines routed (direct + sized `CombinedInput` groups).
- [ ] DMA controllers instantiated; peripheral DMA requests routed (RM table).
- [ ] GPIO ports + AFIO + AF mesh + `invertedAFPins` from the DS.
- [ ] Loads clean in Renode (§6.1).
- [ ] Reference firmware boots and talks on a UART (§6.4).

---

## 8. Worked example evidence (STM32F103)

The actual `platforms/cpus/stm32f103.repl` annotated by provenance, with the SVD cross-check
from §2:

```repl
// --- SVD-derived (verified exact match to STM32F103.svd) ---
usart1: UART.STM32_UART @ sysbus <0x40013800, +0x100>  // base 0x40013800 ✓ SVD
    -> nvic@37                                           // IRQ 37 ✓ SVD 'USART1'
nvic: IRQControllers.NVIC @ sysbus 0xE000E000
    priorityMask: 0xF0                                   // nvicPrioBits=4 ✓ SVD
    systickFrequency: 72000000                           // ✗ NOT in SVD - DS clock tree
i2c1: I2C.STM32F1_I2C @ sysbus 0x40005400                // base ✓ SVD
    EventInterrupt -> nvic@31                            // ✓ SVD 'I2C1_EV'=31
    ErrorInterrupt -> nvic@32                            // ✓ SVD 'I2C1_ER'=32

// --- RM-derived (not in SVD) ---
exti: IRQControllers.STM32F4_EXTI @ sysbus 0x40010400    // base ✓ SVD; model reuse from F4
    [5-9] -> nvicInput23@[0-4]                           // grouping = RM
nvicInput23: Miscellaneous.CombinedInput @ none
    numberOfInputs: 5                                    // fan-in count = RM
    -> nvic@23                                           // vector 23 ✓ SVD 'EXTI9_5'
usart1:
    DMARequest -> dma1@4 | dma1@5                        // DMA routing = RM

// --- DS-derived (not in SVD) ---
gpioPortA: GPIOPort.STM32F1GPIOPort @ sysbus <0x40010800, +0x400>  // base ✓ SVD
    invertedAFPins: [[7, 1]]                             // silicon AF quirk = DS/errata
timer1:
    0 -> gpioPortA#08@01 | …                             // AF table = DS

// --- firmware bring-up (not a cold-reset value) ---
sysbus:
    init:
        ApplySVD @https://…/STM32F103.svd.gz
        Tag <0x40021000, 0x40021003> "RCC_CR" 0x0A020083 # SVD cold reset = 0x00000083; forced for boot
```

**Cross-check raw evidence** (from the real `STM32F103.svd`):
- Bases: `USART1=0x40013800`, `I2C1=0x40005400`, `TIM1=0x40012C00`, `DMA1=0x40020000`,
  `EXTI=0x40010400`, `AFIO=0x40010000`, `RCC=0x40021000` - all equal the repl.
- IRQs: `EXTI0..4=6..10`, `EXTI9_5=23`, `EXTI15_10=40`, `DMA1_Channel1..7=11..17`,
  `TIM1_BRK/UP/TRG_COM/CC=24/25/26/27`, `I2C1_EV/ER=31/32`, `USART1/2/3=37/38/39`,
  `UART4/5=52/53`, `DMA2_Channel1=56` - all equal the repl.
- `<cpu><nvicPrioBits>4` → `priorityMask: 0xF0`.
- `grep -c systick|72000000` in the SVD = **0** → `systickFrequency` is not SVD-derivable.
- RCC_CR `<resetValue>0x00000083` ≠ the repl `Tag … 0x0A020083` → the Tag is a boot override.

---

## 9. Vendor / architecture adaptations

The §2 method is universal; the *special-case* rows differ by silicon:

- **STM32 (Cortex-M)** - the full menu: EXTI→NVIC grouping, AFIO/`SYSCFG` pin-mux, DMA request
  maps, AF tables, `invertedAFPins`. The worked example.
- **Other Cortex-M (NXP Kinetis, Nordic nRF, Ambiq, Renesas RA, …)** - same SVD-driven core
  (NVIC `0xE000E000`, `priorityMask` from `nvicPrioBits`), but **no EXTI/AFIO**: pin-mux is a
  PORT/PINCFG/GPIO block, and interrupt routing is usually flatter (per-peripheral vectors). Some
  such CPU `.repl`s lean on `ApplySVD` (e.g. the repo's `nxp-k6xf.repl` simply
  `ApplySVD @…/MK64F12.svd.gz`); many don't. DMA exists but the request-mux model differs.
  **Verified on nRF52840 (§2.1):** the prediction holds - per-peripheral vectors straight to
  `nvic@N`, no EXTI/AFIO, a `GPIOTasksEvents` (GPIOTE) pin-mux, and `priorityMask` derivable from
  `nvicPrioBits` (3 → `0xE0`). **But watch the GPIO base offset** - model base = SVD base + 0x500.
- **RISC-V (LiteX, GD32V, Kendryte, …)** - **no NVIC/EXTI/AFIO at all.** The interrupt fabric is
  `PLIC` (external) + `CLINT`/`machineTimer` (software/timer interrupts); the CPU is
  `CPU.VexRiscv`/`CPU.IbexRiscV32`/etc. with `timeProvider`/PLIC wiring instead of
  `nvic:`/`priorityMask`. Crucially, **soft-SoCs usually ship no SVD** - base addresses come from
  the SoC's *generated* config (LiteX emits a CSV/JSON), or a device tree, not a CMSIS-SVD. The
  whole "Step 0/3/5" block is replaced by PLIC/CLINT wiring. Study an existing RISC-V CPU
  `.repl` (`platforms/cpus/litex_vexriscv.repl`, `litex_ibex.repl`) as the template.

> **Reality check - the SVD path is the exception, not the rule.** Of the 118 CPU `.repl`s
> shipped in `platforms/cpus/`, **only 15 use `ApplySVD` at all** - 14 of them Cortex-M across
> several vendors (ST `stm32*`/`stm32w108`, Nordic `nrf52840`, NXP `nxp-k6xf`/`s32k118`, Microchip
> `sam_e70`, Maxim `max32652`) **plus the RISC-V SiFive `sifive-fe310`** (`CPU.RiscV32`,
> `rv32imac`). That last one matters: SVD is *mostly* an Arm/Cortex-M convention, but **not
> exclusively** - SiFive publishes CMSIS-SVDs for some of its RISC-V parts, so "RISC-V ⇒ no SVD" is
> a strong tendency, not a law. The genuinely niche, non-Cortex-M parts still typically have **no
> CMSIS-SVD** - and a different interrupt controller entirely:
> SPARC LEON (`leon3`, `gr712rc` → `IRQControllers.GaislerMIC`), PowerPC (`mpc5567` →
> `MPC5567_INTC`, `microwatt` → `CPU.PowerPc64`), MSP430 (`msp430f2619`), Xtensa
> (`xtensa-sample-controller`), and RISC-V soft-SoCs. For these the **entire SVD column of §2 is
> unavailable** - you fill it from the [§3.1](#31-when-theres-no-svd--alternative-primary-sources)
> substitutes (device tree, BSP header, SoC-generator output, SystemRDL, or HDL) plus the chosen
> C# model's register map and a same-architecture scaffold `.repl`, and the §6 load/boot loop
> becomes your primary source of truth instead of the SVD cross-check.

Pick a same-architecture existing CPU `.repl` as your scaffold, then swap in your bases, sizes,
and interrupt numbers (from the SVD **if one exists**, else the RM + model), and rebuild the
silicon-specific meshes from your RM/DS.

---

## 10. Notes for an automated (LLM) generator

- **Parse the SVD programmatically** - it's XML. Extract, per `<peripheral>`: `name`,
  `baseAddress`, `addressBlock/size`, each `<interrupt>` `name`+`value` (and follow
  `derivedFrom`), and per `<register>` `name`+`addressOffset`+`resetValue`. Plus `<cpu>`
  `name`/`nvicPrioBits`. This is deterministic and covers the entire SVD column of §2 - **with two
  caveats**: (a) the *registration* base is `baseAddress + (SVD first-register offset − model
  first-register offset)`, not `baseAddress` raw, when the model maps only the register block
  (the nRF52840 GPIO `+0x500` trap, [§2.1](#21-caveat--the-model-base-can-be-svd-base--register-block-offset)) - so resolve it against the chosen model's register
  enum, don't emit `<baseAddress>` blindly; (b) **most parts ship no SVD** (only 15 of 118 CPU
  `.repl`s use one - §9), so make the parser pluggable: accept the
  [§3.1](#31-when-theres-no-svd--alternative-primary-sources) substitutes too - a device tree
  (`.dts`), a BSP/SDK header, the SoC generator's CSR map (LiteX `csr.json`), or a SystemRDL model
  (see `tools/PeakRDL-repl`) - each yields the same base/size/IRQ/reset facts in a different
  encoding, then fall back to RM + model + scaffold.
- **Use the RM/DS (PDF/HTML) for the rest** - interrupt grouping, DMA maps, AF tables, clock
  tree, memory map. These need document understanding; structure them into tables first, then
  emit the repl meshes.
- **Match models** by grepping the catalog (§5) and reading candidate classes to confirm
  register-layout compatibility; record the mapping `SVD-peripheral → Category.Class`.
- **Close the loop with Renode** (§6): the load test is fast and its errors are localized
  (file:line + caret + ctor report) - ideal structured feedback. Iterate until clean, then boot
  a reference firmware and iterate on fidelity (`ApplySVD` + access logs guide where to add it).
- **Cross-check** generated bases/IRQs back against the SVD (as done in §8) before trusting the
  RM/DS-derived parts - it catches transcription errors early.

---

See also: [01 (`.repl`)](01-repl-format.md) · [03 (C# peripherals)](03-csharp-peripherals.md) ·
[04 (the bridge)](04-repl-to-csharp-bridge.md) · [05 (cheatsheet)](05-cheatsheet.md).
