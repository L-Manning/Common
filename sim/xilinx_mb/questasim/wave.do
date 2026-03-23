# wave.do
#
# Questasim waveform configuration stub.
#
# This file is sourced by sim.do after elaboration (vsim) and after the ELF
# has been loaded into BRAM.  Add "add wave" commands here to configure the
# waveform viewer for your testbench.
#
# This file is not sourced when running in batch mode (QUESTA_BATCH=1).
#
# Example commands:
#
#   # Clock and reset
#   add wave -divider "Clocks / Resets"
#   add wave -radix bin  /tb_top/clk
#   add wave -radix bin  /tb_top/resetn
#
#   # MicroBlaze AXI debug signals
#   add wave -divider "MicroBlaze"
#   add wave -radix hex  /tb_top/DUT/bd_i/microblaze_0/M_AXI_DP_ARADDR
#   add wave -radix hex  /tb_top/DUT/bd_i/microblaze_0/M_AXI_DP_RDATA
#
#   # UART TX (useful for seeing firmware printf output)
#   add wave -divider "UART"
#   add wave -radix bin  /tb_top/DUT/bd_i/axi_uartlite_0/tx
#
#   # Zoom waveform window to fit
#   wave zoom full

# Add your waveform configuration below:
