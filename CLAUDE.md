# CLAUDE.md — VHDL Development for AMD Xilinx FPGAs

## Project Overview

This repository supports VHDL-based FPGA development targeting AMD Xilinx devices, using the Vivado Design Suite toolchain. Follow the conventions below to maintain consistent, synthesizable, and timing-clean designs.

---

## Toolchain

| Tool | Purpose |
|---|---|
| **Vivado** | Synthesis, implementation, bitstream generation, timing analysis |
| **Vivado Simulator / GHDL** | Functional and timing simulation |
| **Vitis / SDK** | Embedded software (if MicroBlaze or Zynq) |
| **Vivado HLS / Vitis HLS** | High-level synthesis (C/C++ to RTL) |

Default Vivado installation path: `/opt/Xilinx/Vivado/<version>/`
Source the environment: `source /opt/Xilinx/Vivado/<version>/settings64.sh`

---

## Directory Layout

```
project/
├── rtl/                  # Synthesizable VHDL source files
│   ├── top/              # Top-level entities
│   ├── core/             # Core logic modules
│   └── pkg/              # Package files (types, constants, functions)
├── tb/                   # Testbenches (not synthesizable)
├── constraints/          # XDC constraint files
├── ip/                   # Xilinx IP cores (.xci)
├── scripts/              # TCL scripts for Vivado flows
│   ├── synth.tcl
│   ├── impl.tcl
│   └── sim.tcl
├── sim/                  # Simulation output / waveforms
├── reports/              # Timing, utilization, DRC reports
└── bitstream/            # Generated .bit / .bin files
```

---

## VHDL Coding Standards

> These standards are informed by NASA's VHDL coding guidelines (NASA-GSFC Rule-Based Style Guide for VHDL), adapted for AMD Xilinx FPGA development. The intent is to produce designs that are readable, verifiable, synthesizable, and maintainable.

### General Rules

- Target **VHDL-2008** (`--std=08` in GHDL; set in Vivado project properties).
- One entity per file; filename matches entity name (lowercase, underscores).
- All ports and signals use lowercase with underscores: `data_valid`, `clk_100mhz`.
- Active-high resets preferred; name them `rst` or `reset`. Active-low: `rst_n`.
- Generics use `ALL_CAPS`: `DATA_WIDTH`, `FIFO_DEPTH`.
- Constants in package files use `ALL_CAPS`.

### NASA-Inspired Mandatory Rules

These rules follow the spirit of NASA's flight software reliability principles applied to RTL design:

#### Rule N1 — Strong Typing
Use the most specific type available. Do not use `std_logic_vector` where a more constrained subtype conveys intent:
```vhdl
-- Preferred: narrow subtype
subtype byte_t is std_logic_vector(7 downto 0);
signal rx_byte : byte_t;

-- Avoid: unconstrained where constrained is possible
signal rx_byte : std_logic_vector(7 downto 0);  -- acceptable but less explicit
```

#### Rule N2 — No Implicit Conversions
All type conversions must be explicit. Never rely on tool-specific implicit casting:
```vhdl
-- Correct
signal count : unsigned(7 downto 0);
signal count_slv : std_logic_vector(7 downto 0);
count_slv <= std_logic_vector(count);

-- Forbidden (Synopsys packages allow this but it is non-portable)
count_slv <= count;  -- DO NOT DO THIS
```

#### Rule N3 — No Uninitialized State Machines
Every FSM must have an explicit reset state and an `others` / `when others` branch:
```vhdl
type state_t is (IDLE, SEND, WAIT_ACK, ERROR);
signal state : state_t;

process(clk)
begin
  if rising_edge(clk) then
    if rst = '1' then
      state <= IDLE;   -- explicit reset state
    else
      case state is
        when IDLE     => ...
        when SEND     => ...
        when WAIT_ACK => ...
        when ERROR    => ...
        when others   => state <= IDLE;  -- mandatory catch-all
      end case;
    end if;
  end if;
end process;
```
Add the Xilinx FSM encoding attribute when appropriate:
```vhdl
attribute FSM_ENCODING : string;
attribute FSM_ENCODING of state : signal is "ONE_HOT";  -- or "GRAY", "BINARY", "AUTO"
```

#### Rule N4 — No Implicit Sensitivity Lists in Combinational Logic (VHDL-93)
If targeting VHDL-93 environments, enumerate every signal read in a combinational process:
```vhdl
-- VHDL-2008 (preferred)
process(all) begin ... end process;

-- VHDL-93 (if required)
process(a, b, sel) begin ... end process;
```
Missing signals in the sensitivity list cause simulation/synthesis mismatches.

#### Rule N5 — Every Signal Must Have Exactly One Driver
Never drive a signal from multiple processes. This rule applies to both simulation and synthesis:
```vhdl
-- FORBIDDEN: two processes writing to the same signal
proc_a : process(clk) begin sig <= a; end process;
proc_b : process(clk) begin sig <= b; end process;  -- multi-driven net

-- Correct: use a mux inside one process
proc_mux : process(clk) begin
  if sel = '1' then sig <= a; else sig <= b; end if;
end process;
```

#### Rule N6 — No Variables in Synthesizable Code (with exceptions)
Avoid `variable` in synthesizable code unless the variable is purely a loop index or intermediate calculation within a single clock cycle. Variables introduce sequencing ambiguities in synthesis:
```vhdl
-- Acceptable: loop index
for i in 0 to 7 loop
  result(i) <= data(i) xor mask(i);
end loop;

-- Acceptable: combinational intermediate
process(all)
  variable tmp : unsigned(8 downto 0);
begin
  tmp := resize(a, 9) + resize(b, 9);  -- widened to catch carry
  sum  <= tmp(7 downto 0);
  cout <= tmp(8);
end process;

-- Avoid: registered variable (use signal instead for clarity)
process(clk)
  variable v_count : integer;  -- use signal count instead
begin ...
```

#### Rule N7 — Assertion-Driven Design
Add assertions to capture invariants and interface contracts. They are ignored by synthesis but invaluable in simulation:
```vhdl
-- Range check on incoming data
assert to_integer(unsigned(data_in)) < MAX_VALUE
  report "data_in out of range: " & to_string(to_integer(unsigned(data_in)))
  severity error;

-- FSM transition guard
assert not (state = SEND and tx_ready = '0')
  report "SEND entered while tx not ready"
  severity warning;
```

#### Rule N8 — Comment Every Port and Every Non-Obvious Signal
```vhdl
entity uart_tx is
  port (
    clk      : in  std_logic;                      -- system clock
    rst      : in  std_logic;                      -- synchronous reset, active-high
    data_in  : in  std_logic_vector(7 downto 0);  -- byte to transmit
    valid    : in  std_logic;                      -- data_in is valid this cycle
    ready    : out std_logic;                      -- asserted when module can accept data
    tx       : out std_logic                       -- UART serial output line
  );
end entity uart_tx;
```

#### Rule N9 — Parameterize Widths via Generics
Never hardcode bit widths in the logic body:
```vhdl
entity adder is
  generic (
    DATA_WIDTH : positive := 8
  );
  port (
    a, b : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    sum  : out std_logic_vector(DATA_WIDTH   downto 0)   -- one extra bit for carry
  );
end entity adder;
```

#### Rule N10 — No Tri-State Logic in Internal Fabric
High-impedance (`'Z'`) is only permitted at FPGA top-level I/O ports (e.g., bidirectional buses). Internal signals must never be `'Z'`. FPGA internal fabric does not support tri-state.
```vhdl
-- Correct: tri-state only at the IO pad
io_data <= data_out when oe = '1' else (others => 'Z');

-- Forbidden: tri-state on internal signal
internal_bus <= result when sel = '1' else (others => 'Z');  -- DO NOT DO THIS
```

### Clock Domains

- Use a single clock per process where possible.
- Never gate clocks in RTL — use clock enables (`ce`/`en`) instead.
- Clearly comment every clock domain and CDC crossing.
- Use `ASYNC_REG` attribute on CDC synchronizer flip-flops:
  ```vhdl
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of sync_ff : signal is "TRUE";
  ```

### Reset Strategy

```vhdl
-- Synchronous reset (preferred for most Xilinx architectures)
process(clk)
begin
  if rising_edge(clk) then
    if rst = '1' then
      q <= '0';
    else
      q <= d;
    end if;
  end if;
end process;
```

- UltraScale/UltraScale+: synchronous reset maps more efficiently.
- 7-Series: either synchronous or asynchronous is acceptable.

### Process Templates

**Registered logic:**
```vhdl
proc_name : process(clk)
begin
  if rising_edge(clk) then
    if rst = '1' then
      -- reset assignments
    else
      -- normal logic
    end if;
  end if;
end process proc_name;
```

**Combinational logic:**
```vhdl
proc_name : process(all)   -- VHDL-2008 sensitivity list
begin
  -- default assignments first to avoid latches
  output <= '0';
  case state is
    when IDLE => ...
    when others => null;
  end case;
end process proc_name;
```

### Avoiding Common Synthesis Issues

- Always assign defaults before conditional logic in combinational processes (prevents latches).
- Do not use `wait` statements in synthesizable code (testbenches only).
- Avoid `initial` values on signals in RTL; rely on reset logic instead.
- Use `std_logic` / `std_logic_vector` (not `bit` or `integer` for ports).
- Limit use of `integer` types to generics and loop indices.

### Attributes for Optimization

