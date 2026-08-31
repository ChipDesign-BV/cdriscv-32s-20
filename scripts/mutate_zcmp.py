#!/usr/bin/env python3
"""Mutation-validate the Zcmp benches (`block-zcmp`, `make zcmp`, cosim).

    python3 scripts/mutate_zcmp.py       # from the repository root

Each mutant is a single, plausible design error in the Zcmp sequence
table (rtl/core/cdriscv_32s_20_zcmp.sv) or the core's sequencer control
(rtl/core/cdriscv_32s_20_core.sv).  For each mutant the targets are run
cheapest first -- block-zcmp, then the directed test, then the Spike
co-simulation -- and the mutant is killed by the FIRST one that fails.
A mutant that survives all three is a hole in the benches, not a pass.
The originals are restored unconditionally in a finally block.

What each mutant proves:

* rlist-count: cm.push {ra, s0-s11} saves 12 registers instead of 13 --
  the rlist=15 special case dropped.  The sequence-table check against
  Spike sees the missing beat immediately.
* sp-first: the push writes sp as its FIRST step and stores relative to
  the moved sp.  On a clean run the final architectural state is
  IDENTICAL (same addresses, same sp), so only the trap-path checks can
  see it: the directed test's PMP-denied push finds sp already moved at
  the trap (checks 17/18), which is precisely the restartability
  property the write-sp-last rule exists for.  block-zcmp also fails
  because its interpreter evaluates each step against the PRE-sequence
  register state -- a step that depends on an earlier step's write
  breaks the table's stated contract.
* retire-per-beat: retire_valid fires on every micro-step.  The
  directed test's minstret arithmetic (check 6) counts 14 where 1 is
  required; the co-simulation would also diverge on every sequence.
* irq-mid-seq: a pending interrupt is taken inside ST_SEQ.  The
  directed test sweeps a CLINT deadline across a cm.pop in 1-cycle
  steps; some K lands after the first beat, and the handler then sees
  mepc = the cm PC with the first destination register already loaded
  (check 14) -- the partially-executed-sequence state a boundary-only
  design can never present.
* popretz-no-zero: the a0 = 0 step writes x0 instead.  Spike's commit
  line carries x10 0x0; the table replay misses it, and the directed
  test reads a non-zero a0 after the call (check 9).
* mv-swapped: cm.mva01s reads r2s' into a0 and r1s' into a1.  Both the
  table replay and check 10 see the crossed values.
* adj-rounding: the 5..8-register base rounds to 48 instead of 32.
  Wrong sp delta and wrong load/store block -- the table replay fails
  on the very first affected encoding.
* pop-wrong-base: pop loads from below sp (the push's frame position)
  instead of below sp+adj.  Wrong addresses in the replay; the directed
  round trip restores garbage.
* denied-beat-issues: the PMP-denied store is put on the bus in the
  same cycle its exception is raised.  The trap still looks right; what
  changes is memory -- the directed test's guarded word is corrupted
  (check 19), which is the deny-BEFORE-issue property itself.

The same warning as scripts/mutate_dbg.py: a surviving mutant is a
claim about the bench, so first be sure the mutant is a real change.
"""
import subprocess, sys, os

CORE = 'rtl/core/cdriscv_32s_20_core.sv'
ZCMP = 'rtl/core/cdriscv_32s_20_zcmp.sv'

MUTANTS = [
 (ZCMP, "assign n = (rlist == 4'd15) ? 4'd13 : (rlist - 4'd3);",
        "assign n = rlist - 4'd3;",
        "zcmp: rlist=15 counts 12 registers, not 13"),
 (ZCMP, """      if (step_i < n) begin
        mem_o = 1'b1;
        we_o  = 1'b1;
        rs2_o = sreg(n - 4'd1 - step_i);
        imm_o = 32'b0 - beat_off;
      end else begin
        wb_o   = 1'b1;
        last_o = 1'b1;
        rd_o   = 5'd2;
        imm_o  = 32'b0 - {24'b0, adj};
      end""",
        """      if (step_i == 4'd0) begin
        wb_o   = 1'b1;
        rd_o   = 5'd2;
        imm_o  = 32'b0 - {24'b0, adj};
      end else begin
        mem_o  = 1'b1;
        we_o   = 1'b1;
        rs2_o  = sreg(n - step_i);
        imm_o  = {24'b0, adj} - {26'b0, step_i, 2'b00};
        last_o = (step_i == n);
      end""",
        "zcmp: push writes sp FIRST, stores relative to the moved sp"),
 (CORE, "      ST_SEQ:      retire = seq_step_done && seq_last;",
        "      ST_SEQ:      retire = seq_step_done;",
        "core: retire fires per micro-step instead of once"),
 (CORE, "  assign take_irq = instr_exec && irq_pending;",
        "  assign take_irq = (instr_exec || seq_active) && irq_pending;",
        "core: interrupt taken mid-sequence, not at the boundary"),
 (ZCMP, """        op_a_zero_o = 1'b1;
        rd_o        = 5'd10;""",
        """        op_a_zero_o = 1'b1;
        rd_o        = 5'd0;""",
        "zcmp: cm.popretz forgets to zero a0"),
 (ZCMP, "        rs1_o = (step_i == 4'd0) ? sregp(r1sp) : sregp(r2sp);",
        "        rs1_o = (step_i == 4'd0) ? sregp(r2sp) : sregp(r1sp);",
        "zcmp: cm.mva01s move pair swapped"),
 (ZCMP, "    else if (n <= 4'd8)  adj = 8'd32;",
        "    else if (n <= 4'd8)  adj = 8'd48;",
        "zcmp: stack adjustment rounding wrong for 5..8 registers"),
 (ZCMP, """        rd_o  = sreg(n - 4'd1 - step_i);
        imm_o = {24'b0, adj} - beat_off;""",
        """        rd_o  = sreg(n - 4'd1 - step_i);
        imm_o = 32'b0 - beat_off;""",
        "zcmp: pop loads from below sp instead of below sp+adj"),
 (CORE, "  assign lsu_req = start_lsu || (seq_issue && !seq_exc);",
        "  assign lsu_req = start_lsu || seq_issue;",
        "core: PMP-denied sequence beat still reaches the bus"),
]

# Cheapest first; a mutant is killed by the first failing target.
TARGETS = ['block-zcmp', 'zcmp', 'cosim']

ENV = dict(os.environ)
ENV['PATH'] = ('/foss/tools/iverilog/bin:/foss/tools/verilator/bin:'
               '/foss/tools/riscv-gnu-toolchain/bin:/foss/tools/yosys/bin:'
               + ENV['PATH'])
ENV.setdefault('SPIKE', '/foss/tools/spike/bin/spike')


def run(target):
    r = subprocess.run(['make', target, 'SPIKE=' + ENV['SPIKE']],
                       capture_output=True, text=True, timeout=1200, env=ENV)
    return r.returncode


orig = {f: open(f).read() for f in (CORE, ZCMP)}
killed, survived = [], []
try:
    # the unmutated design must pass, or nothing below means anything
    for t in TARGETS:
        if run(t) != 0:
            print("BASELINE FAILS on %s -- aborting" % t); sys.exit(2)
    print("baseline passes\n")

    for f, old, new, desc in MUTANTS:
        s = orig[f]
        if s.count(old) != 1:
            print(f"SKIP (anchor not unique): {desc}"); survived.append(desc + " [ANCHOR]")
            continue
        open(f, 'w').write(s.replace(old, new, 1))
        killer = None
        for t in TARGETS:
            if run(t) != 0:
                killer = t
                break
        open(f, 'w').write(orig[f])          # restore straight away
        if killer:
            killed.append(desc);  print(f"killed   {desc}  [{killer}]")
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
