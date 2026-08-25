# =============================================================================
# rinriAI tiny-config synthesis script (fe-yosys methodology, yosys 0.68)
# chparam FIRST: the wrapper-instance path mis-evaluates learn_accel's
# W_TOT localparam (yosys 0.68 quirk) and derives the weight_ram at the
# 25,450-word default; chparam sets the module defaults before hierarchy.
# weight_ram_tiny.v = test-side copy with small DEFAULT (instance override
# is what matters); source RTL untouched.
# =============================================================================
read_verilog verify/synth/learn_accel_tiny_top.v rtl/learn_accel.v rtl/apb_regs.v rtl/sample_stream.v rtl/learner.v verify/synth/weight_ram_tiny.v rtl/stats.v rtl/div_seq.v
chparam -set FEATURES 4 -set HIDDEN 4 -set CLASSES 2 learn_accel
hierarchy -check -top learn_accel_tiny_top

# --- generic synthesis (keep hierarchy; FSM re-encoding off for equiv) ----
synth -top learn_accel_tiny_top -nofsm

# --- sky130 HD standard-cell mapping (liberty) ----------------------------
dfflibmap -liberty %%LIB%%
abc -liberty %%LIB%%
clean

# --- reports + netlist -----------------------------------------------------
tee -o %%OUT%%/learn_accel_tiny_top_stat.txt stat -top learn_accel_tiny_top -liberty %%LIB%%
write_verilog -noattr -noexpr %%OUT%%/learn_accel_tiny_top_synth.v
