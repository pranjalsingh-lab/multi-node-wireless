# 08 - Porting a New CPU Architecture (when there is no `CPU.<Arch>` core at all)

> **Where this sits.** [Doc 07](07-source-router.md) routes a new *chip* onto an ISA Renode
> *already emulates* (Cortex-M, ARM-app, RISC-V, x86, SPARC, PowerPC, MSP430, Xtensa). This doc is
> the **layer beneath**: what to do when the **instruction set itself is missing** - there is no
> `CPU.<Arch>` C# class and no native translator, so the very first line doc 06/07 emit
> (`cpu: CPU.<Arch> @ sysbus … cpuType: "…"`) fails to resolve. The **output of this doc is a
> working `CPU.<Arch>`** that doc 06/07 can then build a platform on. After it loads and steps
> instructions, you re-enter doc 07 → doc 06 for the chip and board.
>
> A `.repl` is only a wiring diagram (docs 00–04); it can name a CPU but cannot *execute* an
> instruction set. Executing instructions is what this doc builds.

**Honesty note (read first).** The C#/binding/build/register/repl claims here are verified against
the **`renode`** and **`renode-infrastructure`** source trees (the same revisions as the rest of
this set; citations are `path:line`). The **tlib** (native translator) claims are verified against a
fresh clone of **`github.com/antmicro/tlib`** (master `64fe457d`, 2026‑06‑25) - because the tlib
submodule is *not populated* in this working tree. The **QEMU** concepts (which ground *what you
write inside* the native frontend) are cited to the official docs at `qemu.org/docs/master/devel/…`.
**No `dotnet`/CMake build was run and no port was compiled or executed here** - the build/verify
commands in §10 are exact but unexecuted. Antmicro itself confirms there is **no official guide** for
this: in `github.com/renode/renode/issues/384` a maintainer says *“We do not have specific
documentation covering this topic,”* pointing implementers at `TranslationCPU.cs`/`ExternalCPU.cs` +
`NativeBinder.cs`. This doc is the missing guide, reconstructed from source.

**Authoritative sources**
- C# CPU base + binding + registers (**`renode-infrastructure`** tree):
  `src/Emulator/Peripherals/Peripherals/CPU/{BaseCPU,TranslationCPU}.cs`,
  `src/Emulator/Main/Utilities/Binding/{NativeBinder,ImportAttribute,ExportAttribute}.cs`,
  `src/Emulator/Cores/<Arch>/*.cs`, `src/Emulator/Cores/Common/RegisterTemplate.tt`.
- Native translator: the **tlib** submodule `src/Emulator/Cores/tlib` (`github.com/antmicro/tlib`),
  plus the Renode C glue `src/Emulator/Cores/renode/`.
- Build: `build.sh` and `tools/building/regenerate_registers.sh` (**`renode`** tree),
  `src/Emulator/Cores/CMakeLists.txt` (**`renode-infrastructure`** tree).
- QEMU concepts: `qemu.org/docs/master/devel/{tcg,tcg-ops,decodetree}.html`.

---

## 1. First decide: do you even need a tlib port?

A full tlib port is the **biggest** task in Renode - it is porting a dynamic binary translator
frontend. Before committing, check the three cheaper options. Not every Renode CPU is tlib-backed:
`MSP430X` and `ExternalCPU` derive straight from `BaseCPU`, not `TranslationCPU`.

| Option | What it is | When to choose | Cost |
|---|---|---|---|
| **A. Port into tlib** (this doc) | Write a guest frontend in the C translator; get a fast, native, fully‑integrated `CPU.<Arch>` | You need a *production* core: speed, GDB, hooks, MMU, snapshots, many chips on this ISA | **Weeks.** A real DBT frontend port |
| **B. External / co‑simulation CPU** | `ExternalCPU : BaseCPU` drives an *external* instruction-set simulator or RTL (Verilator) over a socket/native lib | You already have an ISS or RTL, or you only need a few cores and can tolerate slower speed | Moderate; no DBT work. See `src/Emulator/Peripherals/Peripherals/CPU/ExternalCPU.cs:20` and Antmicro’s co‑sim post (`antmicro.com/blog/2023/01/cpu-rtl-co-simulation-in-renode`) |
| **C. KVM passthrough** | `KVMCPU` runs the guest on the host CPU | The guest ISA == host ISA (x86‑on‑x86) | Host‑only; not an emulation port. `src/Emulator/Cores/KVM/` |

**Decision rule.** Is your ISA already in tlib’s `TARGET_ARCH` list
(`i386 x86_64 arm arm-m arm64 sparc ppc ppc64 riscv riscv64 xtensa`)? If **yes** → you don’t need
this doc; go to [doc 07](07-source-router.md). If **no** and you want a first‑class core → continue
with Option A below. If you have RTL/an ISS and want it running fast → Option B (and stop here).

