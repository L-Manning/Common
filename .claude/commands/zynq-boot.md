# Zynq Boot Skill

Create AMD Xilinx Zynq-7000 and Zynq UltraScale+ (MPSoC/RFSoC) boot images combining the FSBL, bitstream, and application ELF using `bootgen`.

## Usage

```
/zynq-boot [options]
```

**Options:**
- `device=zynq7|zynqmp` — Target SoC family (default: auto-detect from bitstream header).
- `fsbl=<path>` — Path to FSBL ELF (default: `software/fsbl/fsbl.elf`).
- `bit=<path>` — Path to PL bitstream (default: `bitstream/design.bit`; omit for PS-only image).
- `elf=<path>` — Path to application ELF (default: `software/app/app.elf`; may be repeated for multiple ELFs).
- `pmufw=<path>` — (Zynq MPSoC only) PMU firmware ELF (default: `software/pmufw/pmufw.elf`).
- `atf=<path>` — (Zynq MPSoC only) ARM Trusted Firmware ELF.
- `uboot=<path>` — (Zynq MPSoC only) U-Boot ELF/image.
- `boot=<path>` — Output BOOT.BIN path (default: `boot/BOOT.BIN`).
- `encrypt=none|aes` — Encryption mode (default: `none`).
- `auth=none|rsa` — Authentication mode (default: `none`).

---

## What This Skill Does

1. Verifies all input files exist.
2. Generates the appropriate `.bif` (Boot Image Format) file.
3. Runs `bootgen` to produce `BOOT.BIN`.
4. Reports image partition sizes and load addresses.
5. Optionally programs the SD card or QSPI flash.

---

## Zynq-7000 Flow

### Typical boot image contents

| Partition | Required | Description |
|---|---|---|
| FSBL | Yes | First Stage Boot Loader (runs from OCM) |
| Bitstream | No | PL configuration (if design uses PL) |
| Application ELF | Yes | Bare-metal app or U-Boot |

### BIF file — Zynq-7000

`/zynq-boot` generates this `.bif` file at `boot/zynq7.bif`:

```
//arch = zynq; split = false; format = BIN
the_ROM_image:
{
    [bootloader] software/fsbl/fsbl.elf
    bitstream/design.bit
    software/app/app.elf
}
```

For a PS-only image (no PL):
```
the_ROM_image:
{
    [bootloader] software/fsbl/fsbl.elf
    software/app/app.elf
}
```

### Run bootgen — Zynq-7000

```bash
mkdir -p boot
bootgen -image boot/zynq7.bif -arch zynq -o boot/BOOT.BIN -w on
```

`-w on` overwrites an existing `BOOT.BIN`. Remove it to avoid accidental overwrite.

Verify output:
```bash
bootgen -image boot/zynq7.bif -arch zynq -o boot/BOOT.BIN -w on -log info 2>&1 \
    | tee boot/bootgen.log
```

---

## Zynq UltraScale+ MPSoC Flow

### Typical boot image contents

| Partition | Required | Description |
|---|---|---|
| FSBL | Yes | First Stage Boot Loader (runs from OCM, Cortex-R5) |
| PMU Firmware | Yes | PMU subsystem firmware |
| ATF (TF-A) | No (Linux) | ARM Trusted Firmware (BL31), required for Linux |
| U-Boot | No (Linux) | Secondary bootloader |
| Bitstream | No | PL configuration |
| Application ELF | Yes | Bare-metal or Linux image |

### BIF file — Zynq MPSoC (bare-metal)

`boot/zynqmp_baremetal.bif`:
```
//arch = zynqmp; split = false; format = BIN
the_ROM_image:
{
    [fsbl_config] a53_x64
    [bootloader, destination_cpu=a53-0] software/fsbl/fsbl.elf
    [pmufw_image]                        software/pmufw/pmufw.elf
    [destination_device=pl]              bitstream/design.bit
    [destination_cpu=a53-0, exception_level=el-3, trustzone] software/atf/bl31.elf
    [destination_cpu=a53-0, exception_level=el-2] software/app/app.elf
}
```

### BIF file — Zynq MPSoC (Linux with U-Boot)

`boot/zynqmp_linux.bif`:
```
//arch = zynqmp; split = false; format = BIN
the_ROM_image:
{
    [fsbl_config] a53_x64
    [bootloader, destination_cpu=a53-0] software/fsbl/fsbl.elf
    [pmufw_image]                        software/pmufw/pmufw.elf
    [destination_device=pl]              bitstream/design.bit
    [destination_cpu=a53-0, exception_level=el-3, trustzone] software/atf/bl31.elf
    [destination_cpu=a53-0, exception_level=el-2] software/uboot/u-boot.elf
}
```

### Run bootgen — Zynq MPSoC

```bash
mkdir -p boot
bootgen -image boot/zynqmp_baremetal.bif -arch zynqmp -o boot/BOOT.BIN -w on
```

---

## Building the FSBL

If the FSBL ELF does not exist, build it from the hardware description:

### Via Vitis (command line)

