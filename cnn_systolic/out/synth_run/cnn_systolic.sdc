# ============================================================
# fe-opensta generated SDC — cnn_systolic
# Source: design-facts spec -> gen_sdc.py (fe-opensta SDC mode).
# DEFAULTS ALWAYS ON; optionals emitted only if in the spec.
# QA: bash scripts/qa_sdc.sh <TOP> <NETLIST> <SDC>
# ============================================================

# --- clock clk (always on) ---
create_clock -period 10.0 -name clk [get_ports clk]
set_clock_uncertainty 0.5 [get_clocks clk]
set_clock_latency 0.0 [get_clocks clk]

# --- input timing (per-port) ---
set_input_delay 3.0 -clock clk [get_ports rst_n]

# --- output timing (per-port) ---
set_output_delay 3.0 -clock clk [get_ports uart_tx]
set_load 0.02 [get_ports uart_tx]
set_output_delay 3.0 -clock clk [get_ports led[*]]
set_load 0.02 [get_ports led[*]]