The rest of this doc is Option A. It has **five deliverables**, in dependency order:
1. a **tlib guest frontend** (`tlib/arch/<isa>/…`) - native, the hard part (§4),
2. the **Renode C glue** (`renode/arch/<isa>/…`) - native, small (§5),
3. the **managed `CPU.<Arch>`** class (§6),
4. its **register table** via T4 (§7),
5. the **build wiring** so a `translate-<arch>-<endian>.so` is produced (§8).

---

## 2. Anatomy of a Renode tlib core (verified)

Every tlib-backed CPU is **two artifacts** that meet at a name-mangled C ABI:

```
   ┌─────────────────────────────┐  managed → native (P/Invoke)   ┌──────────────────────────────┐
   │  C#  CPU.<Arch> : TranslationCPU  ── [Import] Tlib*  ────────► │  native  translate-<arch>-     │
   │  (renode-infrastructure)    │       (tlib_*_ex symbols)       │  <endian>.so   (tlib + glue)   │
   │                             │ ◄──── [Export] callbacks ────── │                                │
   │  Architecture, GDBArch,     │   (renode_external_attach__*)   │  guest decode → TCG IR →        │
   │  DecodeInterrupt, registers │                                 │  host code; soft-MMU; no devices│
   └─────────────────────────────┘                                 └──────────────────────────────┘
            ▲                                                                  │
            │ resolved by TypeManager from ".repl" (doc 04)                    │ all MMIO / RAM access is a
            │ cpu: CPU.<Arch> @ sysbus ; cpuType: "..."                        │ CALLBACK into the manager
            ▼                                                                  ▼
     the platform (docs 06/07)                                         sysbus / peripherals (doc 03)
```

**Class hierarchy:** `CPUCore` → `BaseCPU` (abstract) → `TranslationCPU` (abstract; the tlib base) →
your concrete `CPU.<Arch>`. (`BaseCPU.cs:34`, `TranslationCPU.cs:57`.)

**Runtime load path (verified, `TranslationCPU.cs`):**
1. `Init()` computes the library name from the abstract `Architecture` property and endianness -
   `var endianSuffix = (Endianness == Endianess.BigEndian || Architecture.StartsWith("ppc")) ? "be" : "le";`
   then `libraryFile = PlatformFileLoader.CopyPlatformFile($"translate-{Architecture}-{endianSuffix}.so");`
   (`:1634-1636`). PowerPC is forced big‑endian; the `.so` is **copied per instance** (tlib keeps
   one global `CPUState` per loaded library, so each CPU gets its own copy).
2. `binder = new NativeBinder(this, libraryFile);` (`:1638`) wires every `[Import]`/`[Export]`.
3. `var result = TlibInit(Model); if(result == -1) throw new ConstructionException("Unknown CPU type");`
   (`:1648`) - **this is where the `cpuType` string enters tlib**. `Model` is the `cpuType`.
4. `PlatformFileLoader` finds the `.so` at `platform-lib/<RID>/translate-<arch>-<endian>.so` next to
   the assembly (`PlatformFileLoader.cs:40-54`; `<RID>` = .NET runtime id, e.g. `linux-x64`).

So three strings must agree end-to-end: the C# `Architecture` property, the `TARGET_ARCH` you build
tlib with, and the `.so` filename. For `mips` they are all `mips`.

---

## 3. The managed↔native ABI (the contract, both directions)

`NativeBinder` (`src/Emulator/Main/Utilities/Binding/NativeBinder.cs`) binds two opposite flows by
**reflection over attributes**, converting names with `GetCName` (CamelCase→snake_case, `:107-119`):

### 3.1 manager → tlib: `[Import]` fields (you *call* tlib)
A `[Import] private readonly Action<…>/Func<…>` field is left null in C#; the binder resolves it to a
native symbol and fills it. Name mapping: `GetCName(field)` then, if
`ImportAttribute.UseExceptionWrapper` is true (the **default**, `ImportAttribute.cs:19`), append
`_ex` (`GetWrappedName`, `NativeBinder.cs:121-125`). So `TlibInit` → **`tlib_init_ex`**,
`TlibSetIrq` → `tlib_set_irq_ex`. The `_ex` variants are exception-safe wrappers tlib generates from
`include/unwind.h` (`EXC_*` macros) so a C# exception thrown inside a callback survives the round
trip. These `tlib_*` symbols are tlib’s **public C ABI**, declared in tlib `include/exports.h`:

| tlib symbol (C ABI) | Purpose |
|---|---|
| `tlib_init(cpu_name)` | construct the CPU model named `cpu_name` (the `cpuType`); returns −1 if unknown |
| `tlib_execute(max_insns)` | run a quantum of instructions |
| `tlib_reset` / `tlib_set_irq(line, state)` | reset; raise/lower an interrupt line |
| `tlib_map_range` / `tlib_unmap_range` | tell tlib which guest ranges are direct RAM (fast path) vs callback (MMIO) |
| `tlib_get_register_value` / `tlib_set_register_value` | register file access (drives §7) |
| `tlib_translate_to_physical_address` | MMU query |
| `tlib_add_breakpoint`, `tlib_export_state` / `tlib_before_save` / `tlib_after_load` | debug; snapshots |

