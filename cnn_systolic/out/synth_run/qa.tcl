read_liberty /home/smdadmin/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130B/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog out/synth_run/qa_net/cnn_systolic_qa.v
link_design cnn_systolic
read_sdc out/synth_run/cnn_systolic.sdc
report_checks -path_delay max -digits 3 > out/synth_run/setup.rpt
report_checks -path_delay min -digits 3 > out/synth_run/hold.rpt
report_clock_skew > out/synth_run/skew.rpt
