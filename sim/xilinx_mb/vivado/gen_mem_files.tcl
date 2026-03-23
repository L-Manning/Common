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
#   <BD_NAME>.mmi        - Memory Map Information file
#   firmware_updated.mem - ELF content as BRAM initialisation data
#   load_elf.tcl         - Questasim "mem load" script (source this in sim.do)

source [file join [file dirname [info script]] ../tcl/utils.tcl]

timer_start "total"

log_section "gen_mem_files — Vivado ELF → mem flow"

# ---------------------------------------------------------------------------
# Minimum version check
# ---------------------------------------------------------------------------
proc check_vivado_version { required } {
    set current [version -short]
    # Compare as "YYYY.N" strings — lexicographic order matches release order
    if { [string compare $current $required] < 0 } {
        die "Vivado $required or later is required (write_mem_tcl was added in 2022.1)." \
            "Current version: $current"
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

set project_xpr   [file normalize [lindex $argv 0]]
set elf_file      [file normalize [lindex $argv 1]]
set bd_name       [lindex $argv 2]
set proc_instance [lindex $argv 3]
set output_dir    [file normalize [lindex $argv 4]]

log_info "Configuration:"
log_kv "PROJECT_XPR"   $project_xpr
log_kv "ELF_FILE"      $elf_file
log_kv "BD_NAME"       $bd_name
log_kv "PROC_INSTANCE" $proc_instance
log_kv "OUTPUT_DIR"    $output_dir
hr

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
require_file $project_xpr "Vivado project (.xpr)"
require_file $elf_file    "ELF firmware file" \
    "Build the firmware first; check that ELF_FILE in project.mk is correct."
require_dir  $output_dir  "Output directory" 1

# ---------------------------------------------------------------------------
# Step 1: Open project and implementation run
# ---------------------------------------------------------------------------
log_step 1 "Open Vivado project"
timer_start "open_project"

if { [catch { open_project $project_xpr } err] } {
    die "Failed to open project: $err"
}

# Try the implementation run first; fall back to synthesis for designs that
# have not been fully implemented yet.
set run_opened 0
foreach run_name { impl_1 synth_1 } {
    set runs [get_runs $run_name]
    if { [llength $runs] == 0 } { continue }
    log_info "Opening run: $run_name"
    if { [catch { open_run $run_name } err] } {
        log_warn "Could not open '$run_name': $err"
        continue
    }
    set run_opened 1
    break
}

if { !$run_opened } {
    die "No completed synthesis or implementation run found in project." \
        "Run at least Synthesis in Vivado before calling this script."
}

timer_stop "open_project" "Project opened"

# ---------------------------------------------------------------------------
# Step 2: Write MMI (Memory Map Information) file
# ---------------------------------------------------------------------------
log_step 2 "Write MMI file (write_mem_info)"
timer_start "write_mmi"

set mmi_file [file join $output_dir "${bd_name}.mmi"]
log_info "Output: $mmi_file"

if { [catch { write_mem_info -force $mmi_file } err] } {
    die "write_mem_info failed: $err"
}
require_file $mmi_file "Generated MMI file"

set mmi_size [file size $mmi_file]
log_ok "MMI written ([format_bytes $mmi_size])"
timer_stop "write_mmi" "write_mem_info"

# ---------------------------------------------------------------------------
# Step 3: Run updatemem
#
# updatemem is a standalone binary shipped with Vivado.  Resolve it from the
# currently running installation via $XILINX_VIVADO so the script is portable.
# ---------------------------------------------------------------------------
log_step 3 "Run updatemem (ELF → per-BRAM .mem)"
timer_start "updatemem"

set xilinx_vivado [require_env XILINX_VIVADO "Vivado installation root"]
set updatemem_bin [file join $xilinx_vivado bin updatemem]
if { ![file exists $updatemem_bin] } {
    # Some installations place binaries one level up
    set updatemem_bin [file join [file dirname $xilinx_vivado] bin updatemem]
}
require_file $updatemem_bin "updatemem binary" \
    "Check that XILINX_VIVADO is set correctly: $xilinx_vivado"

set mem_out_file [file join $output_dir "firmware_updated.mem"]

set updatemem_cmd [list \
    $updatemem_bin  \
    -force          \
    -meminfo $mmi_file      \
    -data    $elf_file      \
    -proc    $proc_instance \
    -bd      $bd_name       \
    -out     $mem_out_file  \
]

log_cmd {*}$updatemem_cmd

if { [catch { exec {*}$updatemem_cmd } out] } {
    log_error "updatemem failed."
    puts stderr $out
    exit 1
}
if { $out ne "" } { puts $out }

require_file $mem_out_file "updatemem output .mem file"
set mem_size [file size $mem_out_file]
log_ok "firmware_updated.mem written ([format_bytes $mem_size])"
timer_stop "updatemem" "updatemem"

# ---------------------------------------------------------------------------
# Step 4: Generate Questasim mem load script via write_mem_tcl
#
# write_mem_tcl must be called while a Vivado simulation is active.  It
# inspects the simulation hierarchy and emits one "mem load" command per BRAM
# instance, pointing to the .mem files that updatemem produced.
# ---------------------------------------------------------------------------
log_step 4 "Generate Questasim mem load script (write_mem_tcl)"
timer_start "write_mem_tcl"

log_info "Launching behavioral simulation (sim_1)..."
if { [catch { launch_simulation -simset sim_1 -mode behavioral } err] } {
    die "launch_simulation failed: $err" \
        "Ensure the project has a 'sim_1' simulation fileset configured."
}

set load_tcl [file join $output_dir "load_elf.tcl"]
log_info "Output: $load_tcl"

if { [catch { write_mem_tcl -force $load_tcl } err] } {
    catch { close_sim }
    die "write_mem_tcl failed: $err"
}

close_sim
require_file $load_tcl "Generated load_elf.tcl"

# Count the mem load commands in the generated script as a quick sanity check
set fd [open $load_tcl r]
set content [read $fd]
close $fd
set mem_load_count [llength [regexp -all -inline {mem load} $content]]
log_ok "load_elf.tcl written ($mem_load_count mem load command(s))"
timer_stop "write_mem_tcl" "write_mem_tcl"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
close_project

hr "═"
log_ok "gen_mem_files completed  ([timer_elapsed_str total])"
hr "═"
puts ""
log_info "Outputs:"
log_kv "MMI file"    $mmi_file
log_kv "MEM file"    $mem_out_file
log_kv "Questa TCL"  $load_tcl
puts ""
log_info "Next: source load_elf.tcl inside Questasim after vsim elaboration (sim.do)."
