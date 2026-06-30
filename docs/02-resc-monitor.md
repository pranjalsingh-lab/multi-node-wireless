# 02 — The `.resc` Script Format & the Monitor

> `.resc` = **RE**node **SC**ript. A sequence of **Monitor commands** that *set up and run*
> an emulation: create machines, load `.repl` platforms, load firmware, configure
> logging/analyzers/networking, define reset behavior, and start. It is imperative glue,
> not a hardware description.

**Authoritative source** (almost all of the Monitor is in `renode-infrastructure`):
- Monitor core (parsing, scripts, variables): `src/Emulator/Extensions/UserInterface/Monitor.cs`.
- Member-reflection engine (object methods → commands): `src/Emulator/Extensions/UserInterface/MonitorCommands.cs`.
- Tokenizer: `src/Emulator/Extensions/UserInterface/Tokenizer/Tokenizer.cs`.
- Built-in commands: `src/Emulator/Extensions/UserInterface/Commands/*.cs`.
- `LoadPlatformDescription` (in the `renode` tree): `src/Renode/PlatformDescription/UserInterface/PlatformDescriptionMachineExtensions.cs`.

> **Myth-busting up front** (the original task brief guessed these; both are wrong):
> there is **no `[RunOnVirtualTime]` attribute**, and the Monitor is *not* under
> `renode/src/Renode/UserInterface` (that dir has no `.cs`). The Monitor lives entirely in
> `renode-infrastructure`. Method exposure is gated by `IsCallable` + `[HideInMonitor]`
> (§5), not by any virtual-time attribute.

---

## 1. Key fact: a `.resc` file is just typed Monitor input

There is **no semantic difference** between a line in a `.resc` file and a line you type at
the `(monitor)` prompt. Both go through the identical pipeline:

```
line ──► Monitor.Parse ──► Tokenize ──► split on ';' ──► ParseTokens ──► ExecuteCommand
```

- Typed input: the shell calls `Monitor.HandleCommand` → `Parse(cmd)` (`Monitor.cs:485-489`).
- `.resc` file: `include`'s executor reads the file and calls `Parse(line)` once per logical
  line (`Monitor.TryExecuteScript`, `Monitor.cs:308-373`, esp. `:360-367`).

The extension `.resc` is a **convention only** — nothing checks it. `IncludeFileCommand`
routes any non-`.py`/`.cs`/`.repl` file to the Monitor-script path
(`Commands/IncludeFileCommand.cs:80-95`). The only script-specific behaviors are:
1. `$ORIGIN` is set to the script's own directory while it runs (`Monitor.cs:322-323`,
   restored at `:368-371`).
2. Multi-line `"""…"""` blocks are joined at file-read time (`Monitor.cs:330-357`);
   interactively you'd be prompted line-by-line.

---

## 2. The parser pipeline

### `Parse` (`Monitor.cs:128-183`)
1. If an interactive multi-line capture ("string eater") is active, accumulate the line.
2. Blank lines are no-ops.
3. `Tokenize` the line.
4. Split tokens on `;` (`CommandSplit`) into independent commands; run each via
   `ParseTokens`. So `start; quit` is two commands.

### `ParseTokens` (`Monitor.cs:185-301`)
- **Comments are dropped** here (`CommentToken` → `continue`).
- **Backtick substitution**: `` `…` `` (an `ExecutionToken`) is executed, its captured
  stdout becomes a string, and the line is re-parsed. This is how
  `` $id = `python "print x"` `` and `` cpu PC `sysbus GetSymbolAddress "_start"` `` work
  (`:197-205`, helper `ExecuteWithResult` `:1174-1186`).
- **Path tokens** `@…` are resolved against the search path, or treated as a URL to download
  (`:207-244`).
- On `RecoverableException`, if `monitor:break-script-on-exception` is true (default) the
  rest of the script aborts (`:256-299`).

### `ExecuteCommand` — resolution order (`Monitor.cs:663-731`)
Given the first token, the Monitor tries, **in this order**:

1. **Variable assignment** — `VAR = value` or `VAR ?= value` (`?=` only if undefined).
2. **Built-in command** whose name matches (e.g. `mach`, `include`, `start`).
3. **Object/peripheral name** is available → dispatch a *member* call (e.g.
   `sysbus LoadELF …`, `cpu PC 0x0`). Honors `using` prefixes.
4. **`EmulationManager`** member.
5. **Command alternative names** (`s`=start, `i`=include, `p`=pause, …).
6. **Alias** expansion.
7. **Python builtin** `mc_<name>` from `scripts/monitor.py`.
8. Else: *"No such command or device"*.

This order is why a peripheral named like a command could shadow nothing — built-ins win.

---

## 3. The tokenizer & comments

Regex rules tried top-to-bottom, first match wins (`Tokenizer/Tokenizer.cs:18-95`).
Highlights:

| Token | Pattern | Meaning |
|---|---|---|
| `CommentToken` | `^#.*` | `#` comment to end of line |
| `ExecutionToken` | `` ^`.*?` `` | backtick command substitution |
| `VariableToken` | `^\$([0-9a-zA-Z_.])+` | `$name` |
| `MultilineString…` | `^"""..."""` / `^"""` | triple-quoted block |
| `StringToken` | `'…'` / `"…"` | string |
| range tokens | `<a,b>` / `<a b>` | absolute / relative ranges |
| `PathToken` | `^@(?:(?!;)((\\ )\|\S))+` | `@path`; `\ ` is an escaped space |
| `HexToken` / numeric / `TimeIntervalToken` | `0x…` / `123` / `h:m:s.frac` | literals |
| `CommandSplit` | `^;` | statement separator |
| `LiteralToken` | `^[\w.\-?][\w.\-?:]*` | command / member / peripheral name |
| `CommentToken` | `^:.*` | `:` comment — **lowest priority** |

