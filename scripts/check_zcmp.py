#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Check the Zcmp sequence table (build/zcmp_dump.txt, written by
# tb_zcmp) against Spike, over EVERY flagged encoding: all 192
# push/pop/popret/popretz forms (rlist 4..15 x spimm 0..3) and all 120
# legal mv pairs.
#
# The reference is generated, not restated:
#
#   1. this script writes an assembly program containing every cm.*
#      MNEMONIC once, with seeded registers and stack slots.  binutils
#      maps mnemonic -> encoding (independently of the RTL), and the
#      encoding in Spike's commit log is what ties each commit line to
#      a dumped sequence;
#   2. Spike executes it with --log-commits.  A Zcmp instruction
#      retires as ONE commit carrying every register and memory write;
#   3. an architectural model (registers + memory) is maintained from
#      the commit log itself -- register values, seeded stack slots and
#      the la-planted return addresses all come out of Spike's own
#      writes, so no expectation here is computed from this repo's
#      arithmetic;
#   4. for each cm.* commit, the DUT's dumped micro-ops are interpreted
#      against the model state and must reproduce Spike's write list
#      exactly (registers sorted by index, memory beats in execution
#      order -- the order Spike prints), and the FOLLOWING commit's PC
#      must equal the loaded ra for a ret form and pc+2 otherwise.
#
# A sequence table that mapped rlist to the wrong count, mixed up an
# offset, dropped the a0 zeroing, swapped a move pair or misplaced the
# sp write in the order therefore fails here without any RTL
# simulation of the core.
#
# Requires $SPIKE (or the default path) with Zcmp support; binutils is
# the riscv64-unknown-elf toolchain on PATH.

import os
import re
import subprocess
import sys

CROSS = "riscv64-unknown-elf-"
ARCH = "rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb_zcmp"
SPIKE = os.environ.get("SPIKE", "/headless/verif-tools/spike/bin/spike")
BUILD = "build"
BASE = 0x80000000
SIZE = 0x40000
SP0 = 0x80030000

SPIKE_HEAD = re.compile(
    r"core\s+\d+:\s+\d\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)")
WR_TOK = re.compile(
    r"(?<=\s)x\s?(\d+)\s+0x([0-9a-f]+)"
    r"|mem\s+0x([0-9a-f]+)(?:\s+0x([0-9a-f]+))?")

SAVED = ["ra", "s0", "s1", "s2", "s3", "s4", "s5", "s6",
         "s7", "s8", "s9", "s10", "s11"]
SREGN = [1, 8, 9, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]


def rlist_name(rl):
    n = 13 if rl == 15 else rl - 3
    if n == 1:
        return "{ra}", 1
    if n == 2:
        return "{ra, s0}", 2
    return "{ra, s0-s%d}" % (n - 2), n


