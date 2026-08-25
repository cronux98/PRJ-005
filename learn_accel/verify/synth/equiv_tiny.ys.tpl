# =============================================================================
# rinriAI tiny-config equivalence check (fe-yosys stage-2 methodology)
# Gold: RTL (chparam tiny) vs Gate: learn_accel_tiny_top_synth.v
# =============================================================================
# ---- gold: single clean prep, tiny config ----
read_verilog -formal verify/synth/learn_accel_tiny_top.v rtl/learn_accel.v rtl/apb_regs.v rtl/sample_stream.v rtl/learner.v verify/synth/weight_ram_tiny.v rtl/stats.v rtl/div_seq.v
chparam -set FEATURES 4 -set HIDDEN 4 -set CLASSES 2 learn_accel
prep -top learn_accel_tiny_top
memory_map
async2sync
flatten -wb learn_accel_tiny_top
design -stash gold

# ---- gate: netlist + liberty ----
read_verilog -formal -icells verify/synth/flow/run-003/synth/learn_accel_tiny_top_synth.v
read_liberty -ignore_miss_func %%LIB%%
prep -top learn_accel_tiny_top
flatten -wb learn_accel_tiny_top
async2sync
design -stash gate

# ---- compare ----
design -copy-from gold -as gold_mod learn_accel_tiny_top
design -copy-from gate -as gate_mod learn_accel_tiny_top
equiv_make gold_mod gate_mod equiv
equiv_induct -undef equiv
equiv_status -assert equiv