**Two comment syntaxes, asymmetric** (commonly misunderstood):
- `#` starts a comment anywhere a token may begin.
- `:` starts a comment **only when it is the first character of a fresh token** (the literal
  rule can't start with `:`, so a leading `:` falls through to the `:`-comment rule). This is
  exactly why the `:name:` / `:description:` metadata headers at the top of every `.resc`
  are simply comments to the Monitor. A mid-token colon (`cpu:0`, `sysbus.uart0`) stays part
  of the literal.

---

## 4. Variables: `$name`, `?=`, `$ORIGIN`, `$CWD`

### Storage and scope
Three dictionaries: `variables`, `macros`, `aliases` (`Monitor.cs:1310-1313`). Names are
**machine-scoped** (`GetVariableName`, `:1188-1204`): an unqualified `$x` is stored under
`<machineName>.x` if a machine is selected, else `global.x`. Lookup tries exact →
`<machine>.x` → `global.x` (`TryExpandVariable`, `:772-795`). This is why the same `reset`
macro means the right thing under each machine.

### Assignment
- `$x = value` — always set.
- `$x ?= value` — set **only if undefined** (`ConditionalEqualityToken`). This is the
  override hook: a script writes `$bin?=@default.elf`, and automation can pre-set `$bin`
  (e.g. `renode -e '$bin=@my.elf' script.resc`) to override it.

### Built-in variables
- **`$CWD`** = process working directory at startup (`global.CWD`, `Monitor.cs:64,77`).
- **`$ORIGIN`** = directory of the *currently executing script* (set per-include,
  `Monitor.cs:322-323`). Use it for **relocatable includes**: `i $ORIGIN/sub.resc`.
- `$bin`, `$name`, `$id1`, … are ordinary user variables — conventions, no magic.
- Environment variables are not directly addressable (no `$ENV`), except `STARTUP_COMMAND`
  (injected as the shell's first command, `Monitor.cs:564`) and via embedded Python
  (`os.environ`).

### Macros vs variables
Same mechanism; a `macro` is a (usually multi-line) string in the `macros` dict that
`runMacro` / the reset hook execute as commands. `set`/`macro`/`alias` differ only by which
dict they write (`Monitor.cs:1046-1051`).

---

## 5. How C# object members become commands (the reflection engine)

`sysbus LoadELF …`, `cpu PC 0x0`, `machine LoadPlatformDescription …`, `emulation RunFor …`
are **not** hard-coded commands. They are reflected member calls on bound objects, via
`MonitorCommands.ExecuteDeviceAction` (`MonitorCommands.cs:70-246`):

- The first token names an object: a peripheral of the current machine (`sysbus`,
  `cpu`, `uart0`, …) or a bound singleton (`machine`, `emulation`, `connector`, `plugins`,
  `EmulationManager`, `sockets` — `Monitor.cs:1021-1026`).
- The second token names a **method / property / field / indexer** on that object's type.
  - method → call it; property/field with no arg → get; with an arg → set
    (`cpu PerformanceInMips 125`, `cpu PC 0x0`).
  - **extension methods** count too (discovered via `TypeManager.GetExtensionMethods`) — this
    is how `LoadELF`, `LoadFdt`, `CreateSwitch`, `SetGlobalQuantum` attach to types they
    don't declare. `LoadPlatformDescription` is likewise an extension method on `Machine`.
  - reference-typed members can be **chained** (`machine SystemBus …`).
- Arguments are bound from tokens (`MonitorCommands.cs:601-885`): positional, **named**
  (`param=value`), `params T[]`, `[a, b, c]` arrays. A leading `[AutoParameter] IMachine` is
  auto-filled with the current machine. Peripheral *names* auto-convert to peripheral
  objects; enum names parse; etc.

**What's exposed**: members are filtered by `TypeExtensions.IsCallable`
(`src/Emulator/Extensions/Utilities/TypeExtensions.cs:30-189`) — every parameter type must be
convertible from a Monitor token, and the member must not be marked `[HideInMonitor]`
(`src/Emulator/Main/UserInterface/HideInMonitorAttribute.cs`). `[UiAccessible]` only supplies
a friendly name. (Again: **no `[RunOnVirtualTime]`** exists.)

Return values are pretty-printed by `PrintActionResult` (`MonitorCommands.cs:1211-1269`):
integers honor the current number format (default **hex**; toggle with `numbersMode`), enums
list their values, images render inline.

---

## 6. Command reference (the ones you'll actually see in `.resc`)

### Machine management — `mach`
`Commands/MachCommand.cs` (name `mach`):
- `mach create` — new machine, generic name, **selected** (`:117-131`).
- `mach create "name"` — new **named** machine, selected (`:109-113`).
- `mach add "name"` — new machine; selected only if none active (`:81-88`).
- `mach set "name"` / `mach set <n>` — select existing.
- `mach clear` — deselect (current = null) (`:122-124`).
- `mach rem "name"` — remove. `mach` alone lists machines.

Selecting sets the prompt to `(name)`. Switching machines changes which peripherals/variables
are in scope.

### `using` (Monitor prefix — *not* the `.repl` include)
`Commands/UsingCommand.cs`: `using sysbus` appends the prefix `sysbus.` so `sysbus.uart0` is
reachable as `uart0` (`:42-57`). `using -` clears all.
> **`sysbus.` is already a default prefix** (`MonitorCommands.cs:1567`), so `using sysbus` is
> conventional but redundant (de-duped, harmless). `using` survives `mach create` and
> emulation reset.

### Load a platform — `machine LoadPlatformDescription` / `…FromString`
Extension methods on `Machine` (in the `renode` tree,
`PlatformDescriptionMachineExtensions.cs:18` / `:23`):
- `machine LoadPlatformDescription @platforms/boards/x.repl` — load a `.repl` file.
- `machine LoadPlatformDescriptionFromString """ <inline repl> """` — inline `.repl`.

These call into the `CreationDriver` (the whole of [doc 01](01-repl-format.md) /
[doc 04](04-repl-to-csharp-bridge.md)).

### `include` / `i`, and loading `.repl`/`.py`/`.cs`
`Commands/IncludeFileCommand.cs:20-105` dispatches by extension:
- `.py` → run as Python; `.cs` → ad-hoc compile a plugin/peripheral at runtime; `.repl` →
  `Monitor.TryLoadPlatform` (auto-creates a machine if none); **anything else** →
  Monitor script.
- `i @scripts/single-node/x.resc`, or relative to the including script via `i $ORIGIN/x.resc`.

### Load firmware — `sysbus LoadELF / LoadBinary / LoadUImage / LoadFdt`
Reflected calls/extensions on `sysbus`:
- `sysbus LoadELF $bin` (`Core/Extensions/FileLoaderExtensions.cs:417`,
  `LoadELF(file, useVirtualAddress=false, cpu=null)`).
- `sysbus LoadBinary @file 0xADDR` (`FileLoaderExtensions.cs:28`).
- `sysbus LoadUImage @file`, `sysbus LoadFdt @file 0xADDR "bootargs"`
  (`MachineExtensions.cs:56`).

### `showAnalyzer` / `sa`
`Commands/ShowBackendAnalyzerCommand.cs`: open a backend window/terminal for a peripheral —
`showAnalyzer sysbus.uart4`. No-op if analyzers are hidden (`--hide-analyzers`).

### Run control — `start` / `s`, `pause` / `p`
- `start` → `Emulation.StartAll()` (`Commands/StartCommand.cs`). `start @path` runs a script
  then starts.
- `pause` / `p` → `Emulation.PauseAll()`.

### `reset` is a **macro**, not a global command
There is no global `reset` command. Each machine has a `reset` macro; the Monitor hooks
machine reset to replay it (`RegisterResetCommand` `Monitor.cs:989-993`, `ResetMachine`
`:1076-1099`). The idiom every script uses:

```
macro reset
"""
    sysbus LoadELF $bin
"""
runMacro $reset
```

`macro reset """…"""` *defines* the reset behavior (and arms it for future `machine Reset`s);
`runMacro $reset` *runs it now* to initialize the machine.

### `logLevel`
`Commands/LogLevelCommand.cs`: `logLevel <level> [object] [recursive?]`. Levels are numeric
`-1..3` or `Noisy/Debug/Info/Warning/Error`. E.g. `logLevel 3`, `logLevel -1 sysbus.uart0`.

### `emulation …` and networking
`emulation` is the `Emulation` object:
- `emulation RunFor "0.1"`, `emulation PauseAll`, `emulation StartAll`.
- extensions: `emulation CreateSwitch "switch"`, `emulation CreateUARTHub`,
  `emulation CreateIEEE802_15_4Medium "wireless"`,
  `emulation CreateServerSocketTerminal 3451 "cli"`,
  `emulation SetGlobalQuantum "0.00002"`, `emulation SetGlobalSerialExecution true`.
- `connector Connect <peripheral> <medium>` wires a peripheral into a shared medium/hub
  (`connector` is a separate bound object).

### `set` / `macro` / `alias`, `runMacro` / `execute`
- `set NAME value` (variable), `macro NAME """…"""` (macro), `alias NAME value` (command
  alias) — three instances of `SetCommand`. With no value they enter interactive multi-line
  capture.
- `runMacro $name` / `execute $var` split the stored string on newlines and `Parse` each line.

### `python` / `py`, and Python builtins
- `python "code"` runs IronPython; `scripts/monitor.py` is preloaded and any `mc_<cmd>`
  function there becomes a Monitor command (`MonitorPythonEngine.cs`).
- `` `python "print expr"` `` is the inline backtick form.

### `path`
`Commands/MonitorPathCommand.cs`: `path set @dir` / `path add @dir` / `path reset` manage the
`;`-separated search path used to resolve `@files` and includes. `@`-paths resolve against the
Renode root by default (the Monitor `chdir`s there at startup, `Monitor.cs:566-574`).

---

## 7. Startup: launcher → Monitor

- **`renode`** (bash launcher, `renode/renode`) strips its own flags and
  `exec dotnet Renode.dll "$@"` — every other arg is forwarded.
- **`Program.Main`** (`renode/src/Renode/Program.cs`) parses argv into `Options` and runs
  `CommandLineInterface.Run`.
- **`Options`** (`renode-infrastructure/src/UI/Options.cs`): positional arg 0 = the
  `.resc`/snapshot to run; `-e/--execute` = extra commands run *after* the script (repeatable);
  `--console` = Monitor in the terminal; `--disable-gui`/`--hide-monitor`/`--hide-analyzers`/
  `-P/--port` (telnet Monitor) etc.
- **`CommandLineInterface.PrepareShell`** injects the startup script as an `include`
  (`i $CWD/<file>` for a relative path, `i @<file>` for absolute/URI; `.save`/`.gz` →
  `Load` snapshot), then appends the `-e` commands.

So `renode myscript.resc -e 'start'` becomes, inside the shell:
`i $CWD/myscript.resc` then `start` — both ordinary Monitor lines.

---

## 8. Annotated real scripts

### Minimal single-node (`scripts/single-node/leon3_zephyr.resc`)
```
:name: Leon3 Zephyr shell                       # ':'-comment (metadata header)
:description: Runs the Zephyr shell on Leon3
using sysbus                                     # add 'sysbus.' prefix (redundant but conventional)
$name?="Leon3"                                   # default name, overridable via -e '$name=...'
mach create $name                                # create + select the machine -> prompt (Leon3)
machine LoadPlatformDescription @platforms/boards/leon3.repl   # instantiate the .repl
$bin?=@https://dl.antmicro.com/.../leon3--zephyr-shell_module.elf-...   # URL firmware, overridable
showAnalyzer sysbus.uart                         # open a UART terminal
macro reset                                      # define the reset behavior...
"""
    sysbus LoadELF $bin                          #   ...load the ELF on every reset
"""
runMacro $reset                                  # run it now to initialize
# (no 'start' here; the user or `-e start` begins execution)
```

The canonical skeleton: **select machine → load platform → declare binary → open analyzer →
define `reset` macro that loads firmware → run it.**

### Patterns worth knowing (from `scripts/single-node/stm32f4_discovery.resc`)
```
cpu PerformanceInMips 125                        # property SET on peripheral 'cpu'
python "import _random"                          # embedded Python
$id1 = `python "print rand.getrandbits(32)"`     # backtick substitution into a variable
macro reset
"""
    sysbus LoadELF $bin
    sysbus WriteDoubleWord 0x1FFF7A10 $id1        # method call on sysbus; writes a unique-ID word
"""
runMacro $reset
```

### Multi-node essentials (`scripts/multi-node/efr32xg24-twonode_demo.resc`)
```
emulation SetGlobalSerialExecution true
emulation CreateIEEE802_15_4Medium "wireless"    # shared radio medium
mach create "node1"
machine LoadPlatformDescription "platforms/boards/silabs/brd4186c.repl"
runMacro $reset                                  # $reset resolves to node1's copy (machine-scoped)
emulation CreateServerSocketTerminal 3451 "cli_node1"
connector Connect sysbus.eusart0 cli_node1
connector Connect sysbus.radio wireless          # join node1 into the shared medium
mach clear                                        # deselect, then repeat for node2 ...
```

---

## 9. Gotchas (verified)

1. **`.resc` is not special** — same parser as the prompt; the extension isn't checked.
2. **`using sysbus` is redundant** — `sysbus.` is a default prefix.
3. **`reset` is a macro** — define `macro reset """…"""` and end with `runMacro $reset`.
4. **Two comment syntaxes** — `#` anywhere; `:` only at a token boundary (hence `:name:`
   headers). Both run to end of line.
5. **`?=`** assigns only if undefined — the override hook for automation/`-e`.
6. **Variables are machine-scoped** — bare `$x` is machine-local first, then `global.`.
7. **`$ORIGIN` (script dir) vs `$CWD` (process start dir)** — use `$ORIGIN` for relocatable
   includes.
8. **Numbers print/parse in hex by default** — toggle with `numbersMode`.
9. **`machine LoadPlatformDescription` is an extension method** in the `renode` tree, surfaced
   through the same reflection dispatch as any peripheral method.

---

Next: [`03-csharp-peripherals.md`](03-csharp-peripherals.md) — how the C# device models that
`.repl` instantiates are written.
