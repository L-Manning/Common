# Bitstream Program Skill

Program an AMD Xilinx FPGA via JTAG or write the bitstream to an SPI/BPI configuration flash device.

## Usage

```
/bitstream-prog [action] [options]
```

**Actions:**
- `/bitstream-prog jtag` — Program the FPGA directly over JTAG (volatile, lost on power cycle).
- `/bitstream-prog flash` — Write bitstream to configuration flash (non-volatile).
- `/bitstream-prog verify` — Verify the flash contents against the bitstream file.
- `/bitstream-prog readback` — Readback the FPGA configuration for verification (7-Series/UltraScale).

**Options:**
- `bit=<path>` — Path to bitstream file (default: `bitstream/design.bit`).
- `bin=<path>` — Path to binary file for flash (default: `bitstream/design.bin`).
- `cable=<index>` — JTAG cable index if multiple cables connected (default: `0`).
- `device=<index>` — Device index in JTAG chain (default: `0`).

---

## What This Skill Does

1. Detects connected JTAG cables using Vivado Hardware Manager.
2. Opens the hardware target and identifies devices in the chain.
3. Programs the FPGA or configuration flash.
4. Reports programming status (success/failure).

---

## Steps to Execute

### Action: `jtag` — Direct FPGA programming

```tcl
# scripts/program_jtag.tcl
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

# Select device (first in chain by default)
set device [lindex [get_hw_devices] 0]
current_hw_device $device

# Set bitstream file
set_property PROGRAM.FILE {bitstream/design.bit} $device

# Program
puts "Programming FPGA..."
program_hw_devices $device
puts "Programming complete."

refresh_hw_device $device
close_hw_target
disconnect_hw_server
close_hw_manager
```

```bash
vivado -mode batch -source scripts/program_jtag.tcl \
    -log logs/program.log -journal logs/program.jou
```

### Action: `flash` — Configuration flash programming

First generate the `.mcs` or `.bin` file if it doesn't exist:

```tcl
# Generate MCS file for SPI flash
write_cfgmem -force \
    -format mcs \
    -size 128 \
    -interface SPIx4 \
    -loadbit "up 0x0 bitstream/design.bit" \
    bitstream/design.mcs

# OR binary format
write_cfgmem -force \
    -format bin \
    -size 128 \
    -interface SPIx4 \
    -loadbit "up 0x0 bitstream/design.bit" \
    bitstream/design.bin
```

Program the flash:

```tcl
# scripts/program_flash.tcl
open_hw_manager
connect_hw_server
open_hw_target

set device [lindex [get_hw_devices xc*] 0]
current_hw_device $device

# Create flash memory object (adjust part for your flash chip)
# Common flash parts: mt25ql128-spi-x1_x2_x4, s25fl128sxxxxxx0-spi-x1_x2_x4
create_hw_cfgmem -hw_device $device \
    [lindex [get_cfgmem_parts {mt25ql128-spi-x1_x2_x4}] 0]

set cfgmem [get_property PROGRAM.HW_CFGMEM $device]

set_property PROGRAM.ERASE         1 $cfgmem
set_property PROGRAM.CFG_PROGRAM   1 $cfgmem
set_property PROGRAM.VERIFY        1 $cfgmem
set_property PROGRAM.CHECKSUM      0 $cfgmem

set_property PROGRAM.FILES         {bitstream/design.mcs} $cfgmem
set_property PROGRAM.PRM_FILES     {} $cfgmem

# Erase and program
puts "Programming configuration flash..."
startgroup
if {![string equal [get_property PROGRAM.HW_CFGMEM_TYPE $device] \
        [get_property MEM_TYPE [get_property CFGMEM_PART $cfgmem]]]} {
    create_hw_bitstream -hw_device $device \
        [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
    program_hw_devices $device
    refresh_hw_device $device
}
program_hw_cfgmem -hw_cfgmem $cfgmem
endgroup

puts "Flash programming complete. Power cycle the board to boot from flash."
close_hw_target
disconnect_hw_server
close_hw_manager
```

```bash
vivado -mode batch -source scripts/program_flash.tcl \
    -log logs/program_flash.log
```

### Action: `verify`

```tcl
# Verify flash contents
set_property PROGRAM.VERIFY 1 $cfgmem
program_hw_cfgmem -hw_cfgmem $cfgmem
# Vivado reports "Programmed and Verified successfully" on success
```

### Action: `readback` (7-Series / UltraScale only)

```tcl
open_hw_manager
connect_hw_server
open_hw_target
set device [lindex [get_hw_devices xc*] 0]
current_hw_device $device

# Readback bitstream
readback_hw_device $device -readback_file bitstream/readback.rbd

puts "Readback saved to bitstream/readback.rbd"
close_hw_target
```

---

## Using `program_fpga` (Vitis / deprecated SDK)

For Zynq and MicroBlaze designs with an ELF:

```bash
program_fpga \
    -hw   bitstream/design.bit \
    -elf  software/app.elf \
    -url  TCP:localhost:3121
```

---

## Using OpenOCD (alternative to Vivado HW Manager)

```bash
# Install: sudo apt install openocd
openocd \
    -f interface/ftdi/digilent-hs2.cfg \
    -f target/xc7_ft232h.cfg \
    -c "init; xc7_program xc7.tap; exit"
```

For Xilinx targets with custom FTDI cables, adjust the interface config file.

---

## Common Issues

| Issue | Cause | Fix |
|---|---|---|
| `ERROR: No hardware targets` | No JTAG cable detected | Check USB connection; install Vivado cable drivers (`install_drivers`) |
| `ERROR: device not found in chain` | Wrong device index | Run `get_hw_devices` and use correct index |
| `Flash erase timeout` | Flash too large or wrong part specified | Check flash chip marking; update `get_cfgmem_parts` argument |
| FPGA not booting from flash | JTAG mode pin active | Check M[2:0] mode pins on board (SPI = 001 or 101 depending on device) |
| `readback not supported` | Encryption enabled or readback disabled | Check bitstream security settings |
| Bitstream ID mismatch | Bitstream built for different device | Regenerate bitstream for the exact part number |

---

## Flash Part Reference

| Board | Flash Chip | `get_cfgmem_parts` Key |
|---|---|---|
| Arty A7 | Micron N25Q128 | `mt25ql128-spi-x1_x2_x4` |
| KC705 | Micron N25Q256 | `mt25ql256-spi-x1_x2_x4` |
| KCU116 | Micron MT25QU512 | `mt25qu512-spi-x1_x2_x4` |
| ZCU102 | Micron MT25QU512 | `mt25qu512-spi-x1_x2_x4` |
