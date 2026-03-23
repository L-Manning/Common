# utils.tcl
#
# Common TCL utility library for AMD/Xilinx simulation scripts.
# Provides coloured terminal output, named timers, and input validation
# helpers to keep the main scripts readable and consistent.
#
# Compatible with: Vivado 2022.1+ (TCL 8.6), Questasim 2022.4+ (TCL 8.5+)
#
# Usage:
#   source [file join [file dirname [info script]] ../tcl/utils.tcl]
#   # All procs are imported into the global namespace automatically.
#
# Sections:
#   1. Colour / ANSI support
#   2. Logging  (log_info, log_ok, log_warn, log_error, log_step, log_section,
#                log_kv, log_cmd, hr)
#   3. Timers   (timer_start, timer_stop, timer_elapsed_ms, timer_elapsed_str,
#                timer_print)
#   4. Validation (require_file, require_dir, require_env, require_var, die)
#   5. Misc     (getenv, format_bytes, script_dir)

package require Tcl 8.5

namespace eval ::simutils {

    # =======================================================================
    # 1. Colour / ANSI support
    # =======================================================================
    #
    # Colours are enabled by default when stdout looks like a terminal.
    # They are suppressed when:
    #   - The NO_COLOR environment variable is set (https://no-color.org/)
    #   - TERM is set to "dumb"
    #   - The SIM_NO_COLOR environment variable is set to "1"
    #
    # Individual scripts can also call: simutils::set_colors 0

    variable colors_enabled 1

    if { [info exists ::env(NO_COLOR)]
      || ([info exists ::env(TERM)]        && $::env(TERM)        eq "dumb")
      || ([info exists ::env(SIM_NO_COLOR)] && $::env(SIM_NO_COLOR) eq "1") } {
        set colors_enabled 0
    }

    # ANSI SGR colour/attribute codes
    variable _C
    array set _C {
        reset    ""   bold     ""   dim      ""   italic   ""
        red      ""   green    ""   yellow   ""   blue     ""
        cyan     ""   magenta  ""   white    ""
        b_red    ""   b_green  ""   b_yellow ""   b_blue   ""
        b_cyan   ""   b_white  ""
    }

    if { $colors_enabled } {
        array set _C {
            reset    "\x1b\[0m"
            bold     "\x1b\[1m"
            dim      "\x1b\[2m"
            italic   "\x1b\[3m"
            red      "\x1b\[31m"
            green    "\x1b\[32m"
            yellow   "\x1b\[33m"
            blue     "\x1b\[34m"
            magenta  "\x1b\[35m"
            cyan     "\x1b\[36m"
            white    "\x1b\[37m"
            b_red    "\x1b\[1;31m"
            b_green  "\x1b\[1;32m"
            b_yellow "\x1b\[1;33m"
            b_blue   "\x1b\[1;34m"
            b_cyan   "\x1b\[1;36m"
            b_white  "\x1b\[1;37m"
        }
    }

    # Programmatically enable or disable colour output at runtime.
    #   simutils::set_colors 0   ;# disable
    #   simutils::set_colors 1   ;# enable
    proc set_colors { on } {
        variable colors_enabled
        variable _C
        set colors_enabled $on
        if { !$on } {
            foreach k [array names _C] { set _C($k) "" }
        } else {
            # Re-source to repopulate (simplest approach)
            source [info script]
        }
    }

    # Return an ANSI colour string by name.  Returns empty string if colours
    # are disabled.  Valid names: reset bold dim red green yellow blue cyan
    # magenta white b_red b_green b_yellow b_blue b_cyan b_white
    proc color { name } {
        variable _C
        if { [info exists _C($name)] } { return $::simutils::_C($name) }
        return ""
    }

    # =======================================================================
    # 2. Logging
    # =======================================================================
    #
    # All log procs write to stdout except log_warn and log_error which write
    # to stderr so they are visible even when stdout is redirected to a file.
    #
    # Timestamp format: HH:MM:SS  (wall-clock, local time)

    proc _ts {} {
        return [clock format [clock seconds] -format "%H:%M:%S"]
    }

