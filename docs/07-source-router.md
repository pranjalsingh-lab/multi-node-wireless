# 07 - Source Router: which documents to fetch for a new CPU/architecture

> **Goal (same as [doc 06](06-generating-a-new-board.md)):** produce a working `.repl` for a chip
> Renode doesn't ship yet. Doc 06 tells you *how to assemble* a `.repl` once you have the facts.
> **This doc is the step before that: given a new CPU/architecture, decide *which source documents
> to fetch* to obtain those facts** - and what each document is good for.
>
> It is a **router**, not a tutorial: classify the part, then follow the matching playbook. It is
> grounded in the *actual* provenance citations the Renode authors left in
> `platforms/cpus/*.repl` (mined, not remembered - see the [Evidence appendix](#evidence-appendix)).
> Per the request: when in doubt it **over-fetches**. Fetching a redundant document is cheap;
> discovering mid-bring-up that you never had the interrupt map is not.

---

## 0. The 5 fact-classes you are routing for

Every `.repl` line traces to one of five fact-classes (this is [doc 06 §1–§2](06-generating-a-new-board.md#1-the-core-idea-every-repl-line-has-a-provenance) restated as a *shopping list*). The router exists to find a document for **each** class:

| # | Fact-class | Examples | Canonical document |
|---|---|---|---|
| **F1** | **Address map** (bases, window sizes) | `usart1 @ 0x40013800, +0x100` | machine-readable HW description (SVD / DTS / generator CSR / SystemRDL / header) → else RM memory map |
| **F2** | **Interrupt numbers / fabric** | `-> nvic@37`, `-> plic@4` | machine-readable description (`<interrupt>`/`interrupts`) **+** RM vector table for grouping/fan-in |
| **F3** | **Core config** | `cpuType`, `priorityMask`/`nvicPrioBits`, FPU/MPU, `privilegedArchitecture`, `hartId` | machine-readable `<cpu>` node / DTS `cpu` node + ISA string |
| **F4** | **Routing meshes** (DMA req maps, EXTI/pin-mux, AF tables, clock tree) | `DMARequest -> dma1@4`, AF mesh, `systickFrequency` | **Reference Manual + Datasheet only** - never in the machine-readable file |
| **F5** | **Model selection** (which `Category.Class`) | `UART.STM32_UART` vs `UART.SiFive_UART` | the **Renode C# catalog** + judgment ([doc 06 §5](06-generating-a-new-board.md#5-the-model-matching-problem-which-categoryclass)) |

F4 and F5 are **architecture-independent** - you always need the RM/DS and the catalog. **The router's job is mostly F1–F3**: *which machine-readable description exists for this part, and where to get it.* That answer is what changes by architecture.

---

## 1. The routing algorithm (run top to bottom)

```
STEP 1  Identify the ISA/core           → §2 decision tree  → gives you the FAMILY
STEP 2  Pick the scaffold .repl          → §3 table (copy a same-family in-tree repl)
STEP 3  Find F1/F2/F3 machine-readable   → §3 table + §4 playbook for the family
            ├─ exists?  fetch it (SVD / DTS / CSR / RDL / header)
            └─ none?    fall through the §4 substitute ladder for that family
STEP 4  Fetch F4 human docs (RM + DS)    → §5 fact→document map (same for all families)
STEP 5  Resolve F5 models                → grep the catalog (doc 06 §5); read the class register map
STEP 6  Close the loop in Renode         → doc 06 §6 (load → read errors → boot firmware)
```

If any of STEP 3/4 is ambiguous, **escalate to §6 "If unsure, over-fetch"** and pull every candidate.

---

## 2. STEP 1 - Classify the core (decision tree)

Start from whatever you know (part number, `CPU.*` you'd use, the ISA, the SoC generator). The fastest tell is the **interrupt controller**, because it is a 1:1 function of the architecture in Renode:

```
Is it Arm?
├─ Cortex-M (M0/M0+/M3/M4/M7/M23/M33/M55…)   → FAMILY = CORTEX-M     (IRQ: NVIC @0xE000E000; STM32 adds EXTI/AFIO)
├─ Cortex-A / Cortex-R / ARMv7-A,R / ARMv8-A,R → FAMILY = ARM-APP     (IRQ: GIC = ARM_GenericInterruptController + redistributor)
│
Is it RISC-V?
├─ Hard silicon SoC (SiFive, GD32V, Kendryte, Andes…) → FAMILY = RISCV-HARD  (IRQ: PLIC + CLINT)
├─ Soft-SoC / FPGA gateware (LiteX, OpenTitan, Murax, microwatt, PULP, VeeR) → FAMILY = RISCV-SOFT (IRQ: PLIC/CLINT or a custom CSR controller)
│
Else:
├─ x86 / x86_64                       → FAMILY = X86      (IRQ: LAPIC + IOAPIC)
├─ SPARC (LEON3/LEON4, GR712/GR716)   → FAMILY = SPARC    (IRQ: GaislerMIC)
├─ PowerPC (mpc5567, microwatt)       → FAMILY = POWERPC  (IRQ: MPC5567_INTC / SoC-specific)
├─ MSP430                              → FAMILY = MSP430   (IRQ: peripheral-level vectors, no central controller)
├─ Xtensa                             → FAMILY = XTENSA   (config-defined; core-isa.h)
└─ anything else                      → FAMILY = UNKNOWN  → §4.UNKNOWN + §6
```

> **Why the interrupt controller is the discriminator:** the F2 fabric is the single most
> architecture-specific thing in a `.repl`, and it dictates the whole top of the file
> (CPU + controller declaration). NVIC ⇒ Cortex-M; GIC ⇒ Arm application core; PLIC/CLINT ⇒ RISC-V;
> LAPIC/IOAPIC ⇒ x86; GaislerMIC ⇒ LEON. (Verified counts in the [appendix](#evidence-appendix).)

---

## 3. STEP 2/3 - Master routing table

For each family: the **scaffold** to copy, the **machine-readable source(s)** to fetch first (F1–F3),
the **interrupt model**, and whether an **SVD** is realistic. Scaffold filenames are real and exist in
`platforms/cpus/` (verified).

| FAMILY | Copy this scaffold first | F1–F3 machine-readable source, best→worst | Interrupt model (`IRQControllers.*` / `CPU.*`) | SVD likely? |
|---|---|---|---|---|
| **CORTEX-M** | `stm32f103.repl` (full STM32 menu), `nrf52840.repl` (non-ST), `nxp-k6xf.repl`/`sam_e70.repl` (SVD-only) | **CMSIS-SVD** (vendor site / CMSIS `.pack`) → vendor **HAL/CMSIS header** (`*xx.h` `#define BASE`, IRQn enum) → RM memory map | `NVIC` @ `0xE000E000`; STM32 also `STM32F4_EXTI`/`STM32*_EXTI`, `STM32F1AFIO` | **Yes** - ST/Nordic/NXP/Microchip/Maxim publish them |
| **ARM-APP** (A/R) | `zynq-7000.repl`, `zynqmp.repl`, `cortex-a53-gicv3.repl`, `vexpress.repl` | **Device tree** (`.dts`/`.dtsi`, Linux/Zephyr/U-Boot) → SoC **TRM** + vendor **register reference** (e.g. AMD UG1087) | `ARM_GenericInterruptController` (GICv2/v3) + `ArmGicRedistributorRegistration`; *GIC→CPU wiring auto-generated* | **Rarely** - use DTS |
| **RISCV-HARD** | `sifive-fu540.repl`, `sifive-fe310.repl` | **Device tree** (SiFive/Linux) → **SVD if the vendor ships one** (SiFive FE310 does!) → SoC manual | `PlatformLevelInterruptController` (PLIC) + `CoreLevelInterruptor` (CLINT); CPU `RiscV64`/`RiscV32`, `timeProvider: clint` | **Sometimes** (fe310) - mostly DTS |
| **RISCV-SOFT** | `litex_vexriscv.repl`, `litex_ibex.repl`, `fomu.repl`, `opentitan-earlgrey.repl` | **SoC generator output** (LiteX `csr.csv`/`.json`, generated headers) / **SystemRDL** (`tools/PeakRDL-repl`) / **auto-gen** (OpenTitan) → **device tree** → **the HDL/RTL** | PLIC/CLINT *or* custom: `OpenTitan_PlatformLevelInterruptController`, `AndesNCEPLIC100`, `MiV_CoreLevelInterruptor`, `VeeR_EL2_PIC`, `PULP_InterruptController` | **No** - generator/DTS/HDL |
| **X86** | `x86.repl`, `up_squared_x86_64.repl`, `quark-c1000.repl` | Board/firmware docs, **ACPI**/Zephyr DTS, fixed PC architecture constants | `LAPIC` (+ `IOAPIC`) | No |
| **SPARC** (LEON) | `leon3.repl`, `gr716.repl`, `gr712rc.repl` | **Gaisler GRLIB IP manual** (HTML/PDF, non-SVD) + the GRLIB AMBA plug&play table | `GaislerMIC`; `CPU.Sparc` | No |
| **POWERPC** | `mpc5567.repl`, `microwatt.repl` | NXP **RM** (mpc5567) / **HDL** (microwatt gateware) | `MPC5567_INTC` (mpc5567) / SoC-specific; `CPU.PowerPc`/`PowerPc64` | No |
| **MSP430** | `msp430f2619.repl` | **TI SLAU family user guide** (e.g. SLAU144/SLAU208) + device-specific datasheet | none central - peripheral-level vectors; models `MSP430_*` (`MSP430_Timer`, `MSP430_USCIA`, …) | No |
| **XTENSA** | `xtensa-sample-controller.repl` | **`core-isa.h`** (toolchain-generated; core is configurable) + the SoC config | config-defined; `CPU.Xtensa` | No |
| **UNKNOWN** | nearest-ISA scaffold above | run the **full §6 ladder** | infer from the chosen CPU model | ? |

---

## 4. STEP 3 - Per-family fetch playbooks (the substitute ladder)

Each playbook is an **ordered list of documents to fetch**. Stop when you have F1–F3; the lower rungs
are fallbacks. F4 (RM/DS) and F5 (catalog) come after, from §5 - they apply to *every* family.

### 4.CORTEX-M
1. **CMSIS-SVD** for the exact part - vendor download page, or the CMSIS `.pack` (a zip → `Device/.../*.svd`). Gives F1 (bases/sizes), F2 (IRQ numbers), F3 (`<cpu> nvicPrioBits`, FPU/MPU), and register reset values. *Renode can even consume it at runtime via `ApplySVD` (doc 06 §6.3).*
2. **Vendor HAL/CMSIS device header** (`stm32f1xx.h`, `MK64F12.h`, `nrf.h`) - `#define`d base addresses + the `IRQn_Type` enum; corroborates the SVD and **replaces it when no SVD exists**.
3. **Reference Manual** - memory map (F4: flash/SRAM/external), EXTI↔NVIC grouping, DMA request maps, clock tree.
4. **Datasheet** - pinout + **alternate-function tables** (F4 AF mesh), max clock (→ `systickFrequency`), AF silicon quirks (`invertedAFPins`).
> ⚠️ **The §2.1 offset trap still applies:** registration base = SVD base **+** (SVD first-reg offset − model first-reg offset). STM32 is offset-0; check anyway ([doc 06 §2.1](06-generating-a-new-board.md#21-caveat--the-model-base-can-be-svd-base--register-block-offset)).

### 4.ARM-APP (Cortex-A / Cortex-R)
1. **Device tree** (`.dts`/`.dtsi`) from Linux (`arch/arm*/boot/dts/`), Zephyr (`dts/arm*/`), or U-Boot - `reg = <base size>` (F1), `interrupts = <…>` + `interrupt-parent` (F2), `cpus` node + `compatible` (F3). For Arm-app parts this is the **primary** source; CMSIS-SVDs usually don't exist.
2. **SoC Technical Reference Manual (TRM)** + **vendor register reference** (e.g. AMD/Xilinx **UG1087** for ZynqMP) - memory map, GIC SPI numbers, clock/reset.
3. **The GIC spec** for the wiring convention: declare `ARM_GenericInterruptController` + per-core `ArmGicRedistributorRegistration`; **GIC→CPU connections are generated automatically** (don't hand-wire them - verified comment in 11 ARM-app repls).
4. **`tools/dts2repl`** (§7) - can auto-convert a Zephyr DTS to a first-draft repl.

### 4.RISCV-HARD
1. **Device tree** (SiFive/Linux/SDK) - bases, `interrupts`, `interrupt-controller` (PLIC), `clint`/`timebase-frequency` (F1–F3). `sifive-fu540.repl` explicitly took its SPI base **from the DTS over the datasheet**.
2. **CMSIS-SVD if the vendor ships one** - yes, RISC-V SVDs exist (SiFive **FE310** uses `ApplySVD @…/FE310.svd.gz`). Don't assume "RISC-V ⇒ no SVD."
3. **SoC manual** for PLIC source numbers, CLINT base, hart layout.
4. Declare `PlatformLevelInterruptController` + `CoreLevelInterruptor`; set each CPU's `timeProvider: clint`, `hartId`, `privilegedArchitecture`.
> ⚠️ **A committed DTS can carry WIP placeholder `interrupts` - cross-check the BSP/SDK `platform.h`.**
> The router lists the device tree first for F1–F3, but for **F2 (PLIC source numbers)** a vendor's
> BSP/SDK interrupt-ID header is frequently *more* reliable. On Mindgrove MGS2401 (Shakti C-class) the
> committed Zephyr DTS had **contradictory placeholder** UART interrupts (`<47>` vs `<&plic0 6>`), while
> the FreeRTOS BSP `platform.h` carried the authoritative, internally-consistent PLIC table (contiguous
> 1–58: GPIO 1–32, PWM 33–40, GPTimer 41–44, I2C 45–46, UART 47–49, QSPI 50–53, SPI 54–57, ADC 58).
> Treat the BSP interrupt-ID header as **co-primary with the DTS** for F2 on vendor RISC-V MCUs, not a
> mere fallback rung - and reconcile the two before wiring a real model's IRQ.

### 4.RISCV-SOFT (LiteX / OpenTitan / Murax / microwatt / PULP / VeeR)
1. **The SoC generator's own output** - there is *no datasheet* because the address map is whatever the build assigned:
   - **LiteX** → `csr.csv` / `csr.json` (CSR base map) and the generated `soc.h`/`mem.h` headers (`fomu.repl` is built from LiteX generated headers).
   - **OpenTitan** → the auto-generated config (`opentitan-earlgrey.repl` header: *"Auto-generated … at commit f243e680…"*); also a specific OpenTitan C file for board variants.
2. **SystemRDL** model → run **`tools/PeakRDL-repl`** (ships in-tree: *"PeakRDL exporter plugin for generation of Renode REPL platform description files"*).
3. **Device tree** if the gateware targets Zephyr/Linux (`litex_vexriscv_zephyr.repl` is based on Zephyr's `riscv32-litex-vexriscv.dtsi`).
4. **The HDL/RTL itself** - read the bus address decoder. Model names betray the gateware: `Murax_UART`/`Murax_GPIO` (SpinalHDL Murax), `Potato_UART` (microwatt VHDL), `LiteX_Timer*`.
5. **The §6 firmware loop becomes the spec** - with no docs, load → boot → watch the access log *is* your ground truth.

### 4.NO-SVD FAMILIES (X86 · POWERPC · SPARC · MSP430 · XTENSA) - shared flow
These five have **no CMSIS-SVD and (usually) no device tree** - doc 06's "parse the machine-readable
description" path is unavailable. The flow collapses to **four sources**, identical for all five:

1. **Copy the in-tree sibling `.repl`** as scaffold (the ones below - all 11–71 lines, so read the whole file).
2. **Vendor Reference Manual** (hard silicon) **or the HDL/RTL** (soft cores) → bases + IRQ numbers (F1/F2).
3. **The chosen C# model's register map** → offsets, ctor/property names (F1/F5; [doc 06 §6.2](06-generating-a-new-board.md#62-reading-the-errors-map-message--fix)).
4. **The [doc 06 §6](06-generating-a-new-board.md#6-verifying-a-generated-repl-the-closed-loop) load→boot→access-log loop** → the real oracle; with no SVD this *is* the spec.

**At-a-glance - the architecture-specific must-dos** (verified against the shipped repls):

| Family | CPU class | Interrupt model | Big-endian bus? | The thing that bites you |
|---|---|---|---|---|
| **X86** | `CPU.X86` / `CPU.X86_64` | `LAPIC` @ `0xFEE00000` (+ `IOAPIC` @ `0xFEC00000` for SMP) | No | legacy PIC/PIT/CMOS/PCI-config aren't modeled - `Tag` them in `init:` |
| **POWERPC** | `CPU.PowerPc` / `PowerPc64` | `MPC5567_INTC` (mpc5567); SoC-specific or none (microwatt) | **Yes** - set it first | LE-on-BE core needs `endianness:`; fake the PLL/clock-ready bit |
| **SPARC** (LEON) | `CPU.Sparc` | `GaislerMIC` | **Yes** | also declare the GRLIB plug-&-play bus objects |
| **MSP430** | `CPU.MSP430X` | none - each peripheral wires `IRQn -> cpu@N` | No | split SFRs need `Bus.BusMultiRegistration`; use `Memory.ArrayMemory` |
| **XTENSA** | `CPU.Xtensa` | config-defined (no bus controller in the sample) | No | `cpuType` must name a core config Renode knows; regions from `core-isa.h` |

> **⚠ Comment syntax (catches everyone):** in the **repl body**, comments are `//` (needs a leading
> space before it) or `/* … */` - **`#` is *not* a repl comment** (it's the IRQ local-index char, as in
> `gpioPortA#08`). `#` works **only inside** `init:`/`reset:` blocks and `.resc` files, which are
> **Monitor** commands. (Verified: `renode/src/Renode/PlatformDescription/PreLexer.cs` recognises only
> `//` and `/* */`.) The snippets below use `//` correctly.

### 4.X86 - scaffold `x86.repl` · `up_squared_x86_64.repl` · `quark-c1000.repl`
Top of file (from `x86.repl`, verified):
```repl
cpu: CPU.X86 @ sysbus
    cpuType: "n270"
    lapic: lapic                                   // ctor wiring, like Cortex-M's `nvic: nvic`
lapic: IRQControllers.LAPIC @ sysbus 0xFEE00000    // architectural constant
    IRQ -> cpu@0
hpet: Timers.HPET @ sysbus 0xFED00000
uart: UART.NS16550 @ sysbus 0xE00003F8
```
- **Fetch:** Intel SDM + **chipset datasheet** for the *fixed* platform addresses (LAPIC `0xFEE00000`, IOAPIC `0xFEC00000`, HPET `0xFED00000`); the board's **ACPI tables / Zephyr DTS** for device addresses; a **firmware image** (BIOS/UEFI/Zephyr) for the §6 loop.
- **Must-do:** the legacy PC devices firmware pokes - 8259 PIC, 8254 PIT, PCI config `0xCF8/0xCFC`, CMOS `0x70/0x71` - are **not modeled**; `Tag` them under `sysbus: init:` so accesses don't fault (see `x86.repl`). Multicore ⇒ add `IRQControllers.IOAPIC`.

### 4.POWERPC - scaffold `mpc5567.repl` (hard) · `microwatt.repl` (soft)
Top of file (from `mpc5567.repl`, verified):
```repl
sysbus:
    Endianess: Endianess.BigEndian                 // MANDATORY for PowerPC - set before anything
cpu: CPU.PowerPc @ sysbus
    cpuType: "e200z6"
intc: IRQControllers.MPC5567_INTC @ sysbus 0xFFF48000
    IRQ -> cpu@0
uart: UART.MPC5567_UART @ sysbus 0xFFFB0000
```
- **Fetch:** **mpc5567** → NXP/Freescale **Reference Manual** (memory map, peripheral bases, `MPC5567_INTC` line numbers). **microwatt** → the open **HDL/RTL** (bases from the address decoder); models `CPU.PowerPc64` + `UART.Potato_UART`.
- **Must-do:** set the **big-endian bus** first. A little-endian core on the BE bus declares its own `endianness: Endianess.LittleEndian` (microwatt does). Firmware busy-waits on a PLL-ready bit → fake it: `mpc5567.repl` uses a tiny `Python.PythonPeripheral` returning `0x8` (the PPC analogue of the STM32 `RCC_CR` `Tag` in [doc 06 §6](06-generating-a-new-board.md#63-bring-up-aids-applysvd-tag-access-logging)).

### 4.SPARC (LEON) - scaffold `leon3.repl` · `gr716.repl` · `gr712rc.repl`
Top of file (from `leon3.repl`, verified):
```repl
sysbus:
    Endianess: Endianess.BigEndian
cpu: CPU.Sparc @ sysbus
    cpuType: "leon3"
mic: IRQControllers.GaislerMIC @ sysbus <0x80000200, +0x100>
    0 -> cpu@0 | cpu@1 | cpu@2
uart: UART.GaislerAPBUART @ sysbus <0x80000100, +0x100>
    -> mic@2
ahbInfo: Bus.GaislerAHBPlugAndPlayInfo @ sysbus <0xfffff000, +0xfff>
apbController: Bus.GaislerAPBController @ sysbus <0x800ff000, +0xfff>
```
- **Fetch:** the **Gaisler GRLIB IP Library User's Manual** (the register reference - there is **no SVD** for LEON): APB/AHB base addresses (the `0x80000xxx` APB region) and IRQ lines. With the bitstream, the GRLIB **AMBA plug-&-play** scan yields the real map.
- **Must-do:** big-endian bus; declare `GaislerMIC` **and** the plug-&-play bus objects (`Bus.GaislerAHBPlugAndPlayInfo`, `Bus.GaislerAPBController`) - firmware enumerates them. (`leon3.repl` even flags one IRQ line `// not verified` - confirm IRQs via the §6 loop.)

### 4.MSP430 - scaffold `msp430f2619.repl`
Top of file (from `msp430f2619.repl`, verified):
```repl
cpu: CPU.MSP430X @ sysbus
    cpuType: "msp430x"
timer_a: Timers.MSP430_Timer @ {
    sysbus <0x160, +0x20>;
    sysbus new Bus.BusMultiRegistration { address: 0x012E; size: 0x2; region: "interruptVector" }
}
    IRQ0 -> cpu@6                                  // vector wired straight to the CPU
    IRQ_IV -> cpu@7
```
- **Fetch:** the **TI SLAU-family User's Guide** (e.g. SLAU144 for MSP430x2xx) for the architecture + peripheral registers, and the **device datasheet** for which peripheral instances exist and at what addresses.
- **Must-do:** there is **no central interrupt controller** - every peripheral wires its vector straight to `cpu@N`. The SFRs (IE/IFG bytes at low fixed addresses) are **split** from the register block ⇒ map a peripheral at multiple points with `Bus.BusMultiRegistration`. Use `Memory.ArrayMemory` (not `MappedMemory`) for the tiny regions.

### 4.XTENSA - scaffold `xtensa-sample-controller.repl`
Top of file (verified - note the real comment is `//`):
```repl
// instram0, dataram0 and dataram1 are defined in 'core-isa.h'.
instram0: Memory.MappedMemory @ sysbus 0x40000000
    size: 0x20000
cpu: CPU.Xtensa @ sysbus
    cpuType: "sample_controller"                   // must match a core config Renode supports
    frequency: 100000000
uartSemihosting: UART.SemihostingUart @ cpu
```
- **Fetch:** **`core-isa.h`** - your Xtensa toolchain *generates* it for the configured core; it defines the RAM/instram regions and the reset vector. Plus the SoC integration doc for any peripherals around the core.
- **Must-do:** the core is **configurable**, so `cpuType` must name a configuration the Renode Xtensa core knows; take the memory regions from `core-isa.h`, not a datasheet.

### 4.UNKNOWN
> ⚠️ **First check whether the ISA is emulated at all.** This router (and doc 06) assumes a
> `CPU.<Arch>` core already exists - i.e. the ISA is one tlib can translate
> (`arm, arm-m, arm64, i386, x86_64, ppc, ppc64, riscv, riscv64, sparc, xtensa`). If your part's ISA
> is **not** in that set (e.g. MIPS), there is no core to instantiate and no scaffold will load -
> you must **port the architecture first**: see **[doc 08](08-porting-a-new-architecture.md)** (tlib
> guest frontend + `CPU.<Arch>` class + build wiring). Once `cpu: CPU.<Arch>` loads and steps,
> return here.

Pick the **nearest-ISA scaffold** from §3, then run the **full §6 over-fetch list** and lean hard on
the §6 load/boot loop - the loader's localized errors (doc 06 §6.2) will tell you what's missing.

---

## 5. STEP 4 - Fact→document map (F4/F5: identical for every family)

Once F1–F3 are sourced, fetch the human docs for the routing meshes and pick models. **This table does
not change with architecture** - it is the right-hand column of [doc 06 §2](06-generating-a-new-board.md#2-provenance-table-verified-against-stm32f103):

| Fact you still need | Document to fetch | Where in it |
|---|---|---|
| Memory-region map (flash/SRAM/external banks) | **Reference Manual** | "Memory map" chapter - *not* the SVD peripheral bases ([doc 06 §2](06-generating-a-new-board.md#2-provenance-table-verified-against-stm32f103) - FSMC bank `0x60000000` ≠ regs `0xA0000000`) |
| Interrupt **grouping / fan-in** (CombinedInput sizes, GIC SPI groups) | **Reference Manual** | vector-table / NVIC / GIC chapter |
| DMA request routing (which req → which channel) | **Reference Manual** | DMA request-mapping tables |
| GPIO **alternate-function mesh** | **Datasheet** | pin/alternate-function tables |
| AF silicon quirks (`invertedAFPins`) | **Datasheet / errata** | AF polarity / errata |
| System & SysTick **clock frequency** | **Datasheet** clock tree | max SYSCLK |
| **Which C# model** (F5) | **Renode catalog** | `ls …/Peripherals/<Category>/` + grep; read the class register map to confirm layout ([doc 06 §5](06-generating-a-new-board.md#5-the-model-matching-problem-which-categoryclass)) |

---

## 6. If unsure, over-fetch (the "don't pull punches" ladder)

When classification is ambiguous, the part is exotic, or docs are thin - **fetch all of these in parallel**
and reconcile. Redundancy is the point.

1. **Every machine-readable description that might exist**, in this order of trust:
   `vendor CMSIS-SVD` · `CMSIS .pack` (→ extract `*.svd`) · `device tree` (Linux `arch/*/boot/dts`, Zephyr `dts/`, U-Boot) · `SoC-generator CSR map` (LiteX `csr.json`) · `SystemRDL` (→ `tools/PeakRDL-repl`) · `vendor BSP/SDK headers` (`*xx.h`, `core-isa.h`, generated `soc.h`).
   > ⚠️ **Two SVD traps (verified on Shakti/Mindgrove).** (a) A repo literally named `<vendor>/CMSIS-SVD`
   > may be a **fork of the SVD *tooling*** (Open-CMSIS-Pack), containing only ARM test-fixture SVDs - not
   > a device SVD for the part. (b) A third-party SVD (e.g. platformio `platform-shakti`'s `vajra/parashu/
   > pinaka.svd`) may describe a **different variant of the same core family** - the generic FPGA SoC, with
   > *different bases* than the productized silicon. Never copy SVD bases without a **datasheet** cross-check;
   > MGS2401 has **no** real SVD at all, despite both repos existing.
2. **Both human docs, in full**: the **Reference Manual / TRM** *and* the **Datasheet** (+ **errata**). Many F4 facts live in only one of them. ⚠️ **Grep the PDF *text*, not just repos** - vendor *programming/API-reference* manuals sometimes **embed the device tree** (MGS2401's API Reference PDF contained the `clint`/`plic`/`gpio`/`uart` `.dtsi` nodes with `reg` + `interrupts`), so a PDF can be your machine-readable F1/F2 source.
3. **Vendor non-SVD register references** (HTML/PDF) for parts that have no SVD: AMD UG1087 (Zynq), Gaisler GRLIB manual (LEON), TI SLAU (MSP430).
4. **Reference firmware / HAL/SDK source** - the `#define`s and HAL busy-wait patterns reveal addresses and which clock-ready bits firmware spins on (→ doc 06 §6.3 `Tag`s). `ambiq-apollo4.repl` was matched to the SDK's `am_hal_*` source.
5. **The in-tree converters** (§7) - run them speculatively even if you'll hand-edit the output.
6. **The nearest sibling `.repl`** in `platforms/cpus/` (§3) - it already encodes a reverse-engineered layout; diff your facts against it.
7. **The chosen C# model's source** - its register enum is ground truth for F1 offsets (the §2.1 trap) and for property/ctor names (doc 06 §6.2).
8. **Run the §6 load→boot loop early and often** - Renode's localized load errors + access logs are themselves a "document" that tells you exactly what's still missing.

> Rule of thumb: it is always correct to additionally fetch **(a)** the device tree, **(b)** the Reference
> Manual, **(c)** the Datasheet, and **(d)** read the C# model you picked - those four cover F1–F5 for
> *any* architecture even when the architecture-specific machine-readable source is missing.

---

## 7. In-tree converters (fetch a tool, not just a doc)

Renode ships two generators under `renode/tools/` - prefer them for a first draft, then hand-fix:

| Tool | Input document | Output | Use for |
|---|---|---|---|
| **`tools/dts2repl`** | a (flattened) **device tree** - typically Zephyr's | a draft `.repl` | ARM-APP, RISCV-HARD, any Zephyr-supported board *(submodule; populate it in a full checkout)* |
| **`tools/PeakRDL-repl`** | a **SystemRDL** register model | a `.repl` | RISCV-SOFT / any RTL flow that emits SystemRDL (also `tools/PeakRDL-renode`) |

> These are exactly the "machine-readable source you actually have" made executable: a DTS or an RDL
> model *is* the F1/F2/F3 document; the converter saves you transcribing it by hand.

---

## 8. Worked routings (one line each)

- **New STM32 (Cortex-M):** scaffold `stm32f103.repl` → fetch the part **SVD** + **RM** + **DS** → models `STM32_*` → load/boot. *(CORTEX-M)*
- **New ZynqMP-class board (Cortex-A53):** scaffold `zynqmp.repl` → fetch the board **DTS** + **AMD UG1087** + TRM → `ARM_GenericInterruptController`, GIC auto-wires → load/boot. *(ARM-APP)*
- **New SiFive RISC-V SoC:** scaffold `sifive-fu540.repl` → fetch **DTS** (+ SVD if SiFive ships one) → `PLIC`+`CLINT`, `timeProvider: clint` → load/boot. *(RISCV-HARD)*
- **New LiteX soft-SoC:** scaffold `litex_vexriscv.repl` → fetch the build's **`csr.json`/generated headers** (or run `dts2repl`/`PeakRDL-repl`) → HDL-named models → §6 loop *is* the spec. *(RISCV-SOFT)*
- **New LEON/GR part:** scaffold `gr716.repl` → fetch **Gaisler GRLIB manual** → `GaislerMIC` → load/boot. *(SPARC)*
- **New Shakti C-class vendor MCU (Mindgrove MGS2401, no SVD):** scaffold `sifive-fe310.repl` → fetch the **datasheet memory map** (all bases/sizes) + the **BSP `platform.h`** (authoritative PLIC IRQ table) + the **API-reference PDF's embedded DTS** (CLINT/PLIC wiring: `cpu@[3,7]`/`cpu@[11,9]`, 2 contexts) → core (`RiscV64`+`CoreLevelInterruptor`+`PlatformLevelInterruptController`+RAM) on real models, **every Shakti peripheral `Tag`-ged** (no models exist) → §6 load+step loop. Watch the FPGA-vs-silicon clock/RAM skew ([doc 06 §7](06-generating-a-new-board.md#7-pitfalls--pre-flight-checklist)). *(RISCV-HARD)*

---

## Evidence appendix

All routing facts above were mined from the two source trees (not memory). Reproduce:

```bash
cd renode/platforms/cpus
grep -rhoE 'CPU\.[A-Za-z0-9_]+' *.repl | sort | uniq -c | sort -rn          # core/arch distribution
grep -rhoE 'IRQControllers\.[A-Za-z0-9_]+' *.repl | sort | uniq -c | sort -rn # interrupt-controller per family
grep -rl 'ApplySVD' *.repl                                                    # the 15 SVD-using repls
grep -rinE '//.*(based on|taken from|device.?tree|auto-generated|core-isa|zephyr|https?://)' *.repl  # provenance comments
ls ../../tools | grep -iE 'repl|dts|rdl'                                      # in-tree converters
```

**What the mine returned (verified):**
- **Core distribution (118 repls):** Cortex-M 42 · RISC-V (RiscV64 19, VexRiscv 14, RiscV32 6, IbexRiscV32 2, PicoRV32 2, Minerva/Ri5cy/VeeR_EL2/CV32E40P 1 each) · Arm-app (ARMv8A 16, ARMv7A 13, ARMv7R 6, ARMv8R 5, CortexA7 1) · x86 (X86_64 3, X86 2, +KVM) · SPARC 3 · PowerPC 3 · Xtensa 1 · MSP430X 1.
- **Interrupt controller → family (1:1):** `NVIC` 42 (Cortex-M) · `ARM_GenericInterruptController`(+redistributor) 17/24 (Arm-app) · `PlatformLevelInterruptController` 11 + `CoreLevelInterruptor` 12 (RISC-V) · `LAPIC` 5/`IOAPIC` 1 (x86) · `GaislerMIC` 3 (SPARC) · `MPC5567_INTC` 1 (PPC) · plus soft-SoC custom (`OpenTitan_*`, `AndesNCEPLIC100`, `MiV_CoreLevelInterruptor`, `VeeR_EL2_PIC`, `PULP_*`).
- **The 15 SVD repls:** 14 Cortex-M (ST `stm32*`/`stm32w108`, Nordic `nrf52840`, NXP `nxp-k6xf`/`s32k118`, Microchip `sam_e70`, Maxim `max32652`) **+ 1 RISC-V (`sifive-fe310`)** - see [doc 06 §9](06-generating-a-new-board.md#9-vendor--architecture-adaptations).
- **Real provenance citations** (the substitute-source evidence): `opentitan-earlgrey.repl` "Auto-generated … commit f243e680…" · `sifive-fu540.repl` "address … taken from the device tree" · `litex_vexriscv_zephyr.repl` ← `riscv32-litex-vexriscv.dtsi` · `mimxrt798s.repl` ← Zephyr MCUX `MIMXRT798S_cm33_core[01].h` · `fomu.repl` ← LiteX generated headers · `xtensa-sample-controller.repl` ← `core-isa.h` · `zynqmp.repl` ← AMD UG1087 · `ambiq-apollo4.repl` ← SDK `am_hal_*`.
- **In-tree converters:** `tools/dts2repl` (DTS→repl), `tools/PeakRDL-repl` + `tools/PeakRDL-renode` (SystemRDL→repl).

> **Caveat (same as doc 06):** `dotnet`/Renode were not built in this environment, so the STEP 6
> load/boot loop is documented but not executed here. Everything in §2–§5 and this appendix is
> verified against the `renode`/`renode-infrastructure` source trees and the live SVDs.

---

See also: [00 (overview)](00-overview.md) · [06 (generating a board)](06-generating-a-new-board.md) ·
[01 (`.repl`)](01-repl-format.md) · [03 (C# peripherals)](03-csharp-peripherals.md) ·
[05 (cheatsheet)](05-cheatsheet.md).