```vhdl
-- Prevent optimization of a register
attribute KEEP : string;
attribute KEEP of my_signal : signal is "TRUE";

-- Mark RAM style
attribute RAM_STYLE : string;
attribute RAM_STYLE of mem_array : signal is "BLOCK"; -- or "DISTRIBUTED", "ULTRA"

-- DSP inference
attribute USE_DSP : string;
attribute USE_DSP of mult_result : signal is "YES";
```

---

## Constraints (XDC)

- Place all timing constraints in `constraints/timing.xdc`.
- Place physical/pin constraints in `constraints/pins.xdc`.
- Always define the primary clock first:
  ```tcl
  create_clock -period 10.000 -name clk_100 [get_ports clk_100mhz]
  ```
- Set false paths for asynchronous CDC signals:
  ```tcl
  set_false_path -from [get_cells src_reg] -to [get_cells dst_sync_reg[0]]
  ```
- Use `set_max_delay -datapath_only` for measured CDC paths:
  ```tcl
  set_max_delay -datapath_only -from [get_clocks clk_a] -to [get_clocks clk_b] 5.0
  ```

---

## Vivado TCL Scripted Flow

Always use TCL scripts for reproducible builds (not the GUI project flow for committed builds).

**Run synthesis:**
```bash
vivado -mode batch -source scripts/synth.tcl
```

**Run full implementation + bitstream:**
```bash
vivado -mode batch -source scripts/impl.tcl
```

See `.claude/commands/` for Claude skills that automate these flows.

---

## Simulation

- Testbench files: prefix with `tb_`, e.g., `tb_my_module.vhd`.
- Use `assert` and `report` for self-checking testbenches:
  ```vhdl
  assert actual = expected
    report "FAIL: expected " & to_string(expected) & " got " & to_string(actual)
    severity failure;
  ```
- Prefer GHDL for fast command-line simulation:
  ```bash
  ghdl -a --std=08 rtl/my_module.vhd tb/tb_my_module.vhd
  ghdl -e --std=08 tb_my_module
  ghdl -r --std=08 tb_my_module --vcd=sim/tb_my_module.vcd
  ```

---

## Timing Closure Checklist

1. All clocks defined with `create_clock` or `create_generated_clock`.
2. CDC paths have false paths or `set_max_delay -datapath_only`.
3. No negative slack on setup (WNS ≥ 0) and hold (WHS ≥ 0).
4. Check `reports/timing_summary.rpt` after every implementation.
5. Review `reports/utilization.rpt` for resource usage.
6. Run DRC (Design Rule Check) before generating bitstream.

---

## Skills Available

| Skill | Description |
|---|---|
| `/vivado-synth` | Run Vivado synthesis via TCL batch mode |
| `/vivado-impl` | Run Vivado implementation and generate reports |
| `/vivado-sim` | Compile and run simulation (GHDL or Vivado sim) |
| `/vhdl-lint` | Check VHDL files for NASA/Xilinx coding standard violations |
| `/xdc-constraints` | Generate or review XDC timing constraint templates |
| `/ip-core` | Add, configure, and upgrade Xilinx IP cores |
| `/cdc-check` | Analyse clock domain crossings and generate CDC constraints |
| `/bitstream-prog` | Program a device via JTAG or write to configuration flash |
| `/resource-report` | Parse utilization reports; flag over-used resources with optimisation tips |
| `/timing-debug` | Walk through failing timing paths; classify root cause; suggest RTL/constraint fixes |
| `/zynq-boot` | Generate Zynq/MPSoC BOOT.BIN from FSBL, bitstream, and ELF via `bootgen` |
| `/vivado-log-review` | Parse Vivado logs; explain every WARNING/CRITICAL WARNING; suggest specific fixes |
| `/commit-msg` | Generate a structured commit message for RTL/constraints changes |
| `/merge-request` | Create a GitLab merge request with design change summary |

---

## Target Device Quick Reference

| Family | Common Parts | Notes |
|---|---|---|
| 7-Series | XC7A35T, XC7K325T, XC7VX485T | Older; no UltraRAM |
| UltraScale | XCKU040, XCVU095 | UltraRAM available |
| UltraScale+ | XCKU5P, XCZU7EV (Zynq) | HBM variants; Versal successor |
| Versal | XCVC1902 | AI Engines + PL + PS |

---

## Common Vivado Tcl Snippets

```tcl
# Open project
open_project project.xpr

# Add sources
add_files -norecurse [glob rtl/**/*.vhd]
add_files -fileset constrs_1 constraints/timing.xdc

# Set top
set_property top my_top [current_fileset]

# Run synthesis
launch_runs synth_1 -jobs 8
wait_on_run synth_1

# Run implementation
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

# Open timing report
open_run impl_1
report_timing_summary -file reports/timing_summary.rpt
report_utilization -file reports/utilization.rpt
```
