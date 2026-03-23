# CDC Check Skill

Analyse Clock Domain Crossing (CDC) paths in a VHDL design. Identify unsynchronised signals, generate appropriate XDC constraints, and recommend synchroniser insertion.

## Usage

```
/cdc-check [options]
```

**Options:**
- `file=<vhd>` — Analyse a specific VHDL file (default: all `rtl/` files).
- `vivado=yes|no` — Run Vivado's CDC report in addition to static analysis (default: `yes` if checkpoint available).

---

## What This Skill Does

1. Statically scans VHDL source files for signals crossing between clock domains.
2. Runs Vivado's built-in CDC analysis (`report_cdc`) if a checkpoint is available.
3. Classifies each CDC path by risk level.
4. Generates recommended XDC constraints or VHDL synchroniser templates.

---

## Steps to Execute

### 1. Static analysis — identify clock domains

Scan VHDL source for process sensitivity lists containing different clocks:

```bash
# Find all processes and their clock signals
grep -n "rising_edge\|falling_edge" rtl/**/*.vhd rtl/*.vhd 2>/dev/null
```

Build a map of: **signal → driving clock domain**.

Look for signals that appear in:
- A process clocked by `clk_a` (as output)
- A process clocked by `clk_b` (as input)

These are CDC candidates.

### 2. Vivado CDC report (preferred)

```bash
vivado -mode batch -source - <<'EOF'
open_checkpoint checkpoints/synth.dcp   ;# or impl.dcp
report_cdc -file reports/cdc_report.rpt -details
report_cdc -return_string -severity Critical
EOF
```

Parse the report:
```bash
grep -E "(Critical|Warning)" reports/cdc_report.rpt | head -30
```

### 3. Classify CDC paths

| Class | Description | Risk |
|---|---|---|
| **Unsynchronised** | Signal crosses domains with no sync FF | Critical |
| **Fan-out** | Multiple signals from domain A to B without MCP | High |
| **Reconvergence** | Two CDC signals that reconverge in domain B | High |
| **Partial** | Only one FF in synchroniser chain | Medium |
| **Compliant** | 2+ FF synchroniser or false path constrained | Low |

### 4. Generate fixes

#### A. Single-bit signal — 2-FF synchroniser

```vhdl
-- Add to rtl/pkg/cdc_pkg.vhd or inline in the receiving module

-- Attributes for Xilinx: prevent logic optimisation across CDC
attribute ASYNC_REG : string;
attribute ASYNC_REG of sync_meta : signal is "TRUE";
attribute ASYNC_REG of sync_out  : signal is "TRUE";

-- In the process of the DESTINATION clock domain:
sync_chain : process(clk_b)
begin
  if rising_edge(clk_b) then
    if rst_b = '1' then
      sync_meta <= '0';
      sync_out  <= '0';
    else
      sync_meta <= async_input;   -- metastability register
      sync_out  <= sync_meta;     -- stable output
    end if;
  end if;
end process sync_chain;
```

For high-reliability designs (MTBF requirements), use a 3-FF chain:
```vhdl
sync_meta  <= async_input;
sync_mid   <= sync_meta;
sync_out   <= sync_mid;
```

#### B. Multi-bit data — Gray code counter

For binary counters (e.g., FIFO pointers) crossing clock domains, convert to Gray code before crossing:

```vhdl
-- In source domain: binary to Gray
gray_ptr <= bin_ptr xor ('0' & bin_ptr(bin_ptr'high downto 1));

-- Synchronise gray_ptr with 2-FF chain into destination domain

-- In destination domain: Gray to binary
for i in gray_ptr'range loop
  bin_local(i) <= xor_reduce(gray_ptr(gray_ptr'high downto i));
end loop;
```

#### C. Multi-bit data bus — handshake protocol

For arbitrary multi-bit data, use a valid/acknowledge handshake:

```vhdl
-- Source domain: assert valid, wait for ack
-- Destination domain: capture data when valid seen, assert ack

-- Synchronise 'valid' into destination (2-FF)
-- Synchronise 'ack' back into source (2-FF)
-- Data bus is stable before valid assertion and held until ack
```

#### D. Pulse stretcher

For narrow pulses (1-cycle in source domain) crossing to a slower domain:

```vhdl
-- Convert pulse to level in source domain
stretch : process(clk_src)
begin
  if rising_edge(clk_src) then
    if rst_src = '1' then
      level <= '0';
    elsif pulse_in = '1' then
      level <= '1';
    elsif ack_sync = '1' then    -- ack_sync = synchronised ack from dest
      level <= '0';
    end if;
  end if;
end process;
-- Synchronise 'level' into destination domain with 2-FF
-- Detect rising edge of synchronised level in destination domain
```

### 5. Generate XDC constraints

For each identified CDC path, add to `constraints/timing.xdc`:

```tcl
# Async CDC — completely asynchronous clocks
set_false_path -from [get_clocks clk_a] -to [get_clocks clk_b]
set_false_path -from [get_clocks clk_b] -to [get_clocks clk_a]

# OR: Measured CDC — max delay equals one destination clock period
# (Use when clocks are related or have bounded skew)
set_max_delay -datapath_only \
    -from [get_cells {src_reg_a src_reg_b}] \
    -to   [get_cells {sync_meta_a sync_meta_b}] \
    5.000   ;# destination clock period

# ASYNC_REG constraint (auto-placed in optimal columns by Vivado)
set_property ASYNC_REG TRUE [get_cells {sync_meta sync_out}]
```

### 6. Report summary

Produce a table:

```
CDC Path                               Type           Risk       Action
──────────────────────────────────────────────────────────────────────────────
clk_100 → clk_200: fifo_wr_ptr[3:0]   Multi-bit bus  Critical   Use Gray code + 2-FF
clk_100 → clk_200: irq_pulse           Single-bit     High       Add 2-FF synchroniser
clk_200 → clk_100: status_reg[1]       Single-bit     Compliant  Already 2-FF in source
gt_rxclk → clk_100: rx_valid           Single-bit     Critical   Add false_path + 2-FF
```

---

## CDC Reusable Synchroniser Package

Offer to create `rtl/pkg/cdc_sync_pkg.vhd` with parameterised synchroniser components:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

package cdc_sync_pkg is

  component sync_ff is
    generic (STAGES : positive := 2);
    port (
      clk  : in  std_logic;
      rst  : in  std_logic;
      d    : in  std_logic;
      q    : out std_logic
    );
  end component;

end package cdc_sync_pkg;

-- Architecture
library ieee;
use ieee.std_logic_1164.all;

entity sync_ff is
  generic (STAGES : positive := 2);
  port (
    clk : in  std_logic;
    rst : in  std_logic;
    d   : in  std_logic;
    q   : out std_logic
  );
end entity sync_ff;

architecture rtl of sync_ff is
  signal chain : std_logic_vector(STAGES-1 downto 0) := (others => '0');
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of chain : signal is "TRUE";
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        chain <= (others => '0');
      else
        chain <= chain(STAGES-2 downto 0) & d;
      end if;
    end if;
  end process;
  q <= chain(STAGES-1);
end architecture rtl;
```
