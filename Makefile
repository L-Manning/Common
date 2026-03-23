# Makefile
#
# Orchestrates the full AMD/Xilinx MicroBlaze Block Design simulation flow:
#
#   1. export-sim  — Export Questasim IP compile scripts from Vivado (one-time)
#   2. gen-mem     — Convert ELF -> MMI -> .mem -> load_elf.tcl via Vivado
#   3. sim         — Compile + elaborate + load ELF + run in Questasim
#
# Prerequisites:
#   - Copy project.mk.example to project.mk (in your project root or here)
#     and fill in the required variables.
#   - Vivado 2022.1+ must be on PATH (or set VIVADO= in project.mk)
#   - Questasim 2022.4+ must be on PATH (or set QUESTA_VSIM= in project.mk)
#
# Usage:
#   cp project.mk.example project.mk
#   # edit project.mk
#   make export-sim          # once, or after IP/BD changes
#   make gen-mem             # after ELF rebuild
#   make sim                 # compile + run simulation
#   make sim QUESTA_BATCH=1  # headless / CI mode

# ---------------------------------------------------------------------------
# Locate this Makefile so script paths are always correct regardless of where
# make is invoked from
# ---------------------------------------------------------------------------
COMMON_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS_VIVADO  := $(COMMON_DIR)sim/xilinx_mb/vivado
SCRIPTS_QUESTA  := $(COMMON_DIR)sim/xilinx_mb/questasim

# ---------------------------------------------------------------------------
# Load per-project configuration
# ---------------------------------------------------------------------------
# Look for project.mk first in the invoking directory, then here in Common.
PROJECT_MK_SEARCH := $(wildcard project.mk) $(wildcard $(COMMON_DIR)project.mk)
PROJECT_MK        := $(firstword $(PROJECT_MK_SEARCH))

ifeq ($(PROJECT_MK),)
$(error No project.mk found. Copy $(COMMON_DIR)project.mk.example to project.mk and fill in the values.)
endif

include $(PROJECT_MK)

# ---------------------------------------------------------------------------
# Defaults for variables that project.mk may not define
# ---------------------------------------------------------------------------
VIVADO           ?= vivado
QUESTA_VSIM      ?= vsim
OUTPUT_DIR       ?= build
SIM_TOP          ?= tb_top
SIM_LIB_DIR      ?=
ELF_FILE         ?=
PROJECT_XPR      ?=
BD_NAME          ?= system
PROC_INSTANCE    ?= system_i/microblaze_0
VSIM_EXTRA_ARGS  ?=
SIM_RUN_TIME     ?= -all
QUESTA_BATCH     ?= 0

# ---------------------------------------------------------------------------
# Derived paths (all absolute so scripts are location-independent)
# ---------------------------------------------------------------------------
ABS_OUTPUT_DIR   := $(abspath $(OUTPUT_DIR))
ABS_PROJECT_XPR  := $(abspath $(PROJECT_XPR))
ABS_ELF_FILE     := $(abspath $(ELF_FILE))

