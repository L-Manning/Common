# Resource Report Skill

Parse Vivado utilization reports, flag resources approaching limits, identify the largest consumers, and suggest optimisation strategies.

## Usage

```
/resource-report [options]
```

**Options:**
- `file=<path>` — Utilization report to parse (default: `reports/utilization.rpt`; also checks `reports/utilization_synth.rpt`).
- `thresholds` — Override warning/critical thresholds (default: warn at 70%, critical at 90%).
- `top=<n>` — Show top N largest RTL consumers per resource (default: 10).

---

## What This Skill Does

1. Reads Vivado utilization report(s) from `reports/`.
2. Extracts per-resource usage counts and percentages.
3. Flags resources at WARNING (≥70%) and CRITICAL (≥90%) utilization.
4. Identifies the top contributors by hierarchy.
5. Suggests specific optimisation strategies for over-utilized resources.
6. Optionally generates a Vivado TCL snippet to produce a hierarchical breakdown.

---

## Steps to Execute

### 1. Locate report files

```bash
ls -1 reports/utilization*.rpt reports/utilization*.xml 2>/dev/null
```

If no report exists, offer to generate one:
```bash
vivado -mode batch -source - <<'EOF'
open_checkpoint checkpoints/impl.dcp   # or synth.dcp
report_utilization -hierarchical -file reports/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 \
    -file reports/utilization_hier.rpt
EOF
```

### 2. Parse key resource metrics

Extract the **Device Summary** table — look for lines matching these patterns:

```
Slice LUTs*           |  used  | fixed | prohibited | available |   util%
Slice Registers       |  used  | ...
F7 Muxes              |  ...
F8 Muxes              |  ...
Block RAM Tile        |  ...
RAMB36/FIFO           |  ...
RAMB18                |  ...
DSPs                  |  ...
Bonded IOB            |  ...
BUFG/BUFGCE/BUFGCTRL  |  ...
MMCM                  |  ...
PLL                   |  ...
```

For each resource, capture: `used`, `available`, `util%`.

### 3. Apply thresholds and flag

| Utilization | Status | Symbol |
|---|---|---|
| < 70% | OK | ✓ |
| 70–89% | WARNING | ⚠ |
| ≥ 90% | CRITICAL | ✗ |

Special rule: **routing congestion** — if the report contains a `CONGESTION` or `Placer` section showing congested regions, always flag as WARNING regardless of raw utilization percentage.

### 4. Hierarchical breakdown (top consumers)

If `reports/utilization_hier.rpt` exists, extract the top N modules by LUT/FF/BRAM usage and display as a table:

```
Module                              LUTs    FFs    BRAMs   DSPs
──────────────────────────────────────────────────────────────────
top_level                          12,450  8,200   12      24
  axi_dma_0                         3,100  2,400    4       0
  fir_filter                        2,800    600    0      16
  uart_subsystem                      450    320    0       0
  debug_ila                           880    920    2       0
```

To regenerate a hierarchical report from Vivado:
```tcl
report_utilization -hierarchical -hierarchical_depth 5 \
    -file reports/utilization_hier.rpt
```

### 5. Routing congestion check

```bash
grep -A 5 "CONGESTION\|Congestion" reports/utilization.rpt
```

Also check the implementation log:
```bash
grep -i "congestion\|routing overflow\|unrouted" logs/impl.log | head -20
```

### 6. Output summary

Present a formatted table:

```
Resource              Used     Avail    Util%   Status
──────────────────────────────────────────────────────────
Slice LUTs           58,200   230,400   25.3%   ✓
Slice Registers      41,000   460,800    8.9%   ✓
Block RAM (36K)         280       312   89.7%   ✗ CRITICAL
DSPs                    420      1728   24.3%   ✓
Bonded IOB              187       400   46.8%   ✓
BUFG/BUFGCE              14        24   58.3%   ⚠ WARNING
MMCM                      3         4   75.0%   ⚠ WARNING
```

Then provide resource-specific recommendations for any WARNING or CRITICAL item.

---

## Optimisation Recommendations

### LUTs > 90%

1. **Enable LUT combining**: Vivado may not be merging LUTs across hierarchy boundaries. Try:
   ```tcl
   set_property FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
   ```
2. **Remove debug ILA/VIO cores** temporarily to measure headroom.
3. **Convert large case statements to BRAM look-up tables** using `RAM_STYLE` attribute.
4. **Review FSM encoding** — binary encoding uses fewer LUTs than one-hot for large state counts.
5. **Check for unintentional logic duplication** — hierarchical report will show unexpected large modules.

### Block RAM > 90%

1. **Convert small BRAMs to distributed RAM** (`RAM_STYLE "distributed"`) for memories ≤ 64 words — frees BRAM tiles.
2. **Pack multiple narrow memories into one wide BRAM** — a 36K BRAM can hold two 512×18 arrays.
3. **Review FIFO depths** — halving unnecessary FIFO depths can free significant BRAM.
4. **Use UltraRAM (URAM)** on UltraScale+ devices for large memories (> 4K × 72-bit):
   ```vhdl
   attribute RAM_STYLE : string;
   attribute RAM_STYLE of mem : signal is "ultra";
   ```
5. **Use external DDR via MIG/NoC** for very large buffers.

### DSPs > 90%

1. **Review multiply-accumulate structures** — ensure they are inferring DSP48E2 properly (check synthesis log for `DSP48E2` inference messages).
2. **Time-multiplex DSP operations** if throughput allows — share one DSP48 across multiple computation cycles.
3. **Use pre-adder input** of DSP48E2 for `(A±D)*B` patterns (saves one DSP per butterfly).
4. **Reduce coefficient precision** in FIR/IIR filters if SNR allows.
5. **Pipeline DSP chains** to allow sharing — though this increases latency.

### BUFG/BUFGCTRL > 80%

1. **Consolidate clock enables** — use a single clock with `CE` rather than separate gated clocks.
2. **Use regional clock buffers (BUFR/BUFIO)** for clocks that only drive one clock region.
3. **Remove debug clock outputs** from MMCM/PLLs not connected to logic.
4. Check: each MMCM/PLL output routed to fabric consumes one BUFG.

### MMCM/PLL > 75%

1. Xilinx 7-Series has 1 MMCM per clock region; UltraScale has more but still limited.
2. **Share MMCM outputs** — a single MMCM can provide up to 7 output clocks.
3. **Use BUFR divide** for simple integer clock divides instead of a separate PLL output.

### IOB > 80%

1. Review if all top-level ports are actually necessary — remove unused debug ports.
2. Check if bidirectional signals can be replaced with separate input/output pairs.
3. Ensure IOB-packing registers are being inferred (check `IOB TRUE` attribute or placement report).

---

## Generating Additional Reports

```tcl
# Detailed cell usage by type
report_utilization -cells [get_cells -hierarchical] -file reports/cell_usage.rpt

# Clock region utilization map
report_clock_utilization -file reports/clock_regions.rpt

# Routing congestion heatmap (GUI only, but can report via TCL)
report_design_analysis -congestion -file reports/congestion.rpt

# Pipeline/timing-aware utilization
report_design_analysis -complexity -file reports/complexity.rpt
```
