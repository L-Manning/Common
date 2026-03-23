# gen_mem_files.tcl
#
# Vivado TCL script that:
#   1. Opens an existing Vivado project
#   2. Writes the Memory Map Information (MMI) file from the implemented design
#   3. Runs updatemem to fold an ELF file into per-BRAM .mem files
#   4. Opens behavioral simulation and runs write_mem_tcl to generate a
#      Questasim-ready "mem load" TCL script (load_elf.tcl)
#
# Requires: Vivado 2022.1 or later (write_mem_tcl was introduced in 2022.1)
#
# Usage (batch mode):
#   vivado -mode batch -source gen_mem_files.tcl \
#     -tclargs <PROJECT_XPR> <ELF_FILE> <BD_NAME> <PROC_INSTANCE> <OUTPUT_DIR>
#
# Arguments (positional, via -tclargs):
#   PROJECT_XPR    - Path to the .xpr Vivado project file
#   ELF_FILE       - Path to the compiled firmware ELF file
#   BD_NAME        - Block Design name (e.g. "system")
#   PROC_INSTANCE  - MicroBlaze hierarchy path within the BD used by updatemem
#                    (e.g. "system_i/microblaze_0")
#   OUTPUT_DIR     - Directory where MMI, mem, and TCL files are written
#
# Outputs written to OUTPUT_DIR:
#   <BD_NAME>.mmi       - Memory Map Information file
#   firmware_updated.mem - ELF content as BRAM initialisation data
#   load_elf.tcl         - Questasim "mem load" script (source this in sim.do)

# ---------------------------------------------------------------------------
# Minimum version check
# ---------------------------------------------------------------------------
proc check_vivado_version { required } {
    set current [version -short]
    # Compare as "YYYY.N" strings lexicographically — valid for Vivado versioning
    if { [string compare $current $required] < 0 } {
        puts "ERROR: Vivado $required or later is required for write_mem_tcl."
        puts "       Current version: $current"
        exit 1
    }
}

check_vivado_version "2022.1"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if { $argc != 5 } {
    puts "Usage: vivado -mode batch -source gen_mem_files.tcl \\"
    puts "         -tclargs <PROJECT_XPR> <ELF_FILE> <BD_NAME> <PROC_INSTANCE> <OUTPUT_DIR>"
    exit 1
}

set project_xpr    [lindex $argv 0]
set elf_file       [lindex $argv 1]
set bd_name        [lindex $argv 2]
set proc_instance  [lindex $argv 3]
set output_dir     [lindex $argv 4]

# Resolve to absolute paths so all downstream tools agree on locations
set project_xpr   [file normalize $project_xpr]
set elf_file      [file normalize $elf_file]
set output_dir    [file normalize $output_dir]

puts "INFO: gen_mem_files.tcl"
puts "INFO:   PROJECT_XPR   = $project_xpr"
puts "INFO:   ELF_FILE      = $elf_file"
puts "INFO:   BD_NAME       = $bd_name"
puts "INFO:   PROC_INSTANCE = $proc_instance"
puts "INFO:   OUTPUT_DIR    = $output_dir"

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
if { ![file exists $project_xpr] } {
    puts "ERROR: Project file not found: $project_xpr"
    exit 1
}

if { ![file exists $elf_file] } {
    puts "ERROR: ELF file not found: $elf_file"
    exit 1
}

file mkdir $output_dir

# ---------------------------------------------------------------------------
# Step 1: Open project and implementation run
# ---------------------------------------------------------------------------
puts "INFO: Opening project: $project_xpr"
if { [catch { open_project $project_xpr } err] } {
    puts "ERROR: Failed to open project: $err"
    exit 1
}

# Try to open the implementation run first; fall back to synthesis for
# designs that have not been fully implemented.
set run_opened 0
foreach run_name { impl_1 synth_1 } {
    set runs [get_runs $run_name]
    if { [llength $runs] > 0 } {
        puts "INFO: Opening run: $run_name"
        if { [catch { open_run $run_name } err] } {
            puts "WARNING: Could not open run '$run_name': $err"
            continue
        }
        set run_opened 1
        break
    }
}

