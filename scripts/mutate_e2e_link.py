#!/usr/bin/env python3
"""Mutation-validate the block-e2e-link bench.

    python3 scripts/mutate_e2e_link.py      # from the repository root

Each mutant is a single, plausible design error in the E2E link
endpoints (rtl/safety/cdriscv_32s_20_e2e_link.sv).  The bench must FAIL
on every one; a mutant that survives is a hole in the bench, not a
pass.  The originals are restored unconditionally in a finally block --
a mutation run that dies half way must not leave the RTL mutated.

A mutant here is a LIST of substitutions applied together, because the
most dangerous errors are symmetric: dropping the address from the fold
at ONLY one end is caught by the very first clean transfer (the two
ends disagree), so it proves nothing about the address property.  The
mutant that matters drops it at BOTH ends -- clean traffic still
passes, data faults still flag, and only the wrong-address tests can
kill it.  That is the E2E claim itself, so it gets its own mutant in
each direction.

The non-mutant trap (learned on mutate_dbg.py): a substitution that is
semantically identical to the original "survives" because it is not a
change.  Every mutant below alters which VALUES flow, not just how
they are written down; and every anchor is checked for exactly one
occurrence so a refactor cannot silently turn a mutant into a no-op.
"""
import subprocess, sys, os

LINK = 'rtl/safety/cdriscv_32s_20_e2e_link.sv'
E2E  = 'rtl/safety/cdriscv_32s_20_e2e.sv'

# Each mutant: (file, [(old, new), ...], description).
MUTANTS = [
 (LINK,
  [("cdriscv_32s_20_e2e_gen u_rd_gen (\n      .data_i (rdata_i),\n      .addr_i (addr_q),",
    "cdriscv_32s_20_e2e_gen u_rd_gen (\n      .data_i (rdata_i),\n      .addr_i (32'h0),"),
   ("cdriscv_32s_20_e2e_chk u_rd_chk (\n      .data_i (rdata_i),\n      .addr_i (addr_q),",
    "cdriscv_32s_20_e2e_chk u_rd_chk (\n      .data_i (rdata_i),\n      .addr_i (32'h0),")],
  "read path: address dropped from the fold at BOTH ends (clean traffic "
  "still passes -- only wrong-address delivery can catch this)"),

 (LINK,
  [("cdriscv_32s_20_e2e_gen u_wr_gen (\n      .data_i (wdata_i),\n      .addr_i (addr_i),",
    "cdriscv_32s_20_e2e_gen u_wr_gen (\n      .data_i (wdata_i),\n      .addr_i (32'h0),"),
   ("cdriscv_32s_20_e2e_chk u_wr_chk (\n      .data_i (wdata_i),\n      .addr_i (addr_i),",
    "cdriscv_32s_20_e2e_chk u_wr_chk (\n      .data_i (wdata_i),\n      .addr_i (32'h0),")],
  "write path: address dropped from the fold at BOTH ends"),

 (LINK,
  [("((!we_q && rd_chk_err) || (rd_chk_valid_i == we_q))",
    "((!we_q && 1'b0) || (rd_chk_valid_i == we_q))")],
  "master checker ignores the check bits (only the type cross-check left)"),

 (LINK,
  [("assign rd_err_o = pend_q && rvalid_i && resp_prot_i &&",
    "assign rd_err_o = ")],
  "read fault unqualified by pending/rvalid: idle cycles must flag it"),

 (LINK,
  [("assign wr_err_o = req_i && gnt_i && we_i && wr_chk_err;",
    "assign wr_err_o = we_i && wr_chk_err;")],
  "write fault unqualified by req/gnt: garbage on an idle bus must flag it"),

 (LINK,
  [("  cdriscv_32s_20_e2e_gen u_rd_gen (\n      .data_i (rdata_i),\n      .addr_i (addr_q),",
    "  cdriscv_32s_20_e2e_gen u_rd_gen (\n      .data_i (rdata_i),\n      .addr_i (addr_i),")],
  "slave generator fed the wrong address phase (live request wires "
  "instead of the held address of the outstanding access)"),

 (LINK,
  [("      if (gnt_i) begin\n        pend_q <= 1'b1;\n        we_q   <= we_i;\n        be_q   <= be_i;\n        addr_q <= addr_i;",
    "      if (rvalid_i) begin\n        pend_q <= 1'b1;\n        we_q   <= we_i;\n        be_q   <= be_i;\n        addr_q <= addr_i;")],
  "master holds the address at the response instead of at the grant"),

 (LINK,
  [("((!we_q && rd_chk_err) || (rd_chk_valid_i == we_q))",
    "((!we_q && rd_chk_err) || 1'b0)")],
  "access-type cross-check dropped (a read served as a write escapes)"),

 # The 2026-09-02 change: byte enables joined the fold.  Dropping them
 # inside the shared generator removes them at BOTH ends by construction
 # (gen and chk instantiate the same module), so clean traffic and every
 # data/address fault still pass -- only the be-corruption tests can
 # kill it.  This is the regression guard for the former E2E gap that
 # produced all 10 SDCs of the fault campaign's E2E sweep.
 (E2E,
  [(".data_i({28'h0, be_i}),",
    ".data_i({28'h0, 4'h0}),")],
  "byte enables dropped from the fold (both ends, via the shared "
  "generator) -- the pre-2026-09-02 gap resurrected"),

 (LINK,
  [("  cdriscv_32s_20_e2e_gen u_rd_gen (\n      .data_i (rdata_i),\n      .addr_i (addr_q),\n      .be_i   (be_q),",
    "  cdriscv_32s_20_e2e_gen u_rd_gen (\n      .data_i (rdata_i),\n      .addr_i (addr_q),\n      .be_i   (be_i),")],
  "slave read generator folds the LIVE be wires instead of the held "
  "byte enables of the outstanding access"),
]

def run():
    r = subprocess.run(['make', 'block-e2e-link'], capture_output=True,
                       text=True, timeout=600, env=ENV)
    return r.returncode

ENV = dict(os.environ)
ENV['PATH'] = '/foss/tools/iverilog/bin:' + ENV['PATH']

orig = {LINK: open(LINK).read(), E2E: open(E2E).read()}
killed, survived = [], []
try:
    # the unmutated design must pass, or nothing below means anything
    if run() != 0:
        print("BASELINE FAILS -- aborting"); sys.exit(2)
    print("baseline passes\n")

    for f, subs, desc in MUTANTS:
        s = orig[f]
        ok = True
        for old, new in subs:
            if s.count(old) != 1:
                print(f"SKIP (anchor not unique): {desc}")
                survived.append(desc + " [ANCHOR]")
                ok = False
                break
            s = s.replace(old, new, 1)
        if not ok:
            continue
        open(f, 'w').write(s)
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