(`TranslationCPU` has ~78 such fields; e.g. `TlibInit` is `Func<string,int>` at
`TranslationCPU.cs:2209`, `TlibSetIrq` is `Action<int,int>` at `:2287`.)

### 3.2 tlib → manager: `[Export]` methods (tlib *calls* you)
Everything tlib can’t do itself - **every RAM/MMIO access, logging, allocation, block hooks,
interrupt queries** - is a callback into the manager. A `[Export]` method on the C# core is matched
to a native “attacher” symbol named `renode_external_attach__…` that the binder calls to register the
managed delegate (`NativeBinder.cs:411-466`). The C side declares these with the `EXTERNAL_AS`
macro (`renode/include/renode_imports.h:110-133`):

```
EXTERNAL_AS(RETURN_TYPE, CSharpMethodName, tlib_c_name, arg_types...)
```

which generates (a) a function pointer the manager fills, (b) the `tlib_c_name(...)` trampoline tlib
actually calls (followed by `tlib_try_interrupt_translation_block()`), and (c) the
`renode_external_attach__…` registration symbol. Two layers of these:

- **Common** (arch‑independent), in `renode/renode_callbacks.c` - bound to base‑class `[Export]`s:
  `tlib_read_byte/word/double_word/quad_word` ↔ `Read*FromBus`,
  `tlib_write_*` ↔ `Write*ToBus`, `tlib_log` ↔ `LogAsCpu`, `tlib_abort` ↔ `ReportAbort`,
  `tlib_allocate/reallocate/free`, `tlib_on_block_begin/finished`,
  `tlib_on_interrupt_begin/end`, `tlib_on_memory_access`, `tlib_get_mp_index`,
  `tlib_get_total_elapsed_cycles`, … (`renode_callbacks.c:32-86`). **You write none of these** - they
  exist for every arch.
- **Arch‑specific**, in `renode/arch/<arch>/renode_<arch>_callbacks.c` - bound to *your* subclass’s
  `[Export]`s. Example (SPARC, `renode/arch/sparc/renode_sparc_callbacks.c:12-15`):
  `EXTERNAL_AS(int32_t, FindBestInterrupt, tlib_find_best_interrupt)` and three more - which
  correspond **exactly** to the `[Export]` methods in `Sparc.cs:163-207`
  (`FindBestInterrupt`, `AcknowledgeInterrupt`, `OnCpuHalted`, `OnCpuPowerDown`).

