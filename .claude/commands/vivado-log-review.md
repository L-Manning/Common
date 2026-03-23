# Vivado Log Review Skill

Read Vivado synthesis and implementation logs, parse every WARNING and CRITICAL WARNING, explain what each means in plain language, and suggest specific RTL or constraint fixes.

## Usage

```
/vivado-log-review [options]
```

**Options:**
- `log=<path>` — Log file to review (default: auto-finds `logs/*.log`; reviews all if multiple exist).
- `stage=synth|impl|sim|all` — Restrict to a specific flow stage (default: `all`).
- `severity=error|critical|warning|all` — Minimum severity to report (default: `warning`).
- `filter=<pattern>` — Only show messages matching a regex (e.g., `filter=Timing`).

---

## What This Skill Does

1. Locates and reads Vivado log files from `logs/`.
2. Extracts all `ERROR`, `CRITICAL WARNING`, and `WARNING` messages with message IDs.
3. Groups messages by ID to collapse repeated warnings.
4. Looks up each message ID in the built-in reference table and provides a plain-language explanation.
5. Suggests specific fixes — including RTL edits, TCL commands, or constraint additions.
6. Highlights messages that block bitstream generation or indicate incorrect hardware behaviour.

---

## Steps to Execute

### 1. Locate log files

```bash
find logs/ -name "*.log" 2>/dev/null | sort
# Common files:
#   logs/synth.log     — synthesis
#   logs/impl.log      — implementation
#   logs/sim.log       — simulation
#   logs/program.log   — programming
```

If `logs/` doesn't exist, look for Vivado's default journal location:
```bash
find . -maxdepth 3 -name "*.log" | grep -v ".Xil\|.cache" | sort
```

### 2. Extract and group messages

```bash
# Extract all warnings and errors
grep -E "^(ERROR|CRITICAL WARNING|WARNING)" logs/synth.log logs/impl.log 2>/dev/null \
    | sed 's/.*\[\([A-Za-z0-9 _-]*\)\].*/\1/' \
    | sort | uniq -c | sort -rn \
    | head -40
```

For each unique message ID, count occurrences and show representative examples.

### 3. Explain and fix each message

Use the reference table below. For each message found in the logs, output:

```
[Synth 8-327] inferring latch for variable 'out_reg'        × 4 occurrences
───────────────────────────────────────────────────────────────────────────
WHAT:   Vivado has inferred a level-sensitive latch because a signal is
        not assigned in all branches of a combinational process. Latches
        cause simulation/synthesis mismatches and are almost always
        unintentional in synchronous FPGA designs.
FIX:    Add a default assignment at the top of the combinational process:
            process(all)
            begin
              out_reg <= '0';           -- add this default
              if condition then
                out_reg <= data_in;
              end if;
            end process;
        Alternatively, convert to a registered process if the signal
        should hold its value between clock edges.
SEVERITY: ERROR — latches will cause incorrect functional behaviour.
```

---

## Message Reference Table

### Synthesis Messages (`[Synth 8-*]`)

| ID | Short Text | Explanation | Fix |
|---|---|---|---|
| `Synth 8-327` | inferring latch | Signal not assigned in all branches of combinational process | Add default assignment before `if`/`case` |
| `Synth 8-3352` | multi-driven net | Same signal driven from two or more processes or statements | Consolidate to single driver |
| `Synth 8-5858` | abstract datatype | Non-synthesizable type (e.g. `file`, `access`, `real`) in synthesizable code | Replace with synthesizable types |
| `Synth 8-256` | cannot find operator | Missing `use ieee.numeric_std.all;` | Add `use ieee.numeric_std.all;` to file header |
| `Synth 8-3917` | design has unconnected port | A port of an instantiated component is left open | Connect port or add `open` explicitly (for outputs); check for typos on inputs |
| `Synth 8-7080` | component not found | Entity/component referenced but not found in compiled libraries | Check file is added to project and `library`/`use` declarations are correct |
| `Synth 8-5580` | DSP48E2 inferred | Informational: DSP inference succeeded | Verify inferred correctly; ensure operand widths match DSP resources |
| `Synth 8-3919` | unused sequential element | Register optimised away — always `'0'` or `'1'` | Check reset value and driver logic; may indicate missing connection |
| `Synth 8-6014` | optimized away | Logic simplified to constant | Intended? If not, check signal assignments for always-zero drivers |
| `Synth 8-4446` | VHDL latch infer | VHDL latch inferred (same as 8-327, different trigger) | Same fix as 8-327 |
| `Synth 8-228` | initial value of variable not equal | Simulation initial value ignored in synthesis | Remove initial value; rely on reset logic |
| `Synth 8-3886` | port ... is not connected | Top-level or component port unconnected | Wire up all ports; use `open` intentionally for unused outputs |
| `Synth 8-2490` | cannot synthesize the component | IP core or black box not properly set up | Ensure IP output products are generated; check OOC synthesis settings |

### Synthesis Messages (`[Synth 8-63*]`)

| ID | Short Text | Explanation | Fix |
|---|---|---|---|
| `Synth 8-6369` | ASYNC_REG attribute | Informational: ASYNC_REG recognised on signal | Verify the synchroniser chain has ≥ 2 FFs with this attribute |

### Common Implementation Messages

