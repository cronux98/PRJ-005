# =============================================================================
# fe-opensta STA script (OpenSTA 3.1.0)
# Placeholders substituted by run_sta.sh: /home/smdadmin/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130B/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib out/sta_run/cnn_systolic_synth_sta.v cnn_systolic
#                                      clk 10.1500 out/sta_run/attempt_3
# Default commands are ALWAYS ON. Optional arguments are commented out —
# uncomment only when the module requires them (see references/05-decision-tree.md).
# =============================================================================

# --- Stage 1: Load design (always on) ----------------------------------------
read_liberty /home/smdadmin/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130B/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
# Optional: blackbox/macro stub liberty (e.g. sram_ip_bbox.lib for SRAM macros).
# Filled by run_sta.sh arg 7 — provides internal arcs so paths THROUGH the
# blackbox are timed instead of silently zero-delay:

read_verilog out/sta_run/cnn_systolic_synth_sta.v
link_design cnn_systolic

# --- Stage 2: Constraints (always on; read from the generated SDC) ------------
# run_sta.sh generates <out>/<TOP>.sdc from scripts/template.sdc
# (create_clock default on; optional constraints commented with how/when notes).
read_sdc out/sta_run/attempt_3/cnn_systolic.sdc
# Add module-specific, OpenSTA-only commands here after read_sdc if needed:
# set_power_activity ...

# --- Stage 3: Power activity (optional; default 0.1/0.5 if omitted) -----------
# set_power_activity -input -activity 0.1 -duty 0.5
# set_power_activity -input_port <name> -activity 0

# --- Stage 4: Reports (always on) ---------------------------------------------
report_checks -path_delay max -digits 4 -format full > out/sta_run/attempt_3/cnn_systolic_timing_max_tt_025C_1v80.rpt
report_checks -path_delay min -digits 4 -format full > out/sta_run/attempt_3/cnn_systolic_timing_min_tt_025C_1v80.rpt
report_wns -digits 4
report_tns -digits 4
report_power > out/sta_run/attempt_3/cnn_systolic_power_tt_025C_1v80.rpt
# Optional report args:
# report_checks -path_delay max -digits 4 -format short -endpoint_path_count 10
# report_checks -unconstrained > out/sta_run/attempt_3/cnn_systolic_unconstrained_tt_025C_1v80.rpt

# --- Stage 5: Area report (always on; OpenSTA has no report_area) -------------
set af [open "out/sta_run/attempt_3/cnn_systolic_area_tt_025C_1v80.rpt" w]
puts $af "Cell Area Report - cnn_systolic"
puts $af "-----------------------------------------------"
puts $af "Instance Cell Area"
set total 0.0
foreach inst [get_cells *] {
  set cn [get_name [get_property $inst cell]]
  set lc [get_lib_cell $cn]
  if {$lc ne ""} {
    set a [get_property $lc area]
    puts $af "[get_name $inst] $cn $a"
    set total [expr {$total + $a}]
  } else {
    puts $af "[get_name $inst] $cn (no liberty area)"
  }
}
puts $af "-----------------------------------------------"
puts $af "TOTAL_CELL_AREA $total"
close $af