> **The rule of thumb:** any callback your guest core needs *from* the manager that isn’t already in
> `renode_callbacks.c` is a pair you add: a `[Export]` method (C#, §6) **and** an `EXTERNAL_AS` line
> (C glue, §5). Anything you need to *push into* tlib is an `[Import]` field (C#) backed by a
> `tlib_*` function (native, §4).

---

## 4. Deliverable 1 - the tlib guest frontend (native; the hard part)

### 4.1 What tlib is
tlib is Antmicro’s **LGPL fork of QEMU’s TCG** (Tiny Code Generator). It is a *library*: builds to one
`.so` per guest, **system‑mode / soft‑MMU only**, with **no devices, no boards, no UI** - every access
to non‑RAM is a callback (§3.2). Host JIT backends (`tcg/{i386,arm,aarch64}`) lower the
target‑independent TCG IR to host code. **Consequence:** porting a *guest* needs **no host codegen** -
you write decode + semantics, not machine‑code emission. (This is an inference from two documented
facts: the guest/target split, `qemu.org/docs/master/devel/tcg-ops.html`, and host‑code isolation in
`tcg-target.c.inc`; the existing tlib host backends already cover x86‑64/arm64 dev machines.)

> ⚠️ **Version skew.** tlib forked QEMU *years* ago, so its frontends use the **classic
> (pre‑decodetree, pre‑QOM) QEMU target layout** - `translate.c` + `cpu.h` + `op_helper.c` +
> `cpu_registers.c`, **not** modern QEMU’s `*.decode` / `TCGCPUOps` / QOM machinery. Use modern
> `qemu.org` docs to *understand the concepts*, but mirror an **existing tlib `arch/` dir** for the
> concrete structure, and port instruction *semantics* from a QEMU `target/<isa>` of a comparable
> vintage. Don’t expect tlib internals to match current QEMU file paths.

### 4.2 Dynamic binary translation in one paragraph
On first execution of a guest code region, the translator decodes guest instructions into TCG IR ops
and the IR is compiled to host code, cached as a **Translation Block (TB)** indexed by **physical**
address; TBs are chained so execution stays in native code
(`qemu.org/docs/master/devel/tcg.html`). The soft‑MMU resolves guest→host addresses through a
per‑CPU **TLB**; a miss calls a target fill hook that walks the page tables/TLB and installs the
mapping (`devel/tcg.html`, “MMU emulation”). Instructions too complex for IR call **helper**
functions written in C (`devel/tcg-ops.html`). Your frontend supplies: the decoder, the IR emitters,
the helpers, the CPU state, the MMU walk, exception/interrupt entry, and register access.

### 4.3 The per‑arch file contract (verified against the tlib clone)
Existing `tlib/arch/` dirs: `arm, arm64, arm_common, i386, ppc, riscv, sparc, xtensa`. The **smallest**
complete port (SPARC) shows the minimum file set; create `tlib/arch/<isa>/` with these:

| File | Role | QEMU analogue (concept) |
|---|---|---|
| `cpu.h` | The `CPUState` struct (registers, flags, MMU/TLB, pending‑exception fields) + arch constants | `target/<a>/cpu.h` (`CPUArchState`) |
| `translate.c` | The **decoder + TCG IR emitters** - the bulk of the work; turns guest instructions into ops | `target/<a>/translate.c` (`translator_loop`) |
| `op_helper.c` / `helper.c` (+ `helper.h`) | C **helper functions** for complex ops, plus exception entry (`do_interrupt`) and the soft‑MMU **`tlb_fill`** / page‑table walk | `target/<a>/*_helper.c`, `DEF_HELPER_*` |
| `cpu_registers.h` / `cpu_registers.c` | The **register ID enum + get/set** that the C# register table (§7) and GDB read; `cpu_registers.h` is consumed directly by the T4 template | `target/<a>/gdbstub.c` + reg defs |
| `arch_exports.c` / `arch_exports.h` | tlib‑specific functions this arch exports to the manager (the `tlib_*` you `[Import]`, beyond the common ABI) | - (tlib‑specific) |
| `arch_callbacks.c` / `arch_callbacks.h` | tlib‑specific callback *declarations* this arch calls back into the manager (paired with §5) | - (tlib‑specific) |

Bigger ISAs add more (`*_helper.c` per unit, FP via the bundled `softfloat-2`/`softfloat-3`, decode
tables). Practical path: **copy the closest existing `arch/` dir** (for MIPS: a 32/64‑bit, GPR‑based,
software‑TLB ISA - structurally close to `sparc`/older `riscv`), then replace the decode/semantics
from a QEMU `target/mips`.

### 4.4 What lives inside, by concern (map to your work)
- **CPU state & registers** - define the `CPUState` and the `cpu_registers.h` IDs; implement
  `tlib_get_register_value`/`tlib_set_register_value`. The IDs you pick here are the contract for §7.
- **Decode + translate** - `translate.c`: for each instruction, emit TCG ops (or a helper call).
  Concepts: `qemu.org/docs/master/devel/{tcg-ops,decodetree}.html`.
- **Memory / MMU** - implement the soft‑MMU fill (page‑table or TLB walk) so guest virtual addresses
  resolve; RAM reads/writes go fast‑path, MMIO falls through to the `tlib_read_*`/`tlib_write_*`
  callbacks (§3.2). (QEMU concept: `tlb_fill` + `get_phys_addr`, `devel/tcg.html`.)
- **Exceptions & interrupts** - set the pending‑exception field and enter the handler on traps; accept
  external IRQs through `tlib_set_irq` and deliver them at instruction boundaries. The C# side maps a
  GPIO line to your interrupt model via `DecodeInterrupt` (§6).
- **CPU models / `cpuType`** - `tlib_init(name)` must recognize each `cpuType` string and configure
  the variant (and return −1 otherwise - that −1 is what surfaces as “Unknown CPU type” at
  `TranslationCPU.cs:1648`). For an ISA-string style (like RISC‑V `rv64gc…`) parse it here or in C#
  (`BaseRiscV`’s `ArchitectureDecoder`, `RiscV/BaseRiscV.cs:1426`, is the in‑tree precedent).
- **CMake registration** - add `<isa>` (and `<isa>64` if applicable) to tlib’s `CMakeLists.txt`
  `TARGET_ARCH` list and set its `TARGET_ACTUAL_ARCH` (most map 1:1; the established remaps are
  `arm-m→arm`, `x86_64→i386`, `ppc64→ppc`, `riscv64→riscv`). The top‑level Cores CMake globs
  `renode/arch/${TARGET_ACTUAL_ARCH}/*.c` (`CMakeLists.txt`), so the glue dir name (§5) must match
  `TARGET_ACTUAL_ARCH`.

---

## 5. Deliverable 2 - the Renode C glue (`renode/arch/<arch>/`)

Small and mechanical. Create `src/Emulator/Cores/renode/arch/<arch>/renode_<arch>_callbacks.c` and,
for each arch‑specific `[Export]` your C# core declares (§6), add one `EXTERNAL_AS` line mapping the
C# method name to the `tlib_*` name your frontend calls. Pattern (verbatim shape from SPARC):

```c
#include "renode_imports.h"

EXTERNAL_AS(int32_t, FindBestInterrupt,    tlib_find_best_interrupt)
EXTERNAL_AS(void,    AcknowledgeInterrupt, tlib_acknowledge_interrupt, int32_t)
EXTERNAL_AS(void,    OnCpuHalted,          tlib_on_cpu_halted)
```

The Cores `CMakeLists.txt` automatically compiles `renode/arch/${TARGET_ACTUAL_ARCH}/*.c` into the
tlib target and renames the output `translate-${TARGET_ARCH}-${ENDIAN_STR}.so`
(`CMakeLists.txt:37`). The arch‑independent callbacks (bus, log, alloc, …) are already provided by
`renode/renode_callbacks.c` - **don’t re‑declare them.**

---

## 6. Deliverable 3 - the managed `CPU.<Arch>` class

This is small (SPARC is ~290 lines, most of it an exception‑name table). It lives in
`src/Emulator/Cores/<Arch>/<Arch>.cs`, namespace `Antmicro.Renode.Peripherals.CPU` → so the `.repl`
references it as `CPU.<Arch>` (the namespace↔category rule, [doc 03 §7](03-csharp-peripherals.md)).
Skeleton, annotated against the verified `Sparc.cs`:

```csharp
namespace Antmicro.Renode.Peripherals.CPU
{
    [GPIO(NumberOfInputs = N)]                                   // # of incoming IRQ lines (Sparc.cs:22)
    public partial class Mips : TranslationCPU                   // 'partial' - registers are generated (§7)
    {
        public Mips(string cpuType, IMachine machine, Endianess endianness = Endianess.LittleEndian)
            : base(cpuType, machine, endianness) { }            // ctor shape: Sparc.cs:25

        // --- the abstract surface a TranslationCPU MUST implement ---
        public override string Architecture => "mips";          // DRIVES the .so name (Sparc.cs:78)
        public override string GDBArchitecture => "mips";       // a name GDB understands (§9)
        public override List<GDBFeatureDescriptor> GDBFeatures => new();   // register XML features (§9)
        public override string[] AllLLVMTriples => new[]{ "mips" };        // on-board disassembler
        public override string LLVMModel => Model;
        public override string GetLLVMTriple(uint flags) => AllLLVMTriples[0];
        public override Endianess DisassemblyHexFormatting => Endianness;

        protected override Interrupt DecodeInterrupt(int number) // GPIO line -> interrupt model
            => number == 0 ? Interrupt.Hard : throw InvalidInterruptNumberException;  // Sparc.cs:141

        // --- arch-specific callbacks (each pairs with an EXTERNAL_AS in §5) ---
        [Export] private void OnCpuHalted() => IsHalted = true;  // tlib calls this (Sparc.cs:197)

        // --- arch-specific calls into tlib (each backed by a tlib_* symbol in §4) ---
#pragma warning disable 649
        [Import] private readonly Action<uint> TlibSetEntryPoint; // -> tlib_set_entry_point_ex (Sparc.cs:261)
#pragma warning restore 649
    }
}
```

**Abstract members you must provide** (compiler will tell you): from `BaseCPU` - `Architecture`
(`BaseCPU.cs:347`); from `TranslationCPU` - `SetRegister`/`GetRegister`/`GetRegisters`
(`:810-814`, **generated in §7**), `GetLLVMTriple` (`:816`), `GDBFeatures`/`GDBArchitecture`
(`:1056-1058`), `AllLLVMTriples`/`LLVMModel` (`:1060-1062`), `DisassemblyHexFormatting` (`:1064`),
and `DecodeInterrupt` (`:1444`). `ExecuteInstructions`, `PC`, `ExecutedInstructions` are already
implemented by `TranslationCPU` over tlib - you do **not** override them.

**Interrupt flow (verified).** A platform wires `something -> cpu@k`; that calls
`TranslationCPU.OnGPIO(k, value)` (`:388`) → `TlibSetIrqWrapped` (`:400`) → **your**
`DecodeInterrupt(k)` (`:1558`) which maps the GPIO line index to an arch interrupt enum →
`TlibSetIrq((int)decoded, 0/1)` (`:1568-1575`) → tlib delivers it (§4.4). So `DecodeInterrupt` is the
one piece of interrupt policy you must write; everything else is plumbing.

---

## 7. Deliverable 4 - registers (T4 generation)

The `<Arch>Registers.cs` half of the `partial class` is **generated**, not hand‑written. Author a tiny
T4 template `src/Emulator/Cores/<Arch>/<Arch>Registers.tt` (verified shape, `SparcRegisters.tt`):

```
<#@ template language="C#" #>
<#@ include file="../Common/RegisterTemplateDefinitions.tt" #>
<#
    CLASS_NAME = "Mips";
    HEADER_FILE = "Emulator/Cores/tlib/arch/mips/cpu_registers.h";   // tlib reg IDs (from §4)
    DEFINES.Add("TARGET_MIPS");
    AFTER_WRITE_HOOKS.Add("PC", "AfterPCSet");                       // optional C# hook on a reg write
    GENERAL_REGISTERS.AddRange(new[] { "R0", /* … */ "PC", "HI", "LO" });
#>
<#@ include file="../Common/RegisterTemplate.tt" #>
```

`RegisterTemplate.tt` then emits the `<Arch>Registers` enum, the `SetRegister`/`GetRegister`/
`GetRegisters` overrides, the `[Register]`‑attributed named properties, and the width‑specific
`[Import]` accessors `SetRegisterValueNN`/`GetRegisterValueNN` (→ tlib `set_register_value_NN`)
(`RegisterTemplate.tt:320,323`; generated example `SparcRegisters.cs:23,33,42,237`). The register
**IDs must match `tlib/arch/<isa>/cpu_registers.h`** - that header is the single source of truth
shared by C and C#.

**Regenerate** with `dotnet-t4` (`tools/building/regenerate_registers.sh`): install it
(`dotnet tool install -g dotnet-t4`), add `<Arch>/<Arch>` to the script’s `FILES` array, and run it -
it produces `<Arch>Registers.cs` next to the `.tt`. (Recent commit
`31b49ca7 [DEV] regenerate_registers: Improve behavior without dotnet-t4 installed` touches exactly
this path.)

---

## 8. Deliverable 5 - build wiring (produce `translate-<arch>-<endian>.so`)

Add your arch to the **build matrix** in `build.sh:413` (the comment above it says exactly this):

```bash
# This list contains all cores that will be built.
# If you are adding a new core or endianness add it here to have the correct tlib built
CORES=(arm.le arm.be … sparc.le sparc.be xtensa.le  mips.le mips.be)   # <-- add mips.le / mips.be
```

For each entry `build_core` (`build.sh:444-478`) runs CMake with
`-DTARGET_ARCH=<arch> -DTARGET_WORD_SIZE=<32|64>` (64 inferred if the name contains `64`),
`-DTARGET_WORDS_BIGENDIAN=1` for `.be`, and `-DHOST_ARCH=$HOST_ARCH` (the TCG **host** backend,
default `i386`, also `aarch64` - target‑independent, §4.1). The built `tlib/*.so` is copied to
`bin/<config>/<RID>` (`:471-472`) and packaged to `platform-lib/<RID>/` where `PlatformFileLoader`
finds it at runtime (§2). For fast native‑only iteration:
`./build.sh --external-lib-only --external-lib-arch mips` (flags at `build.sh:52,71`).

Bitness/endianness gotchas: a bi‑endian ISA (MIPS) needs **both** `mips.le` and `mips.be`; a 64‑bit
variant is a separate entry (`mips64.le`/`mips64.be`) and a separate C# class with
`Architecture => "mips64"` (mirroring `riscv`/`riscv64`).

---

## 9. GDB & disassembly

Three abstract properties tie your core to the debugger and the on‑board disassembler:
- **`GDBArchitecture`** must be a BFD architecture name GDB recognizes for your ISA (QEMU’s names are
  the reference set, e.g. `riscv:rv64`, `arm`, `aarch64`, `i386:x86-64`, `powerpc:common` -
  `qemu.org` `target/*/gdbstub.c`). For MIPS, `mips`.
- **`GDBFeatures`** returns register‑group descriptors (the equivalent of GDB target‑description XML,
  feature names like `org.gnu.gdb.mips.cpu`). Returning an empty list (as SPARC does, `Sparc.cs:82`)
  is acceptable to start - core registers still work via the generated `GetRegisters`.
- **`AllLLVMTriples`/`LLVMModel`/`GetLLVMTriple`** select the LLVM disassembler used for tracing and
  the monitor’s disassembly. Use a triple LLVM supports for the ISA.

Renode can also debug the **native** core itself: build tlib in debug and use the “Tlib Attach” GDB
flow (`renode.readthedocs.io/en/latest/introduction/developing-renode.html`); building tlib with
`--tlib-export-compile-commands` yields `compile_commands.json` for clangd.

---

## 10. Verification loop (build → step → boot → hand off)

1. **Build native only:** `./build.sh --external-lib-only --external-lib-arch mips` → expect
   `translate-mips-le.so` (and `-be`). Compilation errors here are pure C/tlib problems.
2. **Minimal load test** (the doc 06 §6.1 oracle - `CreationDriver` validates types/ctors/regs):
   ```bash
   renode --console --disable-xwt -e \
     "mach create; machine LoadPlatformDescriptionFromString \
      \"cpu: CPU.Mips @ sysbus { cpuType: \\\"<a-model-your-tlib_init-knows>\\\" }; \
        mem: Memory.MappedMemory @ sysbus 0x0 { size: 0x10000 }\"; quit"
   ```
   - “Could not resolve type `CPU.Mips`” ⇒ the C# class/assembly isn’t built (§6).
   - “Unknown CPU type” ⇒ class loads and the `.so` bound, but `tlib_init` rejected the `cpuType`
     (§4.4) - your model table.
   - Clean exit ⇒ the core instantiates.
3. **Single‑step sanity:** load a handful of hand‑assembled instructions, `cpu Step`, and check `cpu
   PC` and registers advance as expected. This exercises decode + register access end‑to‑end.
4. **Differential test vs QEMU:** Renode ships `tools/gdb_compare` - run the same program in Renode
   and in QEMU‑for‑MIPS under GDB and diff register state per step. This is the highest‑signal way to
   shake out decode/semantics bugs.
5. **Boot a real firmware**, then turn on `sysbus LogAllPeripheralsAccess true` + `logLevel -1` and
   iterate on MMU/exception fidelity (doc 06 §6.3/§6.4).
6. **Hand off:** once the core steps and boots, the ISA exists. Re‑enter [doc 07](07-source-router.md)
   to source the chip’s bases/IRQs and [doc 06](06-generating-a-new-board.md) to assemble and verify
   the platform - exactly as for any supported ISA.

---

## 11. Worked example - MIPS from scratch

Mapping every deliverable to MIPS (the canonical gap: PIC32 / embedded‑Linux / OpenWrt silicon, and
the one mainstream ISA Renode lacks while QEMU has a mature `target/mips`):

| Step | MIPS specifics |
|---|---|
| **§4 tlib frontend** | `tlib/arch/mips/`: copy the structure of a GPR‑based, software‑TLB arch dir (sparc/older‑riscv shaped); port decode + semantics from QEMU `target/mips`. Implement the **CP0** coprocessor, the **software‑managed TLB** (`tlb_fill` walks/loads TLB entries, *not* a hardware page‑table walk), the exception model, and the FPU (via bundled softfloat). **Bi‑endian:** MIPS runs both - so build *both* `.le` and `.be`. |
| **§4 cpuType** | `tlib_init` recognizes the variants you target (e.g. a 24Kc/microAptiv‑class for PIC32; a generic `mips32r2`/`mips64r2`). Return −1 for unknown. |
| **§4 registers** | `tlib/arch/mips/cpu_registers.h`: the 32 GPRs, `PC`, `HI`/`LO`, and the CP0 registers you expose to GDB. |
| **§5 C glue** | `renode/arch/mips/renode_mips_callbacks.c` with `EXTERNAL_AS` lines for any MIPS‑specific `[Export]`s (e.g. interrupt acknowledge, if you model an external INTC handshake like SPARC’s). |
| **§6 C# class** | `src/Emulator/Cores/MIPS/Mips.cs`: `Architecture => "mips"` (and a separate `Mips64` ⇒ `"mips64"` if needed), constructor `(cpuType, machine, endianness)`, `DecodeInterrupt` mapping CPU IRQ lines (MIPS has a small set of hardware interrupt lines in CP0 `Cause`/`Status`), `GDBArchitecture => "mips"`. |
| **§7 registers (C#)** | `MIPS/Mips.tt` with `CLASS_NAME="Mips"`, `HEADER_FILE=".../tlib/arch/mips/cpu_registers.h"`, `DEFINES.Add("TARGET_MIPS")`, the GPR/PC/HI/LO list; add `MIPS/Mips` to `regenerate_registers.sh` FILES; run `t4`. |
| **§8 build** | add `mips.le mips.be` (and `mips64.le mips64.be`) to `build.sh:413`. |
| **§10 verify** | step a MIPS test program; `gdb_compare` against QEMU‑mips; boot a PIC32 or MIPS‑Linux image. |
| **then docs 06/07** | route the chip (PIC32 → vendor headers/RM; a MIPS‑Linux SoC → its device tree), instantiate UART/timer/INTC, run the load→boot loop. |

The trickiest MIPS‑specific pieces are the **CP0 + software TLB** (different from ARM/RISC‑V hardware
walkers), **bi‑endianness** (two libraries, and the C# `Endianess` argument is meaningful), and the
**branch‑delay slot** in decode. None require host‑backend work.

---

## 12. Pitfalls & pre‑flight checklist

**Pitfalls**
- The three names must match: C# `Architecture`, CMake `TARGET_ARCH`, and the `.so` filename
  (`translate-<arch>-<endian>.so`). A mismatch = “Cannot find platform file” at construction.
- `[Import]` binds to the **`_ex`** symbol by default (`tlib_init`→`tlib_init_ex`). If you write a
  raw `tlib_init` with no exception wrapper, either generate the `_ex` wrapper (tlib `EXC_*` macros)
  or mark the field `[Import(UseExceptionWrapper = false)]`.
- Every arch‑specific `[Export]` needs a matching `EXTERNAL_AS` line, or the binder logs *“marked with
  Export but was not exported”* (`NativeBinder.cs:466-469`) and tlib’s callback pointer stays null.
- The register enum and `cpu_registers.h` IDs **must agree** - they are one ABI in two languages.
- Bi‑endian / 64‑bit variants are **separate** `CORES` entries *and* (for bitness) separate C#
  classes; don’t try to fold `mips`/`mips64` into one.
- `tlib_init` returning −1 surfaces only as a terse “Unknown CPU type” - log the rejected name inside
  tlib while bringing up the model table.
- Don’t hand‑write `<Arch>Registers.cs`; regenerate it from the `.tt` or it drifts from the header.
- This is a real DBT port: budget weeks, and prefer **porting** QEMU `target/mips` semantics over
  writing decode from the ISA manual cold.

**Checklist**
- [ ] Chose Option A vs B/C deliberately (§1).
- [ ] `tlib/arch/<isa>/`: `cpu.h`, `translate.c`, `op_helper.c`(+`helper.h`), `cpu_registers.{c,h}`,
      `arch_exports.{c,h}`, `arch_callbacks.{c,h}` (§4.3).
- [ ] `tlib_init` knows every `cpuType` you advertise; soft‑MMU fill + exceptions + IRQ delivery work.
- [ ] tlib `CMakeLists.txt` `TARGET_ARCH` + `TARGET_ACTUAL_ARCH` updated (§4.4).
- [ ] `renode/arch/<isa>/renode_<isa>_callbacks.c` `EXTERNAL_AS` lines = the C# `[Export]`s (§5).
- [ ] `CPU.<Arch>` class: `Architecture` + the abstract surface + `DecodeInterrupt` (§6).
- [ ] `<Arch>Registers.tt` authored, added to `regenerate_registers.sh`, regenerated (§7).
- [ ] `build.sh` `CORES` includes your `<arch>.le`/`.be` (and `64` variants) (§8).
- [ ] `--external-lib-arch <arch>` builds the `.so`; minimal repl loads; `cpu Step` advances; (ideally)
      `gdb_compare` vs QEMU passes; a reference firmware boots (§10).
- [ ] Handed off to [doc 07](07-source-router.md) → [doc 06](06-generating-a-new-board.md) for the chip.

---

## 13. Evidence appendix (sources & what was/wasn’t executed)

**Verified from the source trees** (reproduce):
```bash
# C# core wiring
grep -nE 'translate-|NativeBinder|TlibInit|Unknown CPU type' \
  renode-infrastructure/src/Emulator/Peripherals/Peripherals/CPU/TranslationCPU.cs   # :1634,1638,1648
grep -nE 'GetCName|_ex|UseExceptionWrapper|renode_external_attach' \
  renode-infrastructure/src/Emulator/Main/Utilities/Binding/NativeBinder.cs          # name-mangling + attach
sed -n '110,133p' renode-infrastructure/src/Emulator/Cores/renode/include/renode_imports.h  # EXTERNAL_AS
grep -nE 'EXTERNAL_AS' renode-infrastructure/src/Emulator/Cores/renode/renode_callbacks.c     # common callbacks
cat renode-infrastructure/src/Emulator/Cores/renode/arch/sparc/renode_sparc_callbacks.c       # arch glue example
cat renode-infrastructure/src/Emulator/Cores/Sparc/Sparc.cs                                    # smallest C# core
cat renode-infrastructure/src/Emulator/Cores/Sparc/SparcRegisters.tt                           # T4 register template
sed -n '37p;459,472p' renode-infrastructure/src/Emulator/Cores/CMakeLists.txt                  # OUTPUT_NAME glob
sed -n '411,478p' renode/build.sh                                                              # CORES matrix
sed -n '1,40p'   renode/tools/building/regenerate_registers.sh                                 # dotnet-t4 flow
```
- **tlib** structure (LGPL QEMU‑TCG fork; soft‑MMU only; `arch/{arm,arm64,arm_common,i386,ppc,riscv,sparc,xtensa}`;
  per‑arch `translate.c`/`cpu.h`/`*_helper.c`/`cpu_registers.{c,h}`/`arch_{exports,callbacks}.{c,h}`;
  host backends `tcg/{i386,arm,aarch64}`; C ABI in `include/exports.h`; `_ex` wrappers in
  `include/unwind.h`): `github.com/antmicro/tlib` (clone at master `64fe457d`, 2026‑06‑25), wired via
  `renode-infrastructure/.gitmodules`.
- **No official porting guide** confirmed: `github.com/renode/renode/issues/384` (maintainer).
- **tlib porting in practice** (features, not a tutorial): Antmicro Cortex‑R post
  `antmicro.com/blog/2023/07/cortex-r-support-in-renode-for-safety-critical-applications`
  (“required several improvements in tlib: adding A32/T32 instruction sets; interrupt support for
  32‑bit ARMv8; AArch32 system registers; MPU support”).
- **QEMU concepts** (ground the native frontend): `qemu.org/docs/master/devel/tcg.html` (TBs, MMU,
  block chaining), `…/devel/tcg-ops.html` (TCG IR, helpers, guest‑vs‑target terminology),
  `…/devel/decodetree.html` (decoder), `…/system/gdb.html` (GDB). Note tlib predates QEMU’s
  decodetree/QOM era, so concepts transfer but file paths do not (§4.1).

**Caveats.** `dotnet`/CMake/Renode were **not** run here and **no MIPS port was compiled or executed**;
§10 commands are exact but unexecuted. tlib internals are from a clone (not the unpopulated submodule
in this tree) and can drift - pin the commit. QEMU file paths cited via the agents reflect QEMU
`master` mid‑2026 and drift across releases; for tlib match its *existing* `arch/` dirs, not current
QEMU.

---

See also: [00 (overview)](00-overview.md) · [03 (C# peripherals)](03-csharp-peripherals.md) ·
[04 (the bridge)](04-repl-to-csharp-bridge.md) · [06 (generating a board)](06-generating-a-new-board.md) ·
[07 (source router)](07-source-router.md).