| ID | Short Text | Explanation | Fix |
|---|---|---|---|
| `Place 30-574` | poor placement for routing | Placer unable to find good placement | Relax constraints; try `AggressiveExplore` directive; use Pblocks |
| `Place 30-99` | IO placer was unable` | Cannot place all IOs within constraints | Check XDC for conflicting pin assignments or missing bank assignments |
| `Route 35-39` | nets not completely routed | Routing failed — congestion or resource exhaustion | Reduce utilization; try `congestion_sspe_explore`; check for uninferred constants |
| `Route 35-57` | re-entrant routing | Router revisiting areas — sign of congestion | Same as above |
| `DRC NSTD-1` | unspecified I/O standard | Port has no IOSTANDARD set in XDC | Add `set_property IOSTANDARD <standard> [get_ports <name>]` |
| `DRC UCIO-1` | unconstrained logic on I/O | Top-level port not placed or constrained | Add pin location + IOSTANDARD in XDC for all ports |
| `DRC RPBF-3` | IO buffer missing | Vivado could not infer IBUF/OBUF for a top-level port | Check port direction; ensure top-level signal is `std_logic` not `boolean` |
| `DRC PLCK-2` | clock enable on RAMB | BRAM clock enable not connected | Drive `ENA`/`ENB` to `'1'` or a meaningful enable signal |
| `Timing 38-282` | path not covered | Clock domain has no timing constraint | Add `create_clock` or `set_clock_groups` for unconstrained domains |
| `Timing 38-316` | clock period mismatch | `create_generated_clock` period doesn't match MMCM config | Recalculate or re-run Clocking Wizard and update generated clock constraints |
| `Timing 38-436` | override of property` | XDC property set multiple times | Remove duplicate constraint; last one wins but order matters |

### Simulation / Elaboration Messages

| ID | Short Text | Explanation | Fix |
|---|---|---|---|
| `VRFC 10-91` | signal not driven | Signal declared but never assigned | Remove unused signal or add driver |
| `VRFC 10-1`  | not a concurrent statement | Procedural statement outside process | Move statement inside a `process` block |
| `VRFC 10-3157` | port map error | Port map mismatch on instantiation | Check component declaration matches entity |
| `XSIM 43-3` | variable still has initial value` | Variable never assigned during simulation | Add stimulus in testbench |

### Critical Warnings (always investigate)

| ID | Short Text | Action Required |
|---|---|---|
| `Timing 38-282` | Unconstrained path | Add clock constraint — timing is not being checked |
| `DRC NSTD-1` | No I/O standard | Will cause DRC error — must fix before bitstream |
| `Synth 8-327` | Latch inferred | Almost certainly wrong — fix RTL |
| `Synth 8-3352` | Multi-driven net | Simulation and hardware will disagree — fix RTL |
| `Route 35-39` | Unrouted nets | Design cannot be programmed — fix routing |
| `DRC UCIO-1` | Unconstrained IO | Will fail bitstream generation DRC |

---

### 4. Summary output format

After analysing the logs, produce:

```
VIVADO LOG REVIEW SUMMARY
═══════════════════════════════════════════════════════════════
Log files reviewed: logs/synth.log, logs/impl.log

ERRORS (block bitstream / require immediate fix):
  [Route 35-39]  Nets not completely routed            ×  3
  → Routing congestion. Reduce LUT utilization or try
    route_design -directive AggressiveExplore.

CRITICAL WARNINGS (likely incorrect behaviour):
  [Synth 8-327]  Latch inferred for 'state_next'       ×  2
  → Add default: state_next <= state; before case statement.

  [Timing 38-282] Unconstrained path clk_gt → clk_sys  ×  1
  → Add: set_clock_groups -asynchronous
         -group clk_gt -group clk_sys

WARNINGS (review recommended):
  [Synth 8-3919] Unused register 'debug_ctr[3:0]'      × 4
  → Intentional? If debug signal, add ILA probe.
    If unintentional, check for missing driver.

  [DRC NSTD-1]   No IOSTANDARD on uart_rxd             × 1
  → Add to constraints/pins.xdc:
    set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]

INFORMATIONAL (no action needed):
  [Synth 8-5580] DSP48E2 inferred for mult_result       × 6  ✓
═══════════════════════════════════════════════════════════════
Total: 3 errors, 3 critical warnings, 5 warnings
```

### 5. Offer to apply fixes

For auto-fixable issues (adding defaults in VHDL, adding XDC lines), offer to apply the fix using the Edit tool after confirming with the user. Always show the proposed change before applying.

---

## Suppressing Benign Warnings

Once a warning is understood and accepted, suppress it in the project TCL to keep future log reviews clean:

```tcl
# Suppress specific message IDs in Vivado
set_msg_config -id "Synth 8-3919" -suppress   ;# unused register (intentional)
set_msg_config -id "Synth 8-5580" -new_severity INFO  ;# DSP inference (expected)
```

Add to `scripts/msg_config.tcl` and source it at the start of synthesis/implementation scripts.

---

## Parsing Logs Without Vivado

```bash
# Quick severity summary from any Vivado log
echo "=== ERRORS ===" && grep "^ERROR" logs/*.log | head -20
echo "=== CRITICAL WARNINGS ===" && grep "^CRITICAL WARNING" logs/*.log | head -20
echo "=== WARNING COUNTS ===" && grep "^WARNING" logs/*.log \
    | grep -oP '\[[^\]]+\]' | sort | uniq -c | sort -rn | head -30
```
