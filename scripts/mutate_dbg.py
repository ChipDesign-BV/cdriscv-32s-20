#!/usr/bin/env python3
"""Mutation-validate the block-dbg bench.

    python3 scripts/mutate_dbg.py        # from the repository root

Each mutant is a single, plausible design error.  The bench must FAIL on
every one; a mutant that survives is a hole in the bench, not a pass.
The originals are restored unconditionally in a finally block -- a
mutation run that dies half way must not leave the RTL mutated.

Current result: 9 of 10 killed.  The survivor -- sending the acknowledge
from acc_strobe rather than from the registered ack_pulse -- is reported
rather than rounded away: it survives because the acknowledge still
crosses a two-stage synchroniser, which in zero-delay RTL simulation
always outlasts a same-cycle register write.  That extra stage is a
timing margin, and functional simulation is the wrong instrument for it.
See doc/verification_findings_20.md section 14.

A warning from writing these: an earlier mutant was
`ack_pulse <= 1'b0; if (acc_strobe) ack_pulse <= 1'b1;`, which under
non-blocking semantics is *literally* `ack_pulse <= acc_strobe`.  It
"survived" because it was not a change.  A surviving mutant is a claim
about the bench, so be sure the mutant is a real difference first.
"""
import subprocess, sys, os, shutil

BR = 'rtl/debug/cdriscv_32s_20_dbg_bridge.sv'
WI = 'rtl/debug/cdriscv_32s_20_dbg_win.sv'

MUTANTS = [
 (WI, "8'h10:   acc_rdata_o = last_pc_q;\n        8'h14:   acc_rdata_o = last_insn_q;",
      "8'h10:   acc_rdata_o = last_insn_q;\n        8'h14:   acc_rdata_o = last_pc_q;",
      "window: LASTPC and LASTINSN swapped"),
 (WI, "                   err_pin_i,\n                   fault_any_i,",
      "                   fault_any_i,\n                   err_pin_i,",
      "window: STATUS bit order (err_pin/fault_any swapped)"),
 (WI, "localparam logic [31:0] Poison = 32'hffff_ffff;",
      "localparam logic [31:0] Poison = 32'h0000_0000;",
      "window: poison value is zero"),
 (WI, "if (acc_addr_i[31:8] == 24'h00_0000) begin",
      "if (1'b1) begin",
      "window: only the low byte decoded (address aliasing)"),
 (WI, "end else if (retire_valid_i) begin",
      "end else if (1'b1) begin",
      "window: last-retire registers follow live inputs"),
 (BR, "assign req_accept = dbg_req_i && !busy_q;",
      "assign req_accept = dbg_req_i;",
      "bridge: request accepted while busy"),
 (BR, ".src_pulse_i (ack_pulse),",
      ".src_pulse_i (acc_strobe),",
      "bridge: acknowledge sent in the strobe cycle, before rdata_q settles"),
 (BR, "      if (acc_strobe) rdata_q <= acc_rdata_i;",
      "      if (acc_strobe) rdata_q <= 32'h0;",
      "bridge: read data never captured"),
 (BR, "    if (!trst_ni) begin\n      busy_q  <= 1'b0;",
      "    if (1'b0) begin\n      busy_q  <= 1'b0;",
      "bridge: trst_ni does not reset the tck domain"),
 (BR, "else if (ack_tck) dbg_rdata_o <= rdata_q;",
      "else              dbg_rdata_o <= rdata_q;",
      "bridge: read data crossed without the handshake"),
]

def run():
    r = subprocess.run(['make', 'block-dbg'], capture_output=True, text=True,
                       timeout=600, env=ENV)
    return r.returncode

ENV = dict(os.environ)
ENV['PATH'] = '/foss/tools/iverilog/bin:' + ENV['PATH']

orig = {f: open(f).read() for f in (BR, WI)}
killed, survived = [], []
try:
    # the unmutated design must pass, or nothing below means anything
    if run() != 0:
        print("BASELINE FAILS -- aborting"); sys.exit(2)
    print("baseline passes\n")

    for f, old, new, desc in MUTANTS:
        s = orig[f]
        if s.count(old) != 1:
            print(f"SKIP (anchor not unique): {desc}"); survived.append(desc + " [ANCHOR]")
            continue
        open(f, 'w').write(s.replace(old, new, 1))
        rc = run()
        open(f, 'w').write(orig[f])          # restore straight away
        if rc != 0:
            killed.append(desc);  print(f"killed   {desc}")
        else:
            survived.append(desc); print(f"SURVIVED {desc}")
finally:
    for f, s in orig.items():
        open(f, 'w').write(s)

print(f"\n{len(killed)}/{len(MUTANTS)} mutants killed")
if survived:
    print("survivors:")
    for d in survived: print("  -", d)
sys.exit(1 if survived else 0)
