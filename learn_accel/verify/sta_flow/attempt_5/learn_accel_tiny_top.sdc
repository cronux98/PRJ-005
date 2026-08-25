# =============================================================================
# fe-opensta SDC constraints template (OpenSTA 3.1.0 / SDC)
# Placeholders substituted by run_sta.sh: clk_core (clock port) 20.2500 (ns)
#
# DEFAULTS ARE ALWAYS ON. Optional constraints are commented out, each with a
# how/when-to-use note — uncomment only what the module actually needs.
# See references/03-constraints-sdc.md for the full decision table.
# =============================================================================

# --- Clock (ALWAYS ON; port + period come from the wrapper args / RTL) -------
create_clock -period 20.2500 -name clk [get_ports clk_core]

# Use when the clock is not 50% duty:
# create_clock -period 20.2500 -name clk -waveform {0 5} [get_ports clk_core]

# Use when the clock comes from an internal cell (PLL/divider), not a port:
# create_clock -period 20.2500 -name clk [get_pins <inst>/<pin>]

# --- Input timing ------------------------------------------------------------
# Use when inputs are driven by external registers (real I/O timing):
# set_input_delay 1 -clock clk [all_inputs]          # arrival after clk edge
# set_input_delay 1 -clock clk -min [all_inputs]     # hold-corner arrival

# Use to model realistic input drive/slew (instead of ideal):
# set_input_transition 0.1 [all_inputs]              # slew in ns
# set_driving_cell -lib_cell sky130_fd_sc_hd__buf_1 [all_inputs]  # drive strength
# set_drive 1 [all_inputs]                           # relative drive strength

# Use for async resets / signals that must be ignored by timing:
# set_false_path -from [get_ports rst_n]             # no timing on this path
# set_case_analysis 0 [get_ports rst_n]              # hold pin at constant value

# --- Output timing -----------------------------------------------------------
# Use when outputs feed external registers:
# set_output_delay 1 -clock clk [all_outputs]        # required arrival before clk
# set_output_delay 1 -clock clk -min [all_outputs]

# Use to model output loading (capacitance in current units, pF for sky130):
# set_load 10 [all_outputs]

# --- Clock quality (margins, jitter, generated clocks) ------------------------
# set_clock_uncertainty 0.1 [get_clocks clk]         # jitter + skew margin
# set_clock_latency 1 [get_clocks clk]               # ideal source/network latency
# set_clock_transition 0.1 [get_clocks clk]          # clock slew
# create_generated_clock -name clk_div -source [get_ports clk] -divide_by 2 [get_ports clk_div]
# set_clock_groups -asynchronous -group {clk} -group {clk_div}   # async clock domains

# --- Path exceptions (only when the design truly allows them) -----------------
# set_false_path -from [get_ports a] -to [get_ports b]
# set_multicycle_path 2 -setup -from [get_pins ...] -to [get_pins ...]
# set_max_delay 5 -from [get_ports ...] -to [get_ports ...]
