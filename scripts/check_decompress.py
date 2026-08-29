#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Check the Zca/Zcb decompressor against binutils, as a proper RV32.
#
# The naive approach -- objdump on a raw binary -- CANNOT be restricted to
# RV32: it decodes c.ldsp, c.addiw and friends, and it cannot see c.jal at
# all because RV64 reads that opcode as c.addiw.  Assembling `.insn`
# directives into an ELF built with -march=rv32im_zba_zbb_zbs_zca_zcb makes objdump
# honour the architecture attributes, and then the reference is genuinely
# RV32 Zca/Zcb: RV64 forms come back as undecoded `.insn`, which is
# exactly the answer this decompressor must give.
#
# binutils disassembles BOTH the compressed input and our 32-bit
# expansion, so the hard part -- unscrambling RVC immediates and 3-bit
# register fields -- is done by an implementation that is not ours.  Only
# the identity of each form (that c.li rd,imm means addi rd,x0,imm) comes
# from this file, and that is specification, not code.
import subprocess, sys, re, os, collections

AS      = "riscv64-unknown-elf-as"
OBJDUMP = "riscv64-unknown-elf-objdump"
ARCH    = "rv32im_zba_zbb_zbs_zca_zcb"
TMP     = os.environ.get("TMPDIR", "/tmp")

