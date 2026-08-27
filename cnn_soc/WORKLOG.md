# cnn_soc — WORKLOG

## 2026-08-26/27 (SoC integration pipeline P0→P5)

Full front-end pipeline for the CNN SoC (RV32I core + CNN accelerator +
UART), spec→arch→rtl→firmware→SoC-verify→evidence. Workers: architect/
frontend on Claude Sonnet 5; the P4 tb fix + rerun finished on a detached
Claude Sonnet 5 (high-effort) worker after the original deepseek-v4-flash
agents went out of credits. Main session did verification + commits only
(did not do the design work, did not spend/switch models autonomously —
model switch to sonnet was Rinri's 21:41Z decision).

### Stages

- **P0 fe-spec** — DONE (9b7b10e, verified).
- **P1 fe-arch** — DONE (b26068d, verified: 8/8 artifacts, YAML valid,
  33/33 REQs mapped, zero orphans).
- **P2 fe-rtl** — DONE (753e475, verified: iverilog `-g2005` gate EXIT 0,
  zero warnings; 13 rtl + 9 ip modules).
- **P3 fe-firmware** — DONE + FIXED (4ce8f36, verified 16:25Z). POST
  self-test walker; bootrom write-probe NULL-addr bug fixed (GCC -Os had
  emitted `ebreak` on the 0x0 probe → moved probe to 0x4). Frozen hex
  `sw/firmware.hex` md5 = b7a8d7044ff4644a7a1b0a6c5f6dac59, 1772 B,
  RV32I-clean.

- **P4 SoC verify** — DONE (a62fb38). Rinri decision 17:42Z = option B:
  build the planned 100-image firmware loop and gate on a literal 100/100
  UART diff vs the golden (`G1` byte-exact), G2–G5 in-sim checks alongside.
  - **run-001** (20:30Z): G2–G5 PASS, tb in-sim PASS, but **G1 = 99/100**.
    IMG 000..098 all byte-exact; IMG 099 missing. Root cause = **testbench
    last-line DRAIN RACE**, not accuracy/RTL: the tb check-process paces
    off `done_r`/`led[11]` (fast internal) and $finishes on image-count
    before the slow serial UART monitor decodes/writes the 100th line. The
    99 captured predictions were byte-perfect.
  - **Fix (tb-only, `verify/tests/tb_cnn_soc.v`):** added module-scope
    `integer uart_lines`, incremented per captured UART line, and replaced
    the fixed `repeat(...)` drain with `while (uart_lines<100) @(posedge
    clk); repeat(200) @(posedge clk);` before the G5 checks + `$finish`.
    RTL / ip / firmware **frozen** — zero edits (verified: git-clean rtl/ip,
    firmware md5 unchanged b7a8d70…dac59).
  - **run-002** (22:55Z): **GREEN.** `summary.txt` RESULT: PASS=6 FAIL=0;
    `PASS G1 (100/100` byte-exact); G2–G5 PASS; `diff.log` empty (0 lines);
    `uart_captured.txt` = exactly 100 lines. `iterations.log` records
    run-002 2026-08-26T22:55:37Z PASS=6 FAIL=0.
  - **Commit note:** the 23:05Z watch tick verified GREEN but its commit
    did not land (HEAD stayed fe10fae, evidence untracked); the 01:05Z tick
    re-verified every gate on disk and completed the commit.

- **P5 evidence** — DONE (this commit). `.gitignore` extended with a
  `cnn_soc/verify/` block mirroring the `cnn` policy (versioned
  iterations.log + run-*/ + run-*/**, excluding *.vvp + sim_build +
  __pycache__ — the 613 KB `tb_cnn_soc.vvp` is ignored). Committed:
  `verify/tests/tb_cnn_soc.v`, `verify/tb_common/`, `verify/run_soc.sh`,
  `verify/iterations.log`, `verify/run-002/`, `sw/firmware.hex`,
  `out/pipeline_state.txt`, `.gitignore`.

### Open items (flagged to Rinri, not in this commit)

- `sw/main.c` + `sw/build_main.sh` are untracked firmware **source** that
  produced the frozen hex — deliberately outside the P4 evidence add-list.
  Decide separately whether to version them.
- `verify/run-001/` (the failed 99/100 run) is left untracked; it's the
  immutable negative-control run, not part of the P4 pass evidence set.

### Cost/perf

- SoC 100-image free-run ≈ 68.8 M cycles; one full run ≈ 65 min wall
  (iverilog). tb drain fix + rerun completed on the detached sonnet-5
  worker without further RTL/firmware changes.
