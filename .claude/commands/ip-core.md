# IP Core Skill

Add, configure, generate, and upgrade AMD Xilinx IP cores in a Vivado project.

## Usage

```
/ip-core [action] [options]
```

**Actions:**
- `/ip-core add` — Add a new IP core to the project.
- `/ip-core upgrade` — Upgrade locked IP cores to the current Vivado version.
- `/ip-core list` — List all IP cores in the project and their lock status.
- `/ip-core generate` — Re-generate output products for all IP cores.

**Options:**
- `name=<ip_name>` — IP core name (e.g., `name=clk_wiz`, `name=fifo_generator`, `name=axi_dma`).
- `part=<part>` — Target device (default: taken from project).

---

## Common Xilinx IP Cores Reference

| IP Core | Catalog Name | Typical Use |
|---|---|---|
| `clk_wiz` | Clocking Wizard | MMCM/PLL clock generation |
| `fifo_generator` | FIFO Generator | Synchronous/async FIFOs |
| `blk_mem_gen` | Block Memory Generator | BRAMs as ROM/RAM/FIFO |
| `axi_dma` | AXI DMA | DMA for AXI4-Stream to memory |
| `axi_interconnect` | AXI Interconnect | Connect multiple AXI masters/slaves |
| `axi_bram_ctrl` | AXI BRAM Controller | Memory-mapped BRAM via AXI4 |
| `axis_data_fifo` | AXI4-Stream Data FIFO | Stream buffering |
| `axis_clock_converter` | AXI4-Stream Clock Converter | Stream CDC |
| `xdma` | DMA/Bridge for PCIe | PCIe DMA |
| `gt_wizard` | GT Wizard | High-speed serial (GTX/GTH/GTY) |
| `ila` | Integrated Logic Analyzer | In-system debug |
| `vio` | Virtual IO | In-system probing/stimulus |

---

## Steps to Execute

### Action: `list`

```bash
vivado -mode batch -source - <<'EOF'
open_project *.xpr
set ips [get_ips]
foreach ip $ips {
    set version [get_property VERSION $ip]
    set locked  [get_property IS_LOCKED $ip]
    set stale   [get_property STALE     $ip]
    puts [format "%-30s v%-10s locked=%-5s stale=%s" \
          [get_property NAME $ip] $version $locked $stale]
}
EOF
```

### Action: `add`

Interactively guide the user through adding an IP:

1. Ask which IP core they want (refer to the table above).
2. Provide the standard TCL commands to add and configure it.

**Example: Add Clocking Wizard**
```tcl
# In Vivado TCL console or batch script
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
    -module_name clk_wiz_0

set_property -dict [list \
    CONFIG.PRIMITIVE            {MMCM} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLKOUT2_USED         {true} \
    CONFIG.NUM_OUT_CLKS         {2} \
    CONFIG.CLKIN1_JITTER_PS     {50.0} \
    CONFIG.MMCM_CLKFBOUT_MULT_F {10.000} \
    CONFIG.MMCM_CLKIN1_PERIOD   {10.000} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {5.000} \
    CONFIG.MMCM_CLKOUT1_DIVIDE  {10} \
] [get_ips clk_wiz_0]

generate_target all [get_ips clk_wiz_0]
```

**Example: Add FIFO Generator (async, 512 deep, 32-bit wide)**
```tcl
create_ip -name fifo_generator -vendor xilinx.com -library ip -version 13.2 \
    -module_name async_fifo_32x512

set_property -dict [list \
    CONFIG.Fifo_Implementation        {Independent_Clocks_Block_RAM} \
    CONFIG.Input_Data_Width           {32} \
    CONFIG.Input_Depth                {512} \
    CONFIG.Output_Data_Width          {32} \
    CONFIG.Output_Depth               {512} \
    CONFIG.Read_Data_Count            {true} \
    CONFIG.Write_Data_Count           {true} \
    CONFIG.Almost_Full_Flag           {true} \
    CONFIG.Almost_Empty_Flag          {true} \
    CONFIG.Use_Extra_Logic            {true} \
] [get_ips async_fifo_32x512]

generate_target all [get_ips async_fifo_32x512]
```

**Example: Add ILA for in-system debug**
```tcl
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 \
    -module_name ila_0

set_property -dict [list \
    CONFIG.C_PROBE0_WIDTH   {8} \
    CONFIG.C_PROBE1_WIDTH   {1} \
    CONFIG.C_DATA_DEPTH     {1024} \
    CONFIG.C_TRIGIN_EN      {false} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
] [get_ips ila_0]

generate_target all [get_ips ila_0]
```

### Action: `upgrade`

```bash
vivado -mode batch -source - <<'EOF'
open_project *.xpr
# Report locked IPs
report_ip_status -file reports/ip_status.rpt

# Upgrade all locked IPs
upgrade_ip [get_ips]

# Re-generate all output products
foreach ip [get_ips] {
    generate_target all $ip
}
puts "IP upgrade complete."
EOF
```

### Action: `generate`

```bash
vivado -mode batch -source - <<'EOF'
open_project *.xpr
foreach ip [get_ips] {
    puts "Generating: [get_property NAME $ip]"
    generate_target all $ip
}
export_ip_user_files -of_objects [get_ips] -no_script -force
puts "All IP output products generated."
EOF
```

---

## VHDL Instantiation Template

After adding an IP, use the generated component declaration from `ip/<name>/<name>.vho`:

```vhdl
-- Component declaration (from .vho stub)
component clk_wiz_0
  port (
    clk_in1  : in  std_logic;
    clk_out1 : out std_logic;   -- 200 MHz
    clk_out2 : out std_logic;   -- 100 MHz
    locked   : out std_logic;
    reset    : in  std_logic
  );
end component;

-- Instantiation
clk_inst : clk_wiz_0
  port map (
    clk_in1  => sys_clk,
    clk_out1 => clk_200,
    clk_out2 => clk_100,
    locked   => pll_locked,
    reset    => '0'
  );
```

---

## Notes on IP Management

- Always commit `.xci` files (IP configuration) to version control, **not** the generated output products.
- Add generated output directories to `.gitignore`:
  ```
  ip/*/sim/
  ip/*/synth/
  ip/*/*.v
  ip/*/*.vhd  # except hand-written wrappers
  ```
- After checkout, run `/ip-core generate` to rebuild output products.