MMI_FILE         := $(ABS_OUTPUT_DIR)/$(BD_NAME).mmi
MEM_FILE         := $(ABS_OUTPUT_DIR)/firmware_updated.mem
LOAD_ELF_TCL     := $(ABS_OUTPUT_DIR)/load_elf.tcl
QUESTA_DIR       := $(ABS_OUTPUT_DIR)/questa_sim
# The compile script name matches the top-level wrapper Vivado generates
COMPILE_DO       := $(shell ls $(QUESTA_DIR)/*_compile.do 2>/dev/null | head -1)

# ---------------------------------------------------------------------------
# Validate required variables before running targets that need them
# ---------------------------------------------------------------------------
.PHONY: check-env
check-env:
	@echo "--- Environment check ---"
	@echo "VIVADO        = $(VIVADO)"
	@echo "QUESTA_VSIM   = $(QUESTA_VSIM)"
	@echo "PROJECT_XPR   = $(ABS_PROJECT_XPR)"
	@echo "ELF_FILE      = $(ABS_ELF_FILE)"
	@echo "BD_NAME       = $(BD_NAME)"
	@echo "PROC_INSTANCE = $(PROC_INSTANCE)"
	@echo "SIM_TOP       = $(SIM_TOP)"
	@echo "SIM_LIB_DIR   = $(SIM_LIB_DIR)"
	@echo "OUTPUT_DIR    = $(ABS_OUTPUT_DIR)"
	@test -n "$(ABS_PROJECT_XPR)" || (echo "ERROR: PROJECT_XPR is not set in project.mk"; exit 1)
	@test -f "$(ABS_PROJECT_XPR)" || (echo "ERROR: PROJECT_XPR not found: $(ABS_PROJECT_XPR)"; exit 1)
	@test -n "$(ABS_ELF_FILE)"    || (echo "ERROR: ELF_FILE is not set in project.mk"; exit 1)
	@command -v $(VIVADO)       >/dev/null 2>&1 || (echo "ERROR: vivado not found on PATH (set VIVADO= in project.mk)"; exit 1)
	@command -v $(QUESTA_VSIM)  >/dev/null 2>&1 || (echo "ERROR: vsim not found on PATH (set QUESTA_VSIM= in project.mk)"; exit 1)
	@echo "--- All checks passed ---"

# ---------------------------------------------------------------------------
# Target: export-sim
#
# Exports Questasim IP compile scripts from the Vivado project.
# Only needs to run when the IP cores or Block Design change.
#
# A sentinel file (.export_done) is written on success so Make can track
# whether re-export is needed.
# ---------------------------------------------------------------------------
EXPORT_SENTINEL := $(ABS_OUTPUT_DIR)/.export_done

.PHONY: export-sim
export-sim: check-env $(EXPORT_SENTINEL)

$(EXPORT_SENTINEL): $(ABS_PROJECT_XPR)
	@echo "=== Step 1: Exporting simulation files from Vivado ==="
	@mkdir -p $(ABS_OUTPUT_DIR)
	$(VIVADO) -mode batch \
	    -source $(SCRIPTS_VIVADO)/export_sim.tcl \
	    -tclargs "$(ABS_PROJECT_XPR)" "$(ABS_OUTPUT_DIR)"
	@touch $@
	@echo "=== export-sim done ==="

# ---------------------------------------------------------------------------
# Target: gen-mem
#
# Generates the MMI file, runs updatemem to produce firmware_updated.mem,
# and runs write_mem_tcl to produce load_elf.tcl for Questasim.
#
# Re-runs whenever the ELF file changes.
# ---------------------------------------------------------------------------
.PHONY: gen-mem
gen-mem: check-env $(LOAD_ELF_TCL)

$(LOAD_ELF_TCL): $(ABS_ELF_FILE) $(ABS_PROJECT_XPR)
	@test -f "$(ABS_ELF_FILE)" || (echo "ERROR: ELF file not found: $(ABS_ELF_FILE)"; exit 1)
	@echo "=== Step 2: Generating mem files from ELF ==="
	@mkdir -p $(ABS_OUTPUT_DIR)
	$(VIVADO) -mode batch \
	    -source $(SCRIPTS_VIVADO)/gen_mem_files.tcl \
	    -tclargs "$(ABS_PROJECT_XPR)" \
	             "$(ABS_ELF_FILE)" \
	             "$(BD_NAME)" \
	             "$(PROC_INSTANCE)" \
	             "$(ABS_OUTPUT_DIR)"
	@echo "=== gen-mem done ==="

# ---------------------------------------------------------------------------
# Target: sim
#
# Compiles HDL (via the Vivado-exported compile script), elaborates, loads
# the ELF into BRAM via mem load, then runs the simulation.
#
# Depends on gen-mem (which in turn depends on export-sim having been run).
# ---------------------------------------------------------------------------
.PHONY: sim
sim: gen-mem
	@test -n "$(COMPILE_DO)" || \
	    (echo "ERROR: No *_compile.do found in $(QUESTA_DIR)."; \
	     echo "       Run 'make export-sim' first."; exit 1)
	@echo "=== Step 3: Running Questasim simulation ==="
	QUESTA_WORK_LIB="work" \
	QUESTA_COMPILE_DO="$(COMPILE_DO)" \
	QUESTA_SIM_TOP="$(SIM_TOP)" \
	QUESTA_SIM_LIB_DIR="$(SIM_LIB_DIR)" \
	QUESTA_LOAD_ELF_TCL="$(LOAD_ELF_TCL)" \
	QUESTA_WAVE_DO="$(SCRIPTS_QUESTA)/wave.do" \
	QUESTA_RUN_TIME="$(SIM_RUN_TIME)" \
	VSIM_EXTRA_ARGS="$(VSIM_EXTRA_ARGS)" \
	QUESTA_BATCH="$(QUESTA_BATCH)" \
	$(QUESTA_VSIM) -batch -do $(SCRIPTS_QUESTA)/sim.do
	@echo "=== sim done ==="

# Convenience alias: run headless (CI)
.PHONY: sim-batch
sim-batch: QUESTA_BATCH=1
sim-batch: sim

# ---------------------------------------------------------------------------
# Target: clean
# ---------------------------------------------------------------------------
.PHONY: clean
clean:
	@echo "Removing $(ABS_OUTPUT_DIR)"
	rm -rf $(ABS_OUTPUT_DIR)

# ---------------------------------------------------------------------------
# Target: help
# ---------------------------------------------------------------------------
.PHONY: help
help:
	@echo ""
	@echo "AMD MicroBlaze Block Design — Questasim Simulation"
	@echo "==================================================="
	@echo ""
	@echo "Setup:"
	@echo "  1. Copy project.mk.example to project.mk"
	@echo "  2. Fill in PROJECT_XPR, ELF_FILE, BD_NAME, PROC_INSTANCE, etc."
	@echo ""
	@echo "Targets:"
	@echo "  make check-env    Validate all required variables and tool paths"
	@echo "  make export-sim   Export Questasim compile scripts from Vivado"
	@echo "                    (one-time; re-run after IP or BD changes)"
	@echo "  make gen-mem      Convert ELF -> MMI -> .mem -> load_elf.tcl"
	@echo "                    (re-run after every ELF rebuild)"
	@echo "  make sim          Compile + elaborate + load ELF + run simulation"
	@echo "  make sim-batch    Same as sim but forces QUESTA_BATCH=1 (no GUI)"
	@echo "  make clean        Remove all generated files ($(OUTPUT_DIR)/)"
	@echo ""
	@echo "Variables (override on command line or in project.mk):"
	@echo "  VIVADO=$(VIVADO)"
	@echo "  QUESTA_VSIM=$(QUESTA_VSIM)"
	@echo "  PROJECT_XPR=$(PROJECT_XPR)"
	@echo "  ELF_FILE=$(ELF_FILE)"
	@echo "  BD_NAME=$(BD_NAME)"
	@echo "  PROC_INSTANCE=$(PROC_INSTANCE)"
	@echo "  SIM_TOP=$(SIM_TOP)"
	@echo "  SIM_LIB_DIR=$(SIM_LIB_DIR)"
	@echo "  OUTPUT_DIR=$(OUTPUT_DIR)"
	@echo "  SIM_RUN_TIME=$(SIM_RUN_TIME)"
	@echo "  QUESTA_BATCH=$(QUESTA_BATCH)"
	@echo ""