    # [INFO]  HH:MM:SS  message  — cyan tag, plain message
    proc log_info { msg } {
        variable _C
        puts "$_C(cyan)\[INFO\]$_C(reset)  [_ts]  $msg"
    }

    # [OK]    HH:MM:SS  message  — bold green tag, for successful completion
    proc log_ok { msg } {
        variable _C
        puts "$_C(b_green)\[OK\]$_C(reset)    [_ts]  $msg"
    }

    # [WARN]  HH:MM:SS  message  — bold yellow tag, to stderr
    proc log_warn { msg } {
        variable _C
        puts stderr "$_C(b_yellow)\[WARN\]$_C(reset)  [_ts]  $msg"
    }

    # [ERROR] HH:MM:SS  message  — bold red tag, to stderr
    proc log_error { msg } {
        variable _C
        puts stderr "$_C(b_red)\[ERROR\]$_C(reset) [_ts]  $msg"
    }

    # Numbered step banner, e.g. "── Step 2: Write MMI file"
    proc log_step { n label } {
        variable _C
        puts "\n$_C(b_blue)── Step $n:$_C(reset) $_C(bold)$label$_C(reset)"
    }

    # Full-width section banner with double-line borders
    proc log_section { title } {
        variable _C
        set w 68
        set inner [expr { $w - 4 }]
        set lpad  [expr { ($inner - [string length $title]) / 2 }]
        set rpad  [expr { $inner - $lpad - [string length $title] }]
        set bar   [string repeat "\u2550" $w]
        puts ""
        puts "$_C(b_cyan)$bar$_C(reset)"
        puts "$_C(b_cyan)\u2551$_C(reset) [string repeat " " $lpad]$_C(bold)$title$_C(reset)[string repeat " " $rpad] $\
_C(b_cyan)\u2551$_C(reset)"
        puts "$_C(b_cyan)$bar$_C(reset)"
        puts ""
    }

    # Key-value pair, nicely aligned — used for configuration summaries
    #   log_kv "ELF_FILE"  "/path/to/fw.elf"
    proc log_kv { key val } {
        variable _C
        puts "  $_C(bold)[format "%-20s" $key]$_C(reset)$_C(dim) =>$_C(reset) $val"
    }

    # Print a command that is about to be executed (dim, indented)
    proc log_cmd { args } {
        variable _C
        puts "$_C(dim)  \$ [join $args { }]$_C(reset)"
    }

    # Horizontal rule
    #   hr          — thin line, full width
    #   hr "═" 40   — custom character and width
    proc hr { {char "\u2500"} {width 68} } {
        variable _C
        puts "$_C(dim)[string repeat $char $width]$_C(reset)"
    }

    # =======================================================================
    # 3. Timers
    # =======================================================================
    #
    # Named wall-clock timers using clock milliseconds (TCL 8.5+).
    # Multiple independent timers can be active simultaneously.
    #
    # Example:
    #   timer_start  "updatemem"
    #   ... do work ...
    #   timer_stop   "updatemem" "updatemem"   ;# prints elapsed and clears
    #
    # Or keep the timer and query it multiple times:
    #   timer_start     "total"
    #   log_info "partial: [timer_elapsed_str total]"
    #   timer_print     "total" "Overall so far"

    variable _timers
    array set _timers {}

    # Record the current wall-clock time for a named timer.
    proc timer_start { name } {
        variable _timers
        set _timers($name) [clock milliseconds]
    }

    # Return elapsed time in milliseconds since timer_start {name}.
    # Returns 0 if the timer was never started.
    proc timer_elapsed_ms { name } {
        variable _timers
        if { ![info exists _timers($name)] } { return 0 }
        return [expr { [clock milliseconds] - $_timers($name) }]
    }

    # Return a human-readable elapsed string:
    #   < 1 s   -> "NNNms"
    #   < 60 s  -> "NNs"
    #   >= 60 s -> "NNm NNs"
    proc timer_elapsed_str { name } {
        set ms [timer_elapsed_ms $name]
        if { $ms < 1000 } { return "${ms}ms" }
        set s  [expr { $ms / 1000 }]
        if { $s < 60  } { return "${s}s" }
        set m  [expr { $s / 60 }]
        set rs [expr { $s % 60 }]
        return "${m}m ${rs}s"
    }

