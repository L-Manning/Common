# VHDL Lint Skill

Check VHDL source files against coding standards for AMD Xilinx FPGA development. Catches common synthesis issues, style violations, and Xilinx-specific pitfalls before running Vivado.

## Usage

```
/vhdl-lint [file or directory]
```

**Examples:**
- `/vhdl-lint` — lint all files in `rtl/`
- `/vhdl-lint rtl/core/my_module.vhd` — lint a single file
- `/vhdl-lint rtl/core/` — lint a directory

---

## What This Skill Does

1. Statically analyzes VHDL files using GHDL (if available) and/or regex-based checks.
2. Checks VHDL-2008 syntax compliance.
3. Flags Xilinx synthesis anti-patterns.
4. Reports violations with file name and line number.

---

## Steps to Execute

### 1. Determine target files

```bash
# If no argument given, find all RTL VHDL files
find rtl/ -name "*.vhd" -o -name "*.vhdl" 2>/dev/null | sort
```

### 2. GHDL syntax check (if available)

```bash
which ghdl && ghdl -a --std=08 --warn-no-hide --warn-library --warn-port \
    $(find rtl/ -name "*.vhd" | sort) 2>&1
```

If GHDL is not installed, note it and proceed with pattern-based checks only.

### 3. Pattern-based checks

For each VHDL file, scan for the following issues:

#### A. Latch inference risk
```bash
# Combinational processes missing default assignments
grep -n "process\b" "$file" | grep -v "rising_edge\|falling_edge\|clk"
```
Manually review: every combinational `process` should assign all outputs at the top before any conditional.

#### B. Missing VHDL-2008 library declarations
Expected header pattern in every RTL file:
```vhdl
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
```
Flag files that use `std_logic_arith` or `std_logic_unsigned` (deprecated Synopsys packages):
```bash
grep -n "std_logic_arith\|std_logic_unsigned\|std_logic_signed" "$file"
```

#### C. Clock gating in RTL (forbidden)
```bash
grep -n "\band\b.*clk\|clk.*\band\b\|gated_clk\|clk_gate" "$file"
```

#### D. Incomplete sensitivity lists (VHDL-93 style)
```bash
grep -n "process\s*(" "$file" | grep -v "process(all)\|process (all)\|process(clk"
```
Suggest converting to `process(all)` (VHDL-2008).

#### E. Use of 'Z' (high-impedance) in internal signals
```bash
grep -n "'Z'\|\"ZZ" "$file"
```
Flag: tri-state logic should only appear at top-level IO ports, not internal signals.

#### F. Use of non-standard integer arithmetic on ports
```bash
grep -n "integer\s\+port\|port.*:\s*integer" "$file"
```
Ports should use `std_logic_vector`; use `numeric_std` for arithmetic.

#### G. Missing reset in registered processes
```bash
grep -n "rising_edge" "$file"
```
Manually verify each registered process includes a reset branch.

#### H. Hardcoded magic numbers (should be constants/generics)
```bash
grep -n '"[01]\{4,\}"' "$file"  # long literals without a named constant
```

#### I. Signal names — check for reserved word conflicts
```bash
# Common VHDL reserved words accidentally used as identifiers
grep -niE "\b(signal|process|variable|entity|architecture|component|port|generic|begin|end|is|in|out|inout|buffer|buffer|others|when|select|with|generate|for|if|case|else|elsif|loop|while|wait|assert|report|severity|true|false|null)\s*\s*:" "$file"
```

#### J. Xilinx-specific: RAM inference check
```bash
grep -n "RAM_STYLE\|rom_style\|ramstyle" "$file"
```
If arrays larger than 512 bits are found without RAM_STYLE attribute, suggest adding one.

### 4. Summarize findings

Produce a table:

```
File                          Line  Severity  Issue
──────────────────────────────────────────────────────────────────
rtl/core/my_module.vhd         42   WARNING   std_logic_arith used (use numeric_std)
rtl/core/my_module.vhd         87   ERROR     Clock gated in RTL
rtl/top/top_level.vhd         120   INFO      Long literal "10110011" — consider named constant
```

Severity levels:
- **ERROR** — Will likely cause synthesis failure or incorrect behavior.
- **WARNING** — Synthesis may succeed but result is not recommended.
- **INFO** — Style/best-practice suggestion.

### 5. Offer to fix

For any auto-fixable issue (e.g., replacing deprecated library imports), offer to apply the fix using the Edit tool after confirming with the user.

---

## Quick Reference: Xilinx Synthesis Checklist

| Check | Pass Criteria |
|---|---|
| VHDL standard | `--std=08` / VHDL-2008 |
| Libraries | `ieee.numeric_std` only (no Synopsys packages) |
| Clocks | No gated clocks; use clock enables |
| Sensitivity lists | `process(all)` or complete explicit list |
| Reset | Every registered process has a reset branch |
| Latches | No unintended latches (all outputs defaulted in comb processes) |
| Tri-state | `'Z'` only on top-level output/inout ports |
| Attributes | `ASYNC_REG` on CDC sync FFs; `RAM_STYLE` on large memories |
| Ports | `std_logic` / `std_logic_vector` (not `integer` or `bit`) |

---

## Installing GHDL (recommended)

```bash
# Ubuntu/Debian
sudo apt install ghdl

# From source / latest release
# https://github.com/ghdl/ghdl/releases
```
