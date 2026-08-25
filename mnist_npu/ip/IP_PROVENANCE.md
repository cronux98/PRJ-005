# IP Provenance — mnist_npu

**No third-party IP is used anywhere in this design.** This directory is intentionally empty of
vendored sources (project brief §8: "ip/ empty (no external IP)").

## uart_tx (BLK-009)

The only block `spec/requirements.yaml` recorded as a reuse *candidate* (`IPR-001`) was the UART
transmitter. Decision: **custom**, not reused.

- Repository: n/a (no network search was executed in this sandboxed environment).
- Search command recorded for a future revisit: `gh search repos "sky130 verilog uart" --limit 20`
  (per `spec/requirements.yaml : ip_reuse`).
- Rationale: a 115200 8N1 transmitter with no RX and a parameterized divider is small and fully
  specified by an exact byte-format contract (REQ-021/022) that must be bit-exact to the golden
  model — implementing it custom (`rtl/uart_tx.v`, `rtl/uart_line_fmt.v`) keeps the exact
  framing/timing directly auditable against the requirement rather than adapting a third-party
  module's own assumptions and licence terms.
- DFT check: n/a (custom code, no scan/JTAG constructs anywhere in this design).

Every other block (`ctrl_fsm`, `mac_datapath`, `sigmoid_lut`, `weight_rom`, `image_rom`,
`label_rom`, `hidden_ram`, `led_ctrl`) is project-specific datapath/control logic with no
reuse-candidate status — see `spec/spec.md` §10 and `arch/arch.md` §10.
