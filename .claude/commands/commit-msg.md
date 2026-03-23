# Commit Message Skill

Generate a structured, informative git commit message for VHDL RTL, constraints, and FPGA project changes.

## Usage

```
/commit-msg
```

No arguments needed — the skill reads the staged diff automatically.

---

## What This Skill Does

1. Runs `git diff --cached` to inspect all staged changes.
2. Categorises the change type and affected design areas.
3. Produces a commit message following the **Conventional Commits** format, extended with FPGA-specific context.
4. Optionally stages and commits with the generated message after user confirmation.

---

## Commit Message Format

```
<type>(<scope>): <short summary — imperative mood, ≤72 chars>

<body — what changed and why, ≤80 chars per line>

[Timing: WNS=+0.42ns  WHS=+0.11ns  LUTs=12%  FFs=8%  BRAMs=4]
[Simulation: PASS — tb_<module> all assertions pass]
[Breaking: <describe any interface change>]
```

### Types

| Type | When to Use |
|---|---|
| `feat` | New RTL module, new IP core, new functionality |
| `fix` | Bug fix in RTL logic or constraints |
| `refactor` | Restructure without functional change (e.g., pipeline stage split) |
| `perf` | Timing improvement, resource reduction |
| `test` | Add or update testbench |
| `constraints` | XDC changes only |
| `scripts` | TCL / build scripts only |
| `docs` | Documentation / comments only |
| `chore` | IP upgrade, tool version bump, file organisation |

### Scopes

Use the module or subsystem name as the scope:
- `uart_rx`, `fifo`, `axi_master`, `pcie_top`, `clk_wizard`, `dsp_chain`
- `constraints/timing`, `constraints/pins`
- `tb/tb_<module>`

### Summary Rules (NASA-inspired clarity)

- Use the **imperative mood**: "add", "fix", "remove", "split" — not "added", "fixing".
- Be **specific**: "fix FIFO overflow when rd_en glitches" not "fix bug".
- No period at the end of the summary line.
- Under 72 characters on the subject line.

---

## Steps to Execute

### 1. Read staged changes

```bash
git diff --cached --stat
git diff --cached
```

### 2. Analyse the diff

Identify:
- **Which files changed** — RTL, testbench, constraints, scripts, IP, docs?
- **What kind of change** — new logic, bug fix, refactor, constraint adjustment?
- **Which clock domains / interfaces are affected?**
- **Are there any breaking changes** (port additions/removals/renames, generic changes)?

### 3. Check for available reports

```bash
ls reports/timing_summary.rpt reports/utilization.rpt 2>/dev/null
```

If timing and utilization reports exist, extract key numbers:
```bash
grep -E "WNS|WHS" reports/timing_summary.rpt | head -4
grep -E "Slice LUTs|Slice Registers|Block RAM|DSPs" reports/utilization.rpt | head -6
```

### 4. Check simulation status

```bash
ls sim/*.log 2>/dev/null | head -5
grep -l "FAIL\|assertion.*failure" sim/*.log 2>/dev/null
```

### 5. Generate and display the message

**Example — RTL bug fix:**
```
fix(uart_rx): correct stop-bit sampling point offset by 0.5 baud

The sample point was calculated relative to the falling edge of the
start bit rather than the centre of the stop bit. This caused
intermittent framing errors at baud rates above 115200.

Timing: WNS=+1.24ns  WHS=+0.08ns  LUTs=3%  FFs=2%
Simulation: PASS — tb_uart_rx all 240 assertions pass
```

**Example — new feature:**
```
feat(axi_master): add burst read support for AXI4 INCR burst type

Implements ARLEN/ARSIZE/ARBURST fields for incrementing burst reads.
Burst length configurable via AXI_BURST_LEN generic (default 16).
Single-beat reads remain backward-compatible.

Timing: WNS=+0.31ns  WHS=+0.15ns  LUTs=18%  FFs=11%  BRAMs=2
Simulation: PASS — tb_axi_master burst and single-beat cases pass
Breaking: AXI_BURST_LEN generic added to axi_master entity
```

**Example — constraints only:**
```
constraints(timing): add set_max_delay for sys_clk -> gt_rxclk CDC

CDC path from clk_sys registers into GT rx clock domain was
unconstrained, causing hold violations at -3 speed grade.
Added set_max_delay -datapath_only 5ns on the 4 crossing paths.

Timing: WNS=+0.88ns  WHS=+0.02ns (was WHS=-0.31ns)
```

### 6. Confirm and commit

Present the message to the user and ask:
> "Commit with this message? (yes to commit / edit to modify)"

If confirmed:
```bash
git commit -m "<generated message>"
```