def disasm(items, width):
    """items: list of (key, word).  Returns {key: (mnem, ops, addr)}."""
    src = os.path.join(TMP, "d%d.s" % width)
    obj = os.path.join(TMP, "d%d.o" % width)
    with open(src, "w") as f:
        f.write(".section .text\n")
        for _, w in items:
            f.write(".insn %d, 0x%x\n" % (width // 8, w))
    r = subprocess.run([AS, "-march=" + ARCH, "-mabi=ilp32", "-o", obj, src],
                       capture_output=True, text=True)
    if r.returncode:
        print("as failed:", r.stderr[:300]); sys.exit(2)
    out = subprocess.run([OBJDUMP, "-d", "-M", "no-aliases,numeric", obj],
                         capture_output=True, text=True).stdout
    res = {}
    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(\S+)\s*([^#]*)", line)
        if m:
            addr = int(m.group(1), 16)
            idx = addr // (width // 8)
            if idx < len(items):
                res[items[idx][0]] = (m.group(3), m.group(4).strip(), addr)
    return res

def norm(mnem, ops, addr):
    """turn an absolute branch/jump target into a relative offset"""
    ops = re.sub(r"\s*<[^>]*>", "", ops)
    if mnem in ("c.j", "c.jal", "c.beqz", "c.bnez", "jal", "beq", "bne"):
        parts = [p.strip() for p in ops.split(",")]
        if parts and re.fullmatch(r"[0-9a-f]+", parts[-1]):
            try:
                parts[-1] = "%d" % (int(parts[-1], 16) - addr)
                return mnem, ",".join(parts)
            except ValueError:
                pass
    return mnem, ops

IDENT = {
    "c.nop":("addi","x0,x0,0"), "c.addi":("addi","$0,$0,$1"),
    "c.li":("addi","$0,x0,$1"), "c.lui":("lui","$0,$1"),
    "c.addi16sp":("addi","x2,x2,$1"), "c.addi4spn":("addi","$0,x2,$2"),
    "c.lw":("lw","$0,$1"), "c.sw":("sw","$0,$1"),
    "c.j":("jal","x0,$0"), "c.jal":("jal","x1,$0"),
    "c.jr":("jalr","x0,0($0)"), "c.jalr":("jalr","x1,0($0)"),
    "c.beqz":("beq","$0,x0,$1"), "c.bnez":("bne","$0,x0,$1"),
    "c.slli":("slli","$0,$0,$1"), "c.srli":("srli","$0,$0,$1"),
    "c.srai":("srai","$0,$0,$1"), "c.andi":("andi","$0,$0,$1"),
    "c.sub":("sub","$0,$0,$1"), "c.xor":("xor","$0,$0,$1"),
    "c.or":("or","$0,$0,$1"),   "c.and":("and","$0,$0,$1"),
    "c.mv":("add","$0,x0,$1"),  "c.add":("add","$0,$0,$1"),
    "c.lwsp":("lw","$0,$1"),    "c.swsp":("sw","$0,$1"),
    "c.ebreak":("ebreak",""),
    "c.lbu":("lbu","$0,$1"), "c.lhu":("lhu","$0,$1"), "c.lh":("lh","$0,$1"),
    "c.sb":("sb","$0,$1"),   "c.sh":("sh","$0,$1"),
    "c.zext.b":("andi","$0,$0,255"), "c.sext.b":("sext.b","$0,$0"),
    "c.zext.h":("zext.h","$0,$0"),   "c.sext.h":("sext.h","$0,$0"),
    "c.not":("xori","$0,$0,-1"), "c.mul":("mul","$0,$0,$1"),
}

def main():
    rows = []
    for line in open("build/decompress_dump.txt"):
        a, b, c = line.split()
        rows.append((int(a, 16), int(b, 16), int(c)))
    # bits[1:0] == 11 is a 32-bit instruction by definition -- not
    # compressed at all, and the assembler refuses `.insn 2` for it.  Those
    # must simply be rejected, and that is checked directly.
    comp = [(i, r[0]) for i, r in enumerate(rows) if (r[0] & 3) != 3]
    d16 = disasm(comp, 16)
    d32 = disasm([(i, rows[i][1]) for i, _ in comp], 32)

    st = collections.Counter(); bad = collections.defaultdict(list)
    for i, (c16, x32, ill) in enumerate(rows):
        if (c16 & 3) == 3:
            if ill: st["ok_reject_uncompressed"] += 1
            else:
                st["ACCEPTED_INVALID"] += 1
                bad["ACCEPTED_INVALID"].append((c16, x32, "not compressed", "we accepted it"))
            continue
        ref = d16.get(i)
        if ref is None:
            st["no_ref"] += 1; continue
        rm, ro, raddr = ref
        if rm == ".insn":                      # not valid RV32 Zca/Zcb
            if ill: st["ok_reject_invalid"] += 1
            else:
                st["ACCEPTED_INVALID"] += 1
                bad["ACCEPTED_INVALID"].append((c16, x32, "undecodable", "we accepted it"))
            continue
        # RVC spec: for RV32, shamt[5] of c.slli/c.srli/c.srai MUST be zero;
        # those code points are reserved.  binutils does not model the
        # restriction and disassembles them as shifts of 32..63.  Trapping is
        # the correct RV32 behaviour and the safe one for this part, so the
        # DUT is right and the reference is lax.
        if rm in ("c.slli", "c.srli", "c.srai") and int(ro.split(",")[-1], 0) >= 32:
            if ill: st["ok_reject_reserved"] += 1
            else:
                st["ACCEPTED_INVALID"] += 1
                bad["ACCEPTED_INVALID"].append((c16, x32, rm + " shamt>=32", "we accepted it"))
            continue
        # C.ADDI16SP: "the code points with nzimm=0 are reserved".  binutils
        # disassembles them as c.addi16sp x2,0 regardless.
        if rm == "c.addi16sp" and int(ro.split(",")[-1], 0) == 0:
            if ill: st["ok_reject_reserved"] += 1
            else:
                st["ACCEPTED_INVALID"] += 1
                bad["ACCEPTED_INVALID"].append((c16, x32, "c.addi16sp nzimm=0", "we accepted it"))
            continue
        # c.unimp (all zeros) is the architecturally defined illegal encoding.
        if rm == "c.unimp":
            if ill: st["ok_reject_unimp"] += 1
            else:
                st["ACCEPTED_INVALID"] += 1
                bad["ACCEPTED_INVALID"].append((c16, x32, "c.unimp", "we accepted it"))
            continue
        if rm not in IDENT:
            st["unmapped:" + rm] += 1; continue
        if ill:
            st["REJECTED_VALID"] += 1
            bad["REJECTED_VALID"].append((c16, x32, "%s %s" % (rm, ro), "we flagged illegal"))
            continue
        got = d32.get(i)
        if got is None:
            st["no_dut_disasm"] += 1; continue
        gm, go, gaddr = got
        rm2, ro2 = norm(rm, ro, raddr)
        gm2, go2 = norm(gm, go, gaddr)
        base, pat = IDENT[rm]
        ops = [o.strip() for o in ro2.split(",")] if ro2 else []
        want = pat
        for k in range(len(ops) - 1, -1, -1):
            want = want.replace("$%d" % k, ops[k])
        if "$" in want:
            st["arity:" + rm] += 1; continue
        if gm2 != base or go2.replace(" ", "") != want.replace(" ", ""):
            st["MISMATCH"] += 1
            bad["MISMATCH:" + rm].append((c16, x32, "%s %s" % (rm2, ro2),
                        "got '%s %s' want '%s %s'" % (gm2, go2, base, want)))
        else:
            st["ok"] += 1

    print("=== Zca/Zcb decompressor vs binutils (%s), 65 536 encodings ===" % ARCH)
    for k in sorted(st): print("  %-30s %6d" % (k, st[k]))
    for cat in sorted(bad):
        print("\n  %s  (%d)" % (cat, len(bad[cat])))
        for c16, x32, ref, why in bad[cat][:3]:
            print("    %04x -> %08x | ref %-26s | %s" % (c16, x32, ref, why))
    n = st["MISMATCH"] + st["REJECTED_VALID"] + st["ACCEPTED_INVALID"]
    print("\n  expansions matched %d, correctly rejected %d, discrepancies %d"
          % (st["ok"], st["ok_reject_invalid"], n))
    print("  " + ("PASS" if n == 0 else "FAIL"))
    return 0 if n == 0 else 1

sys.exit(main())
