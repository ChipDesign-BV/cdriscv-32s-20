#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Runs one program on Spike and on the RTL and compares the retired
# instruction streams.
#
#   python3 verif/core/cosim.py build/cosim_isa.elf --count 3000
#
# Compared: the (pc, instruction, ordered-write-list) sequence, where
# the write list carries every register write and every memory access
# of the retirement -- one entry for most instructions, up to 14 for a
# Zcmp sequence instruction.  Both sides come from the same places: Spike's
# --log-commits, and on the RTL side the core's internal signals through
# a hierarchical reference in the bench, so the RTL is not modified.
# Still not compared: CSR state that no instruction reads back, and
# anything the program does not execute.
#
# Spike's own reset vector at 0x1000 is skipped: the comparison starts
# at the ELF entry point.

import argparse
import os
import re
import subprocess
import sys

SPIKE = os.environ.get("SPIKE", "/headless/verif-tools/spike/bin/spike")
VVP = os.environ.get("VVP", "vvp")
ISA = "rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb_zcmp"

# Spike --log-commits: "core   0: 3 0x800000dc (0x40e68833) x16 0xffffffff"
# The disassembly line for the same instruction has no privilege field
# and is skipped by requiring it.
#
# A Zcmp instruction (cm.push/cm.pop/...) retires as ONE commit with
# MANY register and memory writes on the same line, so the tail of the
# line is tokenised rather than matched once: every "xN 0xV" register
# write and every "mem 0xA [0xV]" access, in the order printed.  The
# same tokeniser reads the RTL's TRACE lines, whose bench prints the
# identical order (registers sorted by index, then memory beats in
# execution order), so an entry compares as (pc, instr, write-tuple)
# for one write and many alike.  CSR commit tokens ("c768_mstatus ...")
# do not match the register pattern and stay ignored, as before.
SPIKE_HEAD = re.compile(
    r"core\s+\d+:\s+\d\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)")
RTL_HEAD = re.compile(r"^TRACE ([0-9a-f]+) ([0-9a-f]+)(.*)")
# The register alternative requires a preceding space so the "x" inside
# a hex value ("... 0x11111111") can never start a false token.
WR_TOK = re.compile(
    r"(?<=\s)x\s?(\d+)\s+(?:0x)?([0-9a-f]+)"
    r"|mem\s+(?:0x)?([0-9a-f]+)(?:\s+(?:0x)?([0-9a-f]+))?")


def parse_writes(tail):
    """The ordered register/memory write list of one commit line."""
    ev = []
    for m in WR_TOK.finditer(tail):
        if m.group(1) is not None:
            ev.append(("x", int(m.group(1)), int(m.group(2), 16)))
        else:
            md = int(m.group(4), 16) if m.group(4) else None
            ev.append(("mem", int(m.group(3), 16), md))
    return tuple(ev)


def symbols(elf, names):
    """Addresses of the named symbols, if present."""
    out = subprocess.run(["riscv64-unknown-elf-nm", elf],
                         capture_output=True, text=True, check=True).stdout
    found = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] in names:
            found[parts[2]] = int(parts[0], 16)
    return found


def truncate_at(trace, stops):
    """Cut a trace at the first instruction inside a stop label.

    The programs end in a tight loop, and Spike only notices the HTIF
    exit store at its next poll, so its trace carries a tail of spin
    loop instructions.  Cutting both traces at the same label keeps the
    comparison to the part that means something, and tells us which
    end the program reached.
    """
    for i, e in enumerate(trace):
        if e[0] in stops:
            return i, stops[e[0]]
    return len(trace), None