    # Print elapsed time without stopping the timer.
    # label defaults to the timer name.
    proc timer_print { name {label ""} } {
        variable _C
        if { $label eq "" } { set label $name }
        puts "  $_C(dim)${label}:$_C(reset) $_C(green)[timer_elapsed_str $name]$_C(reset)"
    }

    # Print elapsed time and clear the timer entry.
    proc timer_stop { name {label ""} } {
        timer_print $name $label
        variable _timers
        unset -nocomplain _timers($name)
    }

    # =======================================================================
    # 4. Validation helpers
    # =======================================================================

    # Print a bold red error and exit with code 1.
    # Optionally provide a hint for how to fix the problem.
    #   die "MMI file not found: $path"
    #   die "ELF not found" "Run 'make firmware' to build it"
    proc die { msg {hint ""} } {
        log_error $msg
        if { $hint ne "" } {
            variable _C
            puts stderr "  $_C(dim)Hint: $hint$_C(reset)"
        }
        exit 1
    }

    # Abort if a file does not exist.
    #   require_file $elf_file "ELF firmware"
    proc require_file { path {desc "file"} {hint ""} } {
        if { ![file exists $path] } {
            die "$desc not found: $path" $hint
        }
    }

    # Abort if a path is not a directory.
    # Pass create=1 to create it instead of aborting.
    #   require_dir $output_dir "" 1   ;# create if missing
    proc require_dir { path {desc "directory"} {create 0} } {
        if { ![file isdirectory $path] } {
            if { $create } {
                file mkdir $path
                log_info "Created directory: $path"
            } else {
                die "$desc not found: $path"
            }
        }
    }

    # Abort if an environment variable is not set or empty.
    # Returns the value on success.
    #   set vivado_root [require_env XILINX_VIVADO "Vivado install root"]
    proc require_env { name {desc ""} {hint ""} } {
        if { $desc eq "" } { set desc "\$$name" }
        if { ![info exists ::env($name)] || $::env($name) eq "" } {
            die "Required environment variable not set: $name ($desc)" $hint
        }
        return $::env($name)
    }

    # Abort if a TCL variable (in the caller's scope) is empty or unset.
    #   require_var project_xpr "PROJECT_XPR"
    proc require_var { varname desc {hint ""} } {
        upvar 1 $varname v
        if { ![info exists v] || $v eq "" } {
            die "$desc is required but not set (\$$varname)" $hint
        }
    }

    # =======================================================================
    # 5. Miscellaneous
    # =======================================================================

    # Read an environment variable, returning default if unset or empty.
    # Identical to the inline getenv proc used in sim.do / other scripts,
    # centralised here.
    #   set batch [getenv QUESTA_BATCH "0"]
    proc getenv { name default } {
        if { [info exists ::env($name)] && $::env($name) ne "" } {
            return $::env($name)
        }
        return $default
    }

    # Format a byte count as a human-readable string.
    #   format_bytes 1048576  -> "1.0 MiB"
    proc format_bytes { bytes } {
        foreach { divisor suffix } {
            1073741824 GiB
            1048576    MiB
            1024       KiB
        } {
            if { $bytes >= $divisor } {
                return [format "%.1f %s" [expr { double($bytes) / $divisor }] $suffix]
            }
        }
        return "${bytes} B"
    }

    # Return the directory containing the currently executing script.
    # Works in Vivado batch mode and Questasim do-files.
    proc script_dir {} {
        set s [info script]
        if { $s eq "" } { return [pwd] }
        return [file normalize [file dirname $s]]
    }

    # =======================================================================
    # Namespace export — import everything into the global namespace
    # =======================================================================
    namespace export \
        set_colors color \
        log_info log_ok log_warn log_error log_step log_section log_kv log_cmd hr \
        timer_start timer_stop timer_elapsed_ms timer_elapsed_str timer_print \
        die require_file require_dir require_env require_var \
        getenv format_bytes script_dir
}

namespace import ::simutils::*
