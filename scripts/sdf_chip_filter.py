#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Prepare the chip-level post-route SDF (flow/runs/chip2b/final/sdf/...)
# for Icarus consumption -- the chip counterpart of sdf_sim_filter.py.
# Every removal is counted and printed: a silent filter is a silent lie.
#
# Three things Icarus 12 cannot digest in this file, measured 2026-09-13
# (verification_findings_20.md, finding 21):
#
# 1. INTERCONNECT entries.  Its annotator cannot create an intermodpath
#    for an entry whose end is a top-level port bit, and follows the
#    failed insertion with a NULL-handle assertion (vvp SIGABRT).  The
#    93 port-to-pad entries are that case by construction; dropping only
#    those and keeping the 285 652 cell-to-cell ones still aborted the
#    same way, 29 minutes into the read, on both boot images -- so the
#    default is the subsystem flow's choice: drop them all.  What is
#    lost is the routed wire delay; what remains is every cell IOPATH.
#    The wire delays are analysed by OpenSTA on this same SDF's source
#    (the chip2b signoff), not by this simulation.  --keep-ic keeps the
#    cell-to-cell set for whoever wants to bisect the crash.
#
# 2. The SRAM macro CELL blocks.  The flat netlist keeps the macros'
#    hierarchical names as escaped identifiers (\u_sub.u_dtcm.g_bank[0].u_bank)
#    and OpenSTA writes them as u_sub\.u_dtcm\.g_bank\[0\]\.u_bank; Icarus
#    splits that on the dots ("Cannot find u_sub in scope") and, two
#    lines later, rejects the A_DOUT[0] bit-select port specs.  Eleven
#    errors and it declares the whole DELAYFILE invalid -- zero
#    annotation, silently, with the run then reporting nothing at all.
#    The macros compile -DFUNCTIONAL (no specify block), so these six
#    blocks could never annotate anyway; they are dropped whole.
#
# 3. The header's min::max triples (VOLTAGE 1.200::1.200) have an empty
#    typ field, which Icarus reports as "Chosen value not defined".
#    Harmless, but noise hides signal, so they are written X:X:X.
import re
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
keep_ic = "--keep-ic" in sys.argv
src, dst = args[0], args[1]

MACRO_RE = re.compile(r'\(CELLTYPE\s+"RM_IHPSG13_')
TRIPLE_RE = re.compile(r'^(\s*\((?:VOLTAGE|PROCESS|TEMPERATURE)\s+"?)([^\s":]+)::([^\s")]+)("?\))')

ic_port = ic_cell = ic_kept = 0
macro_cells = macro_lines = 0
empty_cells = empty_lines = 0
hdr_fixed = other = 0

# A CELL whose only content was INTERCONNECT (the chip-top CELL, once
# its port-to-pad wires are gone) is left with an empty (ABSOLUTE)
# list, which Icarus reports as "Invalid/malformed delay type" and
# "Too many errors".  Nothing is lost by dropping the shell.
CONTENT = ("(IOPATH ", "(INTERCONNECT ", "(TIMINGCHECK", "(PORT ", "(DEVICE ", "(COND")


def has_content(lines):
    return any(any(tag in l for tag in CONTENT) for l in lines)

with open(src) as f, open(dst, "w") as g:
    pending = []          # lines of a CELL block not yet classified
    in_cell = False
    depth_at_cell = 0
    depth = 0
    drop_block = False

    def flush():
        global other, empty_cells, empty_lines
        if not has_content(pending):
            empty_cells += 1
            empty_lines += len(pending)
            pending.clear()
            return
        for l in pending:
            g.write(l)
            other += 1
        pending.clear()

    for line in f:
        s = line.lstrip()
        # --- INTERCONNECT ------------------------------------------------
        if s.startswith("(INTERCONNECT "):
            a, b = s.split()[1], s.split()[2]
            if "." not in a or "." not in b:
                ic_port += 1
                continue
            if keep_ic:
                ic_kept += 1
                if in_cell:
                    pending.append(line)
                else:
                    g.write(line)
                continue
            ic_cell += 1
            continue
        # --- header triples -----------------------------------------------
        m = TRIPLE_RE.match(line)
        if m and not in_cell:
            line = "%s%s:%s:%s%s\n" % (m.group(1), m.group(2), m.group(2), m.group(3), m.group(4))
            hdr_fixed += 1
        # --- CELL block tracking ------------------------------------------
        opens, closes = line.count("("), line.count(")")
        if s.startswith("(CELL") and not s.startswith("(CELLTYPE"):
            # a new CELL: settle the previous one first
            if in_cell:
                if drop_block:
                    macro_lines += len(pending); pending.clear()
                else:
                    flush()
            in_cell = True
            drop_block = False
            depth_at_cell = depth
            pending.append(line)
            depth += opens - closes
            continue
        if in_cell:
            if MACRO_RE.search(line):
                drop_block = True
                macro_cells += 1
            pending.append(line)
            depth += opens - closes
            if depth <= depth_at_cell:      # block closed
                if drop_block:
                    macro_lines += len(pending); pending.clear()
                else:
                    flush()
                in_cell = False
            continue
        depth += opens - closes
        g.write(line)
        other += 1
    if in_cell:
        if drop_block:
            macro_lines += len(pending); pending.clear()
        else:
            flush()

print("sdf_chip_filter: %s -> %s" % (src, dst))
print("sdf_chip_filter: dropped %d port-to-pad INTERCONNECT entries" % ic_port)
if keep_ic:
    print("sdf_chip_filter: KEPT %d cell-to-cell INTERCONNECT entries (--keep-ic)" % ic_kept)
else:
    print("sdf_chip_filter: dropped %d cell-to-cell INTERCONNECT entries" % ic_cell)
print("sdf_chip_filter: dropped %d SRAM macro CELL blocks (%d lines)" % (macro_cells, macro_lines))
print("sdf_chip_filter: dropped %d CELL blocks left empty by the above (%d lines)" % (empty_cells, empty_lines))
print("sdf_chip_filter: rewrote %d header min::max triples" % hdr_fixed)
print("sdf_chip_filter: %d lines written" % other)