```bash
# Export hardware description from Vivado first
vivado -mode batch -source - <<'EOF'
open_checkpoint checkpoints/impl.dcp
write_hw_platform -fixed -include_bit -force hw/design_1_wrapper.xsa
EOF

# Create FSBL project in Vitis
xsct <<'EOF'
setws vitis_workspace
platform create -name fsbl_platform -hw hw/design_1_wrapper.xsa
platform active fsbl_platform
domain create -name fsbl_domain -proc psu_cortexa53_0 -os standalone
platform generate

app create -name fsbl_app -platform fsbl_platform -domain fsbl_domain \
    -template "Zynq MP FSBL"
app build -name fsbl_app
EOF

# Copy FSBL to expected location
cp vitis_workspace/fsbl_app/Debug/fsbl_app.elf software/fsbl/fsbl.elf
```

### FSBL for Zynq-7000 (classic SDK/Vitis)

```bash
xsct <<'EOF'
setws vitis_workspace
platform create -name zynq7_platform -hw hw/design_wrapper.xsa
platform active zynq7_platform
domain create -name fsbl_domain -proc ps7_cortexa9_0 -os standalone
platform generate

app create -name fsbl_app -platform zynq7_platform -domain fsbl_domain \
    -template "Zynq FSBL"
app build -name fsbl_app
EOF
cp vitis_workspace/fsbl_app/Debug/fsbl_app.elf software/fsbl/fsbl.elf
```

---

## Programming the Boot Device

### SD card (most common for development)

```bash
# Assuming SD card mounted at /dev/sdb1 (FAT32 partition)
# NEVER use /dev/sda — verify the device first
lsblk | grep -v loop

sudo cp boot/BOOT.BIN /media/$USER/BOOT/
sudo sync
```

For Linux boot, also copy:
```bash
sudo cp software/linux/Image      /media/$USER/BOOT/
sudo cp software/linux/system.dtb /media/$USER/BOOT/
sudo cp software/linux/rootfs.ext4 /media/$USER/ROOTFS/   # if separate partition
```

### QSPI flash via Vivado Hardware Manager

```bash
vivado -mode batch -source - <<'EOF'
open_hw_manager
connect_hw_server
open_hw_target

set device [lindex [get_hw_devices xc*] 0]
current_hw_device $device

# Configure for QSPI — adjust flash part for your board
create_hw_cfgmem -hw_device $device \
    [lindex [get_cfgmem_parts {mt25qu512-spi-x1_x2_x4}] 0]

set cfgmem [get_property PROGRAM.HW_CFGMEM $device]
set_property PROGRAM.FILES         {boot/BOOT.BIN} $cfgmem
set_property PROGRAM.ERASE         1 $cfgmem
set_property PROGRAM.CFG_PROGRAM   1 $cfgmem
set_property PROGRAM.VERIFY        1 $cfgmem

program_hw_cfgmem -hw_cfgmem $cfgmem
close_hw_target
EOF
```

---

## Boot Mode Pin Reference

### Zynq-7000 (MIO[6:2])

| Mode | MIO[6] | MIO[5] | MIO[4] | MIO[3] | MIO[2] |
|---|---|---|---|---|---|
| JTAG | 0 | 0 | 0 | 0 | 0 |
| QSPI (single) | 0 | 0 | 1 | 0 | 1 |
| QSPI (dual) | 0 | 0 | 1 | 1 | 0 |
| SD0 | 0 | 1 | 1 | 0 | 1 |
| NAND | 1 | 0 | 0 | 1 | 0 |

### Zynq MPSoC (MODE pins)

| Mode | MODE[3:0] |
|---|---|
| JTAG | 0000 |
| QSPI (24-bit) | 0001 |
| QSPI (32-bit) | 0010 |
| SD0 (2.0) | 0011 |
| NAND | 0100 |
| SD1 (2.0) | 0101 |
| eMMC | 0110 |
| USB | 0111 |

---

## Common bootgen Errors

| Error | Cause | Fix |
|---|---|---|
| `ERROR: Invalid ELF file` | ELF built for wrong processor | Rebuild FSBL for correct CPU (A53 vs R5 vs A9) |
| `ERROR: Bitstream is not compatible` | Bitstream for wrong device | Regenerate bitstream for the exact part |
| `WARNING: destination_cpu not specified` | Ambiguous target | Add `destination_cpu=a53-0` to each partition |
| `ERROR: PMU firmware not found` | Missing `pmufw.elf` for MPSoC | Build PMU firmware in Vitis or omit if not needed |
| Board does not boot from SD | SD not FAT32 or wrong partition | Format SD card: `mkfs.vfat -F 32 /dev/sdb1` |
| Board boots to JTAG despite SD mode | FSBL fails silently | Connect UART; check FSBL debug output at 115200 baud |
| `Could not find bl31.elf` | ATF not built | Build TF-A or use bare-metal without ATF (remove ATF line from BIF) |

---

## Directory Layout for Zynq Projects

```
project/
├── hw/                        # Exported .xsa hardware platform
├── software/
│   ├── fsbl/fsbl.elf          # First Stage Boot Loader
│   ├── pmufw/pmufw.elf        # PMU firmware (MPSoC only)
│   ├── atf/bl31.elf           # ARM Trusted Firmware (Linux only)
│   ├── uboot/u-boot.elf       # U-Boot (Linux only)
│   └── app/app.elf            # Application or Linux Image
├── bitstream/design.bit
└── boot/
    ├── zynq7.bif / zynqmp.bif
    ├── BOOT.BIN
    └── bootgen.log
```
