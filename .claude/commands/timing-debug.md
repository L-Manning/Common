# Timing Debug Skill

Interactively diagnose timing failures (negative WNS/WHS) in AMD Xilinx FPGA designs. Walk through critical paths, identify root causes, and suggest RTL or constraint fixes.

## Usage

```
/timing-debug [options]
```

**Options:**
- `type=setup|hold|pulse` — Focus on setup (WNS), hold (WHS), or pulse-width (WPWS) violations (default: `setup` if WNS < 0, else `hold`).
- `paths=<n>` — Number of worst paths to analyse (default: 10).
- `clock=<name>` — Restrict analysis to a specific clock domain.
- `file=<path>` — Use an existing timing report (default: `reports/timing_summary.rpt`).

---

## What This Skill Does

1. Reads the timing summary report to identify the worst violations.
2. Generates detailed path reports for the failing paths.
3. Classifies the root cause of each violation.
4. Recommends targeted RTL changes, constraint adjustments, or implementation options.
5. Optionally applies constraint fixes after user confirmation.

---

## Steps to Execute

### 1. Read timing summary

```bash
cat reports/timing_summary.rpt | grep -A 50 "Design Timing Summary"
```

Extract:
- **WNS** (Worst Negative Slack) — setup margin; must be ≥ 0
- **TNS** (Total Negative Slack) — sum of all setup violations
- **WHS** (Worst Hold Slack) — hold margin; must be ≥ 0
- **THS** (Total Hold Slack) — sum of all hold violations
- **WPWS** (Worst Pulse Width Slack) — clock pulse width; must be ≥ 0

If no report exists, generate one from the implementation checkpoint:
```bash
vivado -mode batch -source - <<'EOF'
open_checkpoint checkpoints/impl.dcp
report_timing_summary -max_paths 50 -report_unconstrained \
    -warn_on_violation -file reports/timing_summary.rpt
report_timing -max_paths 20 -nworst 5 -path_type full_clock_expanded \
    -input_pins -file reports/timing_critical_paths.rpt
EOF
```

### 2. Extract worst paths

```bash
vivado -mode batch -source - <<'EOF'
open_checkpoint checkpoints/impl.dcp

# Setup — worst 10 paths
report_timing -max_paths 10 -nworst 3 \
    -sort_by slack \
    -path_type full_clock_expanded \
    -input_pins \
    -file reports/timing_setup_worst.rpt

# Hold — worst 10 paths
report_timing -max_paths 10 -nworst 3 \
    -delay_type min \
    -sort_by slack \
    -path_type full_clock_expanded \
    -input_pins \
    -file reports/timing_hold_worst.rpt
EOF
```

### 3. Parse and classify each failing path

For each path in the report, extract:

```
Slack:          -0.432 ns  (VIOLATED)
Source:         core/fir/mult_reg[15]/C  (FF clocked by clk_200)
Destination:    core/fir/accum_reg[31]/D (FF clocked by clk_200)
Data Path Delay: 5.821 ns
Logic Levels:   8  (CARRY4 x2, LUT6 x5, MUXF7 x1)
Clock Skew:     0.041 ns
```

Classify the root cause using this decision tree:

#### Setup violation root causes

| Symptom | Root Cause | Fix |
|---|---|---|
| Logic levels > 6 in a single cycle | Deep combinational cone | Insert pipeline register |
| Path crosses hierarchy boundaries unexpectedly | Flattening introduced long route | Add `KEEP_HIERARCHY` attribute |
| Large carry chain (CARRY4 count > 4) | Wide adder/comparator in critical path | Split operation across 2 cycles or use DSP |
| Path involves multiplier not in DSP | DSP not inferred | Restructure for DSP inference; add `USE_DSP YES` |
| Clock skew > 0.5 ns between source and dest | Poor clock placement | Constrain to same clock region with Pblock |
| Source/dest in different SLRs (multi-die) | SLR crossing penalty | Add pipeline stage at SLR boundary; use `set_max_delay` |
| Tight paths only after `phys_opt_design` | Placement not optimal | Try `directive AggressiveExplore` or `ExplorePostRoutePhysOpt` |
| `-0.0xx ns` marginal violation | Marginal: temperature/voltage variation | Add 50–100 ps guard band; re-run with `-directive HigherPostPlacementOpt` |

#### Hold violation root causes

| Symptom | Root Cause | Fix |
|---|---|---|
| Path has 0 logic levels (direct FF→FF) | Missing hold constraint on CDC path | Add `set_false_path` or `set_max_delay -datapath_only` |
| Large negative hold slack on all paths | Aggressive `set_max_delay -datapath_only` too tight | Review CDC constraints; widen the max delay |
| Hold violations after clock crossing only | CDC path not properly constrained | Add `set_clock_groups -asynchronous` or `set_false_path` |
| Scattered hold violations after route | Routing congestion causing hold-skew | Reduce congestion; try `directive AggressiveExplore` |

### 4. Detailed path analysis

For the worst path, display the full breakdown:

```
PATH ANALYSIS: Slack = -0.432 ns

  Source FF:      core/fir/mult_reg[15]  (clk_200, rising edge)
  Destination FF: core/fir/accum_reg[31] (clk_200, rising edge)

  Clock path:
    MMCM CLKOUT0 → BUFG → FF clock pin    0.832 ns

  Data path:
    FF Q → LUT6 (fir_add)                 0.142 ns  (logic: 0.124 ns)
    LUT6 → LUT6 (accum_carry_0)           0.312 ns  (route: 0.269 ns)
    LUT6 → CARRY4 (accum_carry_1)         0.401 ns
    CARRY4 → CARRY4 (accum_carry_2)       0.289 ns
    CARRY4 → CARRY4 (accum_carry_3)       0.311 ns
    CARRY4 → LUT6 (round_logic)           0.498 ns  ← LONG ROUTE
    LUT6 → MUXF7                          0.223 ns
    MUXF7 → FF D                          0.098 ns
    ─────────────────────────────────────────────
    Total data path delay:                5.821 ns

  Required time:    5.389 ns (clock period 5.0 ns - setup time 0.432 ns + skew)
  Slack:           -0.432 ns  VIOLATED
```

### 5. Generate fixes

Present targeted fix recommendations in priority order:

---

#### Fix A — Pipeline register insertion (most common)

Identify where in the data path to break the logic. The long route between `CARRY4` and `LUT6 (round_logic)` above is the best cut point.

Suggest RTL change:
```vhdl
-- Before: single-cycle multiply-accumulate
process(clk)
begin
  if rising_edge(clk) then
    accum <= accum + (a * b);  -- 8 logic levels
  end if;
end process;

-- After: pipelined (adds 1 cycle latency)
process(clk)
begin
  if rising_edge(clk) then
    mult_reg <= a * b;                    -- stage 1: multiply (uses DSP)
    accum    <= accum + mult_reg;         -- stage 2: accumulate
  end if;
end process;
```

#### Fix B — Implementation strategy escalation

Try progressively more aggressive strategies before changing RTL:

```bash
# Step 1: re-run phys_opt_design with more effort
vivado -mode batch -source - <<'EOF'
open_checkpoint checkpoints/impl.dcp
phys_opt_design -directive AggressiveExplore
write_checkpoint -force checkpoints/impl_physopt2.dcp
report_timing_summary -file reports/timing_after_physopt2.rpt
EOF

# Step 2: full re-implementation with aggressive directives
# In impl.tcl, change:
#   place_design -directive AggressiveExplore
#   phys_opt_design -directive AggressiveExplore
#   route_design -directive AggressiveExplore
#   phys_opt_design -directive AggressiveExplore
```

#### Fix C — Retiming

Enable register retiming during synthesis to automatically move registers across combinational logic:

```tcl
# In synth.tcl
synth_design -top $top -part $part -retiming
```

Or apply to specific modules:
```vhdl
attribute RETIMING_FORWARD  : integer;
attribute RETIMING_BACKWARD : integer;
attribute RETIMING_FORWARD  of my_module : label is 1;
```

#### Fix D — DSP inference fix

If the path goes through LUT-based multipliers, force DSP inference:
```vhdl
attribute USE_DSP : string;
attribute USE_DSP of mult_result : signal is "YES";
```
Verify in synthesis log:
```
INFO: [Synth 8-5580] DSP48E2 inferred for expression 'mult_result'
```

#### Fix E — Multicycle path constraint (use carefully)

Only apply if the data is genuinely not needed every cycle:
```tcl
# Data computed over 2 cycles — relax setup by 1 extra cycle
set_multicycle_path -setup 2 \
    -from [get_cells {core/fir/mult_reg[*]}] \
    -to   [get_cells {core/fir/accum_reg[*]}]
# MUST also adjust hold to compensate
set_multicycle_path -hold 1 \
    -from [get_cells {core/fir/mult_reg[*]}] \
    -to   [get_cells {core/fir/accum_reg[*]}]
```

#### Fix F — Pblock floorplanning

When source and destination are placed far apart, constrain them to the same region:
```tcl
create_pblock pblock_fir
add_cells_to_pblock [get_pblocks pblock_fir] \
    [get_cells core/fir_filter]
resize_pblock [get_pblocks pblock_fir] \
    -add {SLICE_X40Y100:SLICE_X79Y149}
```

### 6. Marginal timing — guard band analysis

For violations < 0.1 ns, check if the design runs cleanly at a slightly relaxed clock:

```tcl
# Temporarily loosen clock by 5% to isolate marginal paths
create_clock -period 10.500 -name clk_100_relaxed [get_ports clk_100mhz]
report_timing_summary -file reports/timing_relaxed.rpt
```

If timing closes at 10.5 ns but not 10.0 ns, focus optimisation effort on paths with slack between -0.5 ns and 0 ns.

---

## Timing Debug Checklist

- [ ] WNS ≥ 0 on all constrained clocks
- [ ] WHS ≥ 0 on all constrained clocks
- [ ] WPWS ≥ 0 (pulse width satisfied)
- [ ] No unconstrained paths (check `report_timing -unconstrained`)
- [ ] No false paths masking real timing issues
- [ ] CDC paths have correct `set_false_path` or `set_max_delay -datapath_only`
- [ ] All generated clocks (`create_generated_clock`) defined for MMCM/PLL outputs
- [ ] No `set_multicycle_path` applied to CDC crossing paths
