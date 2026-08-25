# fe-iverilog X-hygiene report
- top: mnist_npu
- summary: 0 X/Z events on outputs (0 X-LEAK lines)
- log: verify/run-001/xcheck/xcheck.log
- tb:  verify/run-001/xcheck/xcheck_tb.v

## X-LEAK events
none.

## Verdict
**XCHECK: PASS** — no X/Z leakage on outputs after reset + X window.