if { !$run_opened } {
    puts "ERROR: No completed synthesis or implementation run found in project."
    puts "       Please run at least synthesis before using this script."
    exit 1
}

# ---------------------------------------------------------------------------
# Step 2: Write MMI (Memory Map Information) file
# ---------------------------------------------------------------------------
set mmi_file [file join $output_dir "${bd_name}.mmi"]
puts "INFO: Writing MMI file: $mmi_file"

if { [catch { write_mem_info -force $mmi_file } err] } {
    puts "ERROR: write_mem_info failed: $err"
    exit 1
}

if { ![file exists $mmi_file] } {
    puts "ERROR: MMI file was not created: $mmi_file"
    exit 1
}
puts "INFO: MMI file written successfully."

# ---------------------------------------------------------------------------
# Step 3: Run updatemem to produce per-BRAM .mem files from the ELF
# ---------------------------------------------------------------------------
# updatemem is a standalone executable shipped with Vivado.
# Resolve it relative to the currently running Vivado installation so the
# script works regardless of where Vivado is installed.
set updatemem_bin [file join $::env(XILINX_VIVADO) bin updatemem]
if { ![file exists $updatemem_bin] } {
    # Some installations put it directly in the install root
    set updatemem_bin [file join [file dirname $::env(XILINX_VIVADO)] bin updatemem]
}
if { ![file exists $updatemem_bin] } {
    puts "ERROR: Cannot locate updatemem binary."
    puts "       Expected: $::env(XILINX_VIVADO)/bin/updatemem"
    exit 1
}

set mem_out_file [file join $output_dir "firmware_updated.mem"]

set updatemem_args [list \
    $updatemem_bin \
    -force \
    -meminfo $mmi_file \
    -data    $elf_file \
    -proc    $proc_instance \
    -bd      $bd_name \
    -out     $mem_out_file \
]

puts "INFO: Running updatemem..."
puts "INFO:   $updatemem_args"

if { [catch { exec {*}$updatemem_args } out] } {
    # exec raises an error on non-zero exit; print stdout/stderr for diagnosis
    puts "ERROR: updatemem failed."
    puts $out
    exit 1
}
puts $out
puts "INFO: updatemem completed."

if { ![file exists $mem_out_file] } {
    puts "ERROR: updatemem did not produce output file: $mem_out_file"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 4: Open behavioral simulation and run write_mem_tcl
#
# write_mem_tcl must be called while a simulation is active. It inspects the
# simulation hierarchy and emits "mem load" commands for every BRAM instance,
# pointing to the .mem files that updatemem produced.
# ---------------------------------------------------------------------------
puts "INFO: Launching behavioral simulation to run write_mem_tcl..."
if { [catch { launch_simulation -simset sim_1 -mode behavioral } err] } {
    puts "ERROR: launch_simulation failed: $err"
    puts "       Ensure the project has a simulation fileset (sim_1) configured."
    exit 1
}

set load_tcl [file join $output_dir "load_elf.tcl"]
puts "INFO: Running write_mem_tcl -> $load_tcl"

if { [catch { write_mem_tcl -force $load_tcl } err] } {
    puts "ERROR: write_mem_tcl failed: $err"
    close_sim
    exit 1
}

close_sim

if { ![file exists $load_tcl] } {
    puts "ERROR: write_mem_tcl did not produce: $load_tcl"
    exit 1
}
puts "INFO: load_elf.tcl written successfully."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
close_project

puts ""
puts "INFO: gen_mem_files.tcl completed successfully."
puts "INFO: Outputs:"
puts "INFO:   MMI file   : $mmi_file"
puts "INFO:   MEM file   : $mem_out_file"
puts "INFO:   Questa TCL : $load_tcl"
puts ""
puts "INFO: Next step: source load_elf.tcl inside your Questasim simulation"
puts "INFO: after vsim has elaborated the design (see sim.do)."
