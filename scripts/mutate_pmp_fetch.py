#!/usr/bin/env python3
"""Mutation-validate the PMP-on-fetch checks of `make pmp`.

    python3 scripts/mutate_pmp_fetch.py      # from the repository root

Each mutant is a single, plausible design error in the *fetch-side* PMP
path (rtl/core/cdriscv_32s_20_core.sv wiring and the if_stage denial
handling).  The bench must FAIL on every one; a mutant that survives is
a hole in the bench, not a pass.  The originals are restored
unconditionally in a finally block.

What each mutant proves about the new checks:

* R-instead-of-X: the locked exec_stub region deliberately carries R=1
  W=1 X=0, so only a checker that tests X denies it (check 16 ff.).
* allow tied high: in machine mode the only entries that can deny are
  the LOCKED ones, so "the fetch check ignores lock" and "the fetch
  verdict is ignored" are the same fault; killed by the locked-denies
  direction (check 16).
* machine-mode tied low: unlocked entries would bind and unmatched
  fetches would be denied -- the deny-everything bug the unlocked
  direction (checks 14/15) exists to catch.  In practice it dies even
  earlier: the very first boot fetch is unmatched and would fault.
* err-escapes-its-entry: ORing the buffer's err bits detaches the
  injected fault from the entry that carries it, so a denied *prefetch*
  sitting behind the instruction in execute faults that instruction --
  the discard no longer contains the denial.  Killed by check 22's
  dead_word-after-a-taken-branch trap count (and it doubles as proof
  that the denied prefetch really happens there: the mutant can only
  fire while a fault entry coexists in the buffer).

  A first version of that mutant -- trapping from the live checker
  verdict, `if (instr_err || !pmp_allow_fetch)` in the core -- SURVIVED,
  and the survival was a real finding: the prefetcher had fetched
  dead_word before the csrw locking its region retired, so no fetch was
  ever denied and check 22 tested nothing.  The test gained its fence.i
  from that.  (The live-verdict mutant stays unkillable for a second
  reason too: by the time anything executes, fetch_pc has moved past
  the denied word, so the live verdict is allow again.)

The same warning as scripts/mutate_dbg.py: a surviving mutant is a
claim about the bench, so first be sure the mutant is a real change.
"""
import subprocess, sys, os

CORE = 'rtl/core/cdriscv_32s_20_core.sv'
IFS  = 'rtl/core/cdriscv_32s_20_if_stage.sv'

MUTANTS = [
 (CORE, "      .req_addr_i     (instr_addr_o),\n"
        "      .req_type_i     (PMP_ACC_EXEC),",
        "      .req_addr_i     (instr_addr_o),\n"
        "      .req_type_i     (PMP_ACC_READ),",
        "core: fetch checker tests R instead of X"),
 (CORE, ".fetch_allow_i  (pmp_allow_fetch)",
        ".fetch_allow_i  (1'b1)",
        "core: fetch verdict ignored (equals ignoring lock in M-mode)"),
 (CORE, "      .req_type_i     (PMP_ACC_EXEC),\n"
        "      .req_machine_i  (1'b1),",
        "      .req_type_i     (PMP_ACC_EXEC),\n"
        "      .req_machine_i  (1'b0),",
        "core: fetch checker binds unlocked entries (deny-everything)"),
 (IFS,  "  assign instr_err_o   = buf_err_q[rd_ptr_q];",
        "  assign instr_err_o   = buf_err_q[0] || buf_err_q[1];",
        "if_stage: injected err escapes its entry -- a dead prefetch traps"),
 (IFS,  "        buf_err_q[fault_wptr]   <= 1'b1;",
        "        buf_err_q[fault_wptr]   <= 1'b0;",
        "if_stage: injected entry loses its err bit (denial delivers a nop)"),
]

ENV = dict(os.environ)
ENV['PATH'] = ('/foss/tools/iverilog/bin:/foss/tools/verilator/bin:'
               '/foss/tools/riscv-gnu-toolchain/bin:/foss/tools/yosys/bin:'
               + ENV['PATH'])

def run():
    r = subprocess.run(['make', 'pmp'], capture_output=True, text=True,
                       timeout=600, env=ENV)
    return r.returncode

orig = {f: open(f).read() for f in (CORE, IFS)}
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