def base_bytes(n):
    # only used to pick a legal mnemonic operand; the checked
    # adjustment value comes from Spike's sp write, not from here
    return ((4 * n + 15) // 16) * 16


def gen_program():
    """Every cm.* mnemonic once, with seeded state around each."""
    L = []
    L.append("    .section .text.init, \"ax\"")
    L.append("    .global _start")
    L.append("_start:")
    cases = []          # mnemonic text, in emission order

    def seed_regs(nregs):
        for j in range(nregs):
            L.append("    li %s, 0x%08x" % (SAVED[j], 0xA5000000 + 0x01010 * (j + 1)))

    def seed_slots(adj, nregs, ret_form):
        # slots: sp + adj - 4*(k+1), k = 0 (highest reg) .. n-1 (ra)
        for k in range(nregs):
            off = adj - 4 * (k + 1)
            if ret_form and k == nregs - 1:
                L.append("    la t0, 77f")
            else:
                L.append("    li t0, 0x%08x" % (0xC0DE0000 + len(cases) * 0x40 + k))
            L.append("    sw t0, %d(sp)" % off)

    for op in ("cm.push", "cm.pop", "cm.popretz", "cm.popret"):
        for rl in range(4, 16):
            name, n = rlist_name(rl)
            for sp2 in range(4):
                adj = base_bytes(n) + 16 * sp2
                L.append("    li sp, 0x%08x" % SP0)
                if op == "cm.push":
                    seed_regs(n)
                    insn = "%s %s, -%d" % (op, name, adj)
                    L.append("    " + insn)
                else:
                    # run the pop from adj below, so it lands back at SP0
                    L.append("    addi sp, sp, -%d" % adj)
                    seed_slots(adj, n, op in ("cm.popret", "cm.popretz"))
                    if op == "cm.popretz":
                        L.append("    li a0, 0x0bad0bad")   # must be zeroed
                    insn = "%s %s, %d" % (op, name, adj)
                    L.append("    " + insn)
                    if op in ("cm.popret", "cm.popretz"):
                        L.append("    li t6, 0xdead")       # skipped by ret
                        L.append("77:")
                cases.append(insn)

    mvregs = ["s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7"]
    L.append("    li a0, 0x1a0a0a0a")
    L.append("    li a1, 0x1b1b1b1b")
    for r1 in range(8):
        for r2 in range(8):
            L.append("    li %s, 0x%08x" % (mvregs[r1], 0x50000000 + r1 * 0x111))
            L.append("    li %s, 0x%08x" % (mvregs[r2], 0x60000000 + r2 * 0x111))
            insn = "cm.mva01s %s, %s" % (mvregs[r1], mvregs[r2])
            L.append("    " + insn)
            cases.append(insn)
            if r1 != r2:                     # equal pair is reserved
                insn = "cm.mvsa01 %s, %s" % (mvregs[r1], mvregs[r2])
                L.append("    " + insn)
                cases.append(insn)

    L.append("    la t0, tohost")
    L.append("    li t1, 1")
    L.append("    sw t1, 0(t0)")
    L.append("done: j done")
    L.append("    .section .tohost, \"aw\", @progbits")
    L.append("    .align 4")
    L.append("    .global tohost")
    L.append("tohost: .dword 0")
    L.append("    .global fromhost")
    L.append("fromhost: .dword 0")
    return "\n".join(L) + "\n", cases


def parse_writes(tail):
    ev = []
    for m in WR_TOK.finditer(tail):
        if m.group(1) is not None:
            ev.append(("x", int(m.group(1)), int(m.group(2), 16)))
        else:
            md = int(m.group(4), 16) if m.group(4) else None
            ev.append(("mem", int(m.group(3), 16), md))
    return ev


def load_dump():
    seqs = {}
    for line in open(os.path.join(BUILD, "zcmp_dump.txt")):
        f = line.split()
        enc = int(f[0], 16)
        step = dict(idx=int(f[1]), mem=int(f[2]), we=int(f[3]),
                    rs1=int(f[4]), rs2=int(f[5]), rd=int(f[6]),
                    imm=int(f[7], 16), azero=int(f[8]), wb=int(f[9]),
                    last=int(f[10]), ret=int(f[11]))
        seqs.setdefault(enc, []).append(step)
    for enc, st in seqs.items():
        assert [x["idx"] for x in st] == list(range(len(st))), hex(enc)
    return seqs


def expected_events(steps, regs, memm):
    """Interpret the DUT micro-ops over the model state.

    Returns (events-in-Spike's-order, ret, ret_target) without mutating
    the model.  Register writes are sorted by index (x0 suppressed) and
    memory beats keep execution order -- exactly how Spike prints one
    commit."""
    regw = {}
    memb = []
    ret = False
    ret_target = None
    for st in steps:
        if st["mem"]:
            addr = (regs[2] + st["imm"]) & 0xffffffff
            if st["we"]:
                memb.append(("mem", addr, regs[st["rs2"]]))
            else:
                memb.append(("mem", addr, None))
                if st["rd"]:
                    regw[st["rd"]] = memm.get(addr)
        elif st["wb"]:
            if st["azero"]:
                val = st["imm"] & 0xffffffff
            else:
                val = (regs[st["rs1"]] + st["imm"]) & 0xffffffff
            if st["rd"]:
                regw[st["rd"]] = val
        if st["last"] and st["ret"]:
            ret = True
            ret_target = regw.get(st["rs2"], regs[st["rs2"]]) & 0xfffffffe
    ev = [("x", r, regw[r]) for r in sorted(regw)] + memb
    return ev, ret, ret_target


def main():
    seqs = load_dump()

    src, cases = gen_program()
    s_path = os.path.join(BUILD, "zcmp_ref.s")
    elf = os.path.join(BUILD, "zcmp_ref.elf")
    ld = os.path.join(BUILD, "zcmp_ref.ld")
    open(s_path, "w").write(src)
    open(ld, "w").write(
        "OUTPUT_ARCH(riscv)\nENTRY(_start)\nSECTIONS {\n"
        "  . = 0x%x;\n  .text : { *(.text.init) *(.text*) }\n"
        "  .tohost ALIGN(8) : { *(.tohost) }\n}\n" % BASE)
    r = subprocess.run([CROSS + "gcc", "-march=" + ARCH, "-mabi=ilp32",
                        "-nostdlib", "-nostartfiles", "-T", ld,
                        "-o", elf, s_path],
                       capture_output=True, text=True)
    if r.returncode:
        print("assembly failed:", r.stderr[:800])
        return 2

    r = subprocess.run([SPIKE, "-l", "--log-commits", "--isa=" + ARCH,
                        "--priv=m", "-m0x%x:0x%x" % (BASE, SIZE), elf],
                       capture_output=True, text=True, timeout=600)
    commits = []
    for line in r.stdout.splitlines() + r.stderr.splitlines():
        m = SPIKE_HEAD.search(line)
        if m:
            commits.append((int(m.group(1), 16), int(m.group(2), 16),
                            parse_writes(m.group(3))))
    if not commits:
        print("spike produced no commit log")
        return 2

    regs = [0] * 32
    memm = {}
    checked = 0
    used = set()
    bad = 0
    for i, (pc, instr, ev) in enumerate(commits):
        if instr in seqs and instr <= 0xffff:
            steps = seqs[instr]
            exp, ret, tgt = expected_events(steps, regs, memm)
            nxt = commits[i + 1][0] if i + 1 < len(commits) else None
            exp_next = (tgt if ret else (pc + 2) & 0xffffffff)
            ok = (exp == ev) and (nxt == exp_next)
            checked += 1
            used.add(instr)
            if not ok:
                bad += 1
                if bad <= 5:
                    print("MISMATCH at pc %08x enc %04x" % (pc, instr))
                    print("  spike : %s next=%s" % (ev, "%08x" % nxt if nxt is not None else "?"))
                    print("  table : %s next=%08x" % (exp, exp_next))
        # update the model from the commit line, whatever it was
        for w in ev:
            if w[0] == "x":
                if w[1]:
                    regs[w[1]] = w[2]
            elif w[2] is not None:
                memm[w[1]] = w[2]

    unused = set(seqs) - used
    print("=== Zcmp sequence table vs Spike (%s) ===" % ARCH)
    print("  dumped sequences        %6d" % len(seqs))
    print("  cases in the program    %6d" % len(cases))
    print("  sequences checked       %6d" % checked)
    print("  mismatches              %6d" % bad)
    if unused:
        # every dumped encoding must have been executed, or part of the
        # table was never compared at all
        print("  NEVER EXECUTED: %s" % ", ".join("%04x" % e for e in sorted(unused)[:8]))
    ok = (bad == 0) and (not unused) and (checked == len(cases))
    print("  " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


sys.exit(main())