def entry_point(elf):
    out = subprocess.run(["riscv64-unknown-elf-readelf", "-h", elf],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if "Entry point address" in line:
            return int(line.split(":")[1].strip(), 16)
    raise RuntimeError("no entry point in %s" % elf)


def run_spike(elf, count, base, size):
    # Free running with the HTIF exit protocol: the program ends the run
    # by storing to `tohost`.  Spike's interactive debug mode can do the
    # same job with "r N", but it is thousands of times slower -- 215
    # instructions took a minute there against 25 ms here.
    # --priv=m matters: Spike defaults to msu, and then reports the S
    # and U bits in misa, which a machine-mode-only core must not set.
    # The first value comparison diverged on exactly that.
    cmd = [SPIKE, "-l", "--log-commits", "--isa=" + ISA, "--priv=m",
           "-m0x%x:0x%x" % (base, size), elf]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    trace = []
    for line in proc.stdout.splitlines() + proc.stderr.splitlines():
        m = SPIKE_HEAD.search(line)
        if m:
            trace.append((int(m.group(1), 16), int(m.group(2), 16),
                          parse_writes(m.group(3))))
    return trace


def run_rtl(runner, hexfile, count, stops=None, stall=0):
    # Two runners are supported: a Verilator binary (executed directly)
    # and an Icarus .vvp image (run under vvp).  Verilator is about 90
    # times faster on this design and is the default; Icarus stays
    # available as an independent second opinion, which has already
    # earned its keep once by rejecting constructs Verilator accepted.
    cmd = ([VVP, runner] if runner.endswith(".vvp") else [runner])
    cmd += ["+HEX=" + hexfile, "+MAXRETIRE=%d" % count,
            "+STALL=%d" % stall,
           "+MAXCYCLES=%d" % (count * 40 + 5000)]
    # Tell the bench where the program ends so it does not simulate the
    # final spin loop up to the retire limit.  That alone was costing
    # about a minute per random program.
    for i, addr in enumerate(sorted(stops or {})):
        cmd.append("+STOPPC%s=%x" % ("" if i == 0 else str(i + 1), addr))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    trace = []
    for line in proc.stdout.splitlines():
        m = RTL_HEAD.match(line)
        if m:
            trace.append((int(m.group(1), 16), int(m.group(2), 16),
                          parse_writes(m.group(3))))
        elif "FAULT" in line or "TIMEOUT" in line:
            sys.stderr.write("[cosim] RTL reported: %s\n" % line.strip())
    return trace


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("--hex", default=None)
    ap.add_argument("--vvp", dest="runner",
                    default="build/obj_cosim/tb_cosim_vl",
                    help="RTL runner: a Verilator binary, or a .vvp image "
                         "to run under vvp")
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0x80000000)
    ap.add_argument("--size", type=lambda x: int(x, 0), default=0x4000)
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--stall", type=int, default=0,
                    help="percentage of cycles on which memory grants are "
                         "held off; must not change the result, only the "
                         "timing, which is what comparing against Spike "
                         "checks")
    args = ap.parse_args()

    hexfile = args.hex or args.elf.replace(".elf", ".hex")
    entry = entry_point(args.elf)

    stops = {}
    for name, addr in symbols(args.elf, {"done", "fail"}).items():
        stops[addr] = name

    spike = run_spike(args.elf, args.count, args.base, args.size)
    # drop Spike's built-in reset vector: start at the ELF entry
    start = next((i for i, e in enumerate(spike) if e[0] == entry), None)
    if start is None:
        print("[cosim] FAIL: Spike never reached the entry point 0x%08x" % entry)
        return 1
    spike = spike[start:]

    rtl = run_rtl(args.runner, hexfile, args.count, stops, args.stall)

    if not rtl:
        print("[cosim] FAIL: the RTL retired nothing")
        return 1

    spike_end, spike_label = truncate_at(spike, stops)
    rtl_end, rtl_label = truncate_at(rtl, stops)
    spike = spike[:spike_end]
    rtl = rtl[:rtl_end]

    # Spike stops at the tohost store; the RTL keeps spinning in the
    # loop after it, so the comparison runs to the end of Spike's stream.
    n = min(len(spike), len(rtl), args.count)
    for i in range(n):
        if spike[i] != rtl[i]:
            print("[cosim] FAIL: streams diverge at retired instruction %d" % i)
            lo = max(0, i - args.context)
            def fmt(e):
                out = "pc=%08x %08x" % (e[0], e[1])
                for w in e[2]:
                    if w[0] == "x":
                        out += " x%d=%08x" % (w[1], w[2])
                    else:
                        out += " m[%08x]" % w[1]
                        out += "=%08x" % w[2] if w[2] is not None else " rd"
                return out
            print("        %-5s %-46s %-46s" % ("idx", "spike", "rtl"))
            for j in range(lo, min(n, i + args.context)):
                mark = "  <<<" if j == i else ""
                print("        %-5d %-46s %-46s%s"
                      % (j, fmt(spike[j]), fmt(rtl[j]), mark))
            return 1

    if len(spike) != len(rtl):
        print("[cosim] FAIL: stream lengths differ before the end label "
              "(spike %d, rtl %d)" % (len(spike), len(rtl)))
        return 1

    if spike_label != rtl_label:
        print("[cosim] FAIL: spike ended at %s, the RTL ended at %s"
              % (spike_label, rtl_label))
        return 1

    if spike_label == "fail":
        print("[cosim] FAIL: the program reached its own fail label "
              "(both sides agree, so this is a program or model issue)")
        return 1

    if spike_label is None:
        print("[cosim] note: no end label reached within %d instructions"
              % args.count)

    print("[cosim] PASS: %d retired instructions match, including register "
          "and memory writes%s" % (n, "" if spike_label is None else
                        " (program reached `%s`)" % spike_label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
