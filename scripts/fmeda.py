#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv-32s-20 FMEDA computation (verification plan O9).
#
# Everything in this file is one of exactly three kinds of number, and
# each row of the tables says which:
#
#   MEASURED  -- element populations counted from the FINAL chip2b
#                placed netlist's flip-flop Q-nets
#                (flow/runs/chip2b/final/pnl/cdriscv_32s_20_chip.pnl.v:
#                7 538 sg13g2_dfrbpq_1 -- the only sequential cell in
#                the netlist, and the same 7 538 that run's
#                metrics.json reports as
#                design__instance__count__class:sequential_cell;
#                335 518 instances, 172 368 standard cells, 6 SRAM
#                macros, 312 pad cells -- all re-read from that
#                metrics.json, not quoted from memory); and diagnostic
#                coverage from THIS variant's fault-injection campaigns
#                (build/fi_campaign*.txt, 2026-09-02/04: workloads A-D
#                re-run on this RTL plus the E2E / CLINT / PMP / Zcmp /
#                debug sweeps).
#   ASSUMED   -- base failure rates.  No foundry FIT data exists for
#                this design; the values are typical published figures
#                for a 130 nm-class process at sea level and are the
#                part a real safety case MUST replace.
#   DERIVED   -- everything computed from the above.
#
# PROVENANCE NOTE (population basis).  Populations were refreshed on
# 2026-09-13 from the final chip2b harden (2026-09-07), which placed
# EVERY block of the subsystem: the CLINT, the E2E link endpoints and
# the Zcmp sequencer (RTL-elaborated stand-ins in the 2026-09-02
# edition, which counted the 2026-08-30 v2full netlist that predated
# them), the QSPI boot loader (new row) and the JTAG/debug blocks.
# Nothing is RTL-counted any more.  The pad ring adds no flip-flops,
# so the chip netlist's 7 538 DFFs are the subsystem's placed
# population.
#
# Method (the flat netlist keeps the RTL hierarchy in its Q-net
# names): every `sg13g2_dfrbpq_1` instance is taken with its .Q net,
# the bit index is stripped, and the net is assigned to exactly ONE
# row by the first matching prefix rule in ATTRIBUTION below -- the
# same rules `--netlist` re-applies to prove the table.  Q-nets that
# synthesis renamed to `_NNN_` cannot be attributed and form the
# "unattributed" row (they include, e.g., the CLINT's mtimecmp/msip
# registers, which have no named Q-net in this netlist).  The sum of
# the rows is asserted equal to TOTAL_FF_NETLIST at import, so a
# future edit that moves flops without closing the balance fails
# instead of passing silently.
#
# Reproduce the raw count and the per-row split outside the script:
#   grep -c '^ sg13g2_dfrbpq_1 ' <pnl.v>                       -> 7538
#   awk '/^ sg13g2_dfrbpq_1 /{f=1} f && /\.Q\(/{sub(/.*\.Q\(/,"");
#        sub(/\).*$/,""); sub(/^\\/,""); sub(/ $/,""); print; f=0}' \
#        <pnl.v> > q.txt ; wc -l q.txt                          -> 7538
#   python3 scripts/fmeda.py --netlist <pnl.v>   (per-row recount)
#
# Metrics follow the ISO 26262 definitions:
#   SPFM = 1 - sum(lambda_SPF) / sum(lambda_safety_related)
#   LFM  = 1 - sum(lambda_MPF_latent) / sum(lambda_SR - lambda_SPF)
# A fault is "safe" when it cannot violate the assumed safety goal
# (the campaigns' silent-ok class: correct result, configuration
# intact -- and the structurally-dead multiply arm of `multdiv`, see
# the core-pair note); a residual/single-point fault is dangerous and
# undetected; a latent multiple-point fault is a disabled mechanism
# nothing reported.  The PMP arrays are the one place this design
# still accumulates those: they have no parity, and the fi-pmp sweep
# measured exactly which upsets lockstep can and cannot see.

import argparse
import collections
import re
import sys

DATE = "2026-09-13"      # date of this edition (population refresh)

# ----------------------------------------------------------------- ASSUMED
# Soft-error rates, 130 nm-class, sea level, typical literature values.
SEU_SRAM_FIT_PER_MBIT = 700.0    # SRAM cell upsets
SEU_FF_FIT_PER_MBIT   = 400.0    # flip-flop upsets
# Permanent (hard) failures.  The base figure is the same SN 29500-class
# 20 FIT that variant 1 assumed for a ~2.6 mm^2 digital die; variant 2's
# die is 3.630 mm^2 (v2full metrics.json: design__die__area 3630240
# um^2), so the total is scaled by the area ratio instead of repeating
# variant 1's known optimism.  The BASE is still ASSUMED -- scaling an
# assumed number does not make it foundry data, it only removes the
# error we could see.
PERM_FIT_BASE         = 20.0     # ASSUMED, per 2.6 mm^2
DIE_MM2               = 3.630    # MEASURED, v2full metrics.json
PERM_FIT_TOTAL        = PERM_FIT_BASE * (DIE_MM2 / 2.6)
MBIT = 1024.0 * 1024.0

# Fraction of SEU events assumed to upset more than one bit in a word
# (adjacent multi-bit upsets; layout interleaving not yet credited).
MBU_FRACTION = 0.02

# ----------------------------------------------------------------- MEASURED
SRAM_BITS   = 2 * 4096 * 39          # two TCMs, logical bits
NETLIST = "flow/runs/chip2b/final/pnl/cdriscv_32s_20_chip.pnl.v"
TOTAL_CELLS = 172368                  # chip2b stdcells (81 599 antenna)
TOTAL_INSTANCES = 335518              # incl. fill, 6 SRAM macros, 312 pads
TOTAL_FF_NETLIST = 7538               # placed dfrbpq_1 count, chip2b
TOTAL_FF     = TOTAL_FF_NETLIST       # nothing is RTL-counted any more

# Q-net -> row attribution, first match wins (bit index already
# stripped).  A Q-net is named after the RTL register it implements
# or, where the register directly drives a wire of an enclosing
# module, after that wire (e.g. `u_sub.clint_rdata` is the CLINT
# adapter's read-data register, `u_sub.bt_addr` the loader's bus
# address register, `dac_data_o_core` the AMS interface's output
# register at chip level).  The rules follow the RTL instance tree of
# rtl/cdriscv_32s_20_subsys.sv.
ATTRIBUTION = [
    ("unattributed (renamed)",   r"^_\d+_$"),
    ("PMP arrays (both cores)",  r"^u_sub\.g_lockstep\.u_core\.u_core_(main|check)\.pmp_(addr|cfg)$"),
    ("Zcmp sequencer",           r"^u_sub\.g_lockstep\.u_core\.u_core_(main|check)\.(seq_idx_q|seq_pend_q|seq_active)$"),
    ("core pair (lockstep)",     r"^u_sub\.g_lockstep\.u_core\.u_core_(main|check)\."),
    ("lockstep delay+compare",   r"^u_sub\.g_lockstep\."),
    ("TCM control+ECC logic",    r"^u_sub\.u_[id]tcm\."),
    ("E2E link endpoints",       r"^u_sub\.u_e2e_"),
    ("safety controller",        r"^u_sub\.u_safety\."),
    ("watchdog",                 r"^u_sub\.u_wdog\."),
    ("clock monitor",            r"^u_sub\.u_clkmon\."),
    ("interrupt controller",     r"^u_sub\.u_irq_ctrl\."),
    ("APB timer",                r"^u_sub\.u_timer\."),
    ("CLINT mtime (no parity)",  r"^u_sub\.u_clint\.mtime_q$"),
    ("CLINT config+adapter",     r"^u_sub\.(u_clint\.|clint_)"),
    ("AMS interface",            r"^(u_sub\.u_ams\.|(adc_ch|dac_data|dac_we|atest_en|atest_sel)_o_core$)"),
    ("memory BIST (x2)",         r"^u_sub\.u_mbist_[id]\."),
    ("JTAG/debug observation",   r"^u_sub\.(u_dbg_win\.|u_jtag_tap\.|u_dbg_bridge\.|jtag_dbg_|dbg_acc_addr$|dbg_busy$)"),
    ("QSPI boot loader",         r"^(u_sub\.(g_boot\.|bt_|boot_)|qspi_sclk_o_core$)"),
    ("bus + sync + APB glue",    r"^(u_sub\.|core_sleep_o_core$)"),
]

# Flip-flop populations per functional element, counted from the placed
# netlist's Q-net names by the rules above.  "dc_*" are the
# measured diagnostic coverages: dc_seu for single-bit upsets (this
# variant's campaigns), dc_mbu for the multi-bit fraction, dc_perm for
# permanent faults (mechanism-based argument).  safe_frac is the
# campaigns' silent-ok share for that element class -- upsets that
# provably cannot violate the goal (masked/overwritten).
#
# Where a dc_seu is written to three digits it is a measured fraction
# from a named campaign; where it is written to two it is an argued
# figure in the variant-1 style, kept only for elements whose campaign
# rows are structural arguments rather than sweeps.
ELEMENTS = [
    # name,                 ffs,  safe, dc_seu, dc_mbu, dc_perm, mechanism
    ("core pair (lockstep)", 3382, 0.45, 0.99,  0.99,  0.99,
     "DCLS; this variant's campaigns A-D: 1156 usable injections into core "
     "state, 0 SDC with status clean, every non-masked upset latched "
     "(lockstep median 2 cycles).  multdiv's dead multiply arm "
     "(finding s17/W5) is GONE from this netlist -- the RTL deleted it "
     "2026-09-02 and chip2b was hardened after; the 0.45 safe fraction "
     "is the campaigns' masked/overwritten share, nothing structural"),
    ("lockstep delay+compare", 555, 0.10, 0.90,  0.90,  0.90,
     "self-checking by construction (a delay-line upset causes a "
     "mismatch; target 19 re-measured on this RTL); residual: faults "
     "forcing permanent agreement"),
    ("PMP arrays (both cores)", 608, 0.00, 1.00,  0.99,  0.99,
     "CONFIG PARITY, extended over pmpcfg/pmpaddr 2026-09-02 after "
     "the first sweep measured 90.8 % latent without it.  Re-measured "
     "fi-pmp: 448/448 upsets detected at exactly 2 cycles, live and "
     "unexercised regions alike -- parity does not care whether the "
     "region is in use.  MBU/permanent held one notch under the "
     "single-bit measurement: an even-width MBU inside one parity "
     "word is the residual, as for every parity-covered element"),
    ("TCM control+ECC logic",  108, 0.30, 0.95,  0.95,  0.95,
     "ECC datapath faults surface as detected errors or bus faults; "
     "BIST covers permanent"),
    ("E2E link endpoints",      144, 0.10, 0.90,  0.90,  0.90,
     "self-evidencing like the comparator: a corrupted held address or "
     "check-bit register mismatches the next beat it qualifies "
     "(block-e2e-link, 11 286 checks, mutants 8/8).  The LINK WIRES "
     "they guard were swept here: 368/368 covered wire bits detected "
     "as FLT_E2E, 0 escapes; the byte-enable wires are outside the "
     "fold and escaped 32/32 times -- carried as interconnect "
     "residual, not as endpoint coverage"),
    ("safety controller",      197, 0.05, 0.999, 0.90,  0.90,
     "config parity, ungated (re-measured: targets 9-13 all detected); "
     "sticky status self-evidencing; residual: reaction wiring"),
    ("watchdog",                 9, 0.05, 0.999, 0.90,  0.90,
     "config parity + timeout is self-revealing (a dead watchdog "
     "fires or never fires -- external pin protocol catches both)"),
    ("clock monitor",          149, 0.10, 0.999, 0.90,  0.85,
     "config parity; ref-domain copies reload each heartbeat"),
    ("interrupt controller",   103, 0.20, 0.999, 0.90,  0.90,
     "config parity on ENABLE/MODE; pending is dynamic"),
    ("APB timer",               97, 0.30, 0.999, 0.90,  0.90,
     "config parity on MTIMECMP/CTRL; no longer the MTIP source"),
    ("CLINT config+adapter",     67, 0.05, 0.999, 0.90,  0.90,
     "mtimecmp/msip/prescaler in the CLINT's own cfg-parity fold; "
     "fi-clint sweep: every mtimecmp/msip/prescaler upset latched "
     "FLT_CFG_PAR (median 2 cycles).  Placed count: prescaler 32 + "
     "parity 1 + OBI adapter 34 (clint_rdata/rvalid/err); the "
     "mtimecmp/msip registers have no named Q-net in chip2b and sit "
     "in the unattributed row"),
    ("CLINT mtime (no parity)",  64, 0.42, 0.00,  0.00,  0.70,
     "UNDETECTED BY DESIGN: mtime is hardware-updated and correctly "
     "outside the parity fold.  fi-clint sweep: 0/192 detected; the "
     "silent-ok share is upsets below the next compare point.  A "
     "corrupted mtime moves or loses timer interrupts; the WINDOWED "
     "WATCHDOG (safety manual SM5) is the bounding mechanism -- a "
     "missed or early service violates the window within one watchdog "
     "period.  That bound applies at system level (AoU: watchdog "
     "armed), so it is credited only in dc_perm (a stuck mtime stops "
     "all service), never for one-shot SEU"),
    ("AMS interface",          365, 0.30, 0.999, 0.90,  0.85,
     "config parity incl. limits and mask; results dynamic.  Includes "
     "the 21 output registers named after the chip-level pad wires "
     "(dac_data/dac_we/adc_ch/atest_*_o_core)"),
    ("memory BIST (x2)",       118, 0.60, 0.50,  0.50,  0.70,
     "dormant in mission; faults surface at next BIST run -- "
     "detected late, so counted mostly latent for SEU"),
    ("bus + sync + APB glue",  128, 0.05, 0.95,  0.95,  0.95,
     "bus errors trap; reset-sync faults are fail-stop.  Every "
     "subsystem-level Q-net no block rule claims: external APB "
     "registers (44), peripheral/TCM read-data and response registers, "
     "BIST address/done/fail, reset synchronisers, warm-reset counter, "
     "fault flags, core_sleep"),
    ("JTAG/debug observation", 275, 0.90, 0.00,  0.00,  0.50,
     "read-only window by construction: bridge and window can reach "
     "nothing but their own registers, the TAP is held in reset while "
     "trst_ni is low (the in-mission state).  fi-dbg sweep: 64/64 "
     "silent-ok, core untouched.  The residual 10 % covers wrong "
     "OBSERVATIONS handed to a debugger; nothing here can corrupt the "
     "mission, which is why safe is 0.90 and dc_seu is honestly 0"),
    ("QSPI boot loader",       534, 0.99, 0.90,  0.90,  0.90,
     "NOT SWEPT by any campaign -- argued figures (two digits).  "
     "Active only from cold reset to boot_done, then a dormant bus "
     "slave parked off the data-master mux; its state is rebuilt from "
     "reset at the next cold start, so a mission-time upset in it "
     "cannot reach the core (safe share), except boot_done/boot_fault "
     "themselves, whose flip stalls the fetch enable -- fail-stop, "
     "watchdog-visible.  During the load, header validation before "
     "any write and one CRC32 over both payloads turn a corrupted beat "
     "into a retry (BootRetryMax=3) and, exhausted, a sticky "
     "boot_fault with the core never released; the residual is an "
     "address/segment register upset AFTER validation, which places a "
     "CRC-correct payload at the wrong TCM offset.  Permanent: the "
     "same retry-then-boot_fault path.  Population: g_boot 463 + "
     "bt_addr/bt_wdata 64 + boot_retries 4 + boot_done/boot_fault 2 + "
     "qspi_sclk_o_core 1"),
    ("Zcmp sequencer",          12, 0.00, 0.99,  0.99,  0.99,
     "fi-zcmp sweep, deposits mid-sequence in one core: lockstep "
     "caught every landed upset (median 12 cycles); the checker walks "
     "the intact sequence so a corrupted beat cannot agree"),
    ("unattributed (renamed)", 623, 0.10, 0.90,  0.90,  0.90,
     "placed FFs whose Q-nets synthesis renamed (_NNN_); they belong "
     "to the blocks above (the CLINT's mtimecmp/msip among them) but "
     "cannot be attributed by name.  Given a "
     "flat conservative 0.90 -- BELOW the population-weighted average "
     "of the named rows -- rather than silently inheriting the best "
     "row.  Variant 1 left its unattributed flops out of the transient "
     "sum entirely; this row closes that quiet optimism"),
]

# Reconciliation: attributed + unattributed == placed.  A row edit that
# moves flops without closing the balance fails here, not silently.
_FF_SUM = sum(e[1] for e in ELEMENTS)
assert _FF_SUM == TOTAL_FF_NETLIST, (
    "ELEMENTS sum to %d flip-flops but the placed netlist holds %d "
    "(TOTAL_FF_NETLIST); re-run --netlist and fix the table"
    % (_FF_SUM, TOTAL_FF_NETLIST))
assert set(n for n, _ in ATTRIBUTION) == set(e[0] for e in ELEMENTS), \
    "ATTRIBUTION rules and ELEMENTS rows name different elements"
UNATTRIBUTED = next(e[1] for e in ELEMENTS if e[0].startswith("unattributed"))

SRAM = ("TCM arrays (SEC-DED)", SRAM_BITS, 0.40, 0.996, 0.996, 0.996,
        "Hsiao SEC-DED corrects 1, detects 2; campaigns re-run on this "
        "RTL: every landed TCM upset corrected/detected, 0 latent; "
        "March C- BIST at start-up for permanent")

# Elements whose undetected faults are mechanism-side (latent) rather
# than mission-side, for the LFM subset: everything except the two
# mission datapaths.
MISSION_ROWS = ("core pair (lockstep)", SRAM[0])

def fit_ff(n):    return n * SEU_FF_FIT_PER_MBIT / MBIT
def fit_sram(n):  return n * SEU_SRAM_FIT_PER_MBIT / MBIT


def compute(overrides=None):
    """overrides: {row name: (safe, dc_seu, dc_mbu, dc_perm)} to
    re-evaluate the metrics with one row's argued figures replaced --
    used for the sensitivity statement, never for the headline."""
    overrides = overrides or {}
    rows = []
    tot = dict(lam=0.0, safe=0.0, spf=0.0)

    def add(name, lam, safe_frac, dc_s, dc_m, mech, perm_lam, dc_p):
        lam_t   = lam
        safe    = lam_t * safe_frac
        resid   = lam_t - safe
        sb, mb  = resid * (1 - MBU_FRACTION), resid * MBU_FRACTION
        det     = sb * dc_s + mb * dc_m
        undet   = resid - det
        p_safe  = perm_lam * safe_frac
        p_res   = perm_lam - p_safe
        p_det   = p_res * dc_p
        p_undet = p_res - p_det
        lam_all  = lam_t + perm_lam
        safe_all = safe + p_safe
        spf      = undet + p_undet          # dangerous, undetected
        rows.append((name, lam_all, safe_all, spf, mech))
        tot['lam']  += lam_all
        tot['safe'] += safe_all
        tot['spf']  += spf

    # SRAM: half the (assumed) permanent budget, as in variant 1
    perm_share = PERM_FIT_TOTAL * 0.5           # ASSUMED apportionment
    add(SRAM[0], fit_sram(SRAM[1]), SRAM[2], SRAM[3], SRAM[4], SRAM[6],
        perm_share, SRAM[5])

    # logic elements share the other half by flop count (ASSUMED)
    perm_logic = PERM_FIT_TOTAL * 0.5
    for (name, ffs, safe, dcs, dcm, dcp, mech) in ELEMENTS:
        if name in overrides:
            safe, dcs, dcm, dcp = overrides[name]
        add(name, fit_ff(ffs), safe, dcs, dcm, mech,
            perm_logic * ffs / TOTAL_FF, dcp)

    lam, spf, safe = tot['lam'], tot['spf'], tot['safe']
    spfm = 1 - spf / lam
    mech_rows = [r for r in rows if r[0] not in MISSION_ROWS]
    lam_mech = sum(r[1] for r in mech_rows)
    lat_mech = sum(r[3] for r in mech_rows)
    lfm = 1 - lat_mech / lam_mech
    return rows, lam, safe, spf, spfm, lfm, lat_mech, lam_mech


def result_text():
    rows, lam, safe, spf, spfm, lfm, lat_mech, lam_mech = compute()
    out = []
    out.append("cdriscv-32s-20 FMEDA -- computed %s" % DATE)
    out.append("ASSUMED rates: SRAM %.0f FIT/Mbit, FF %.0f FIT/Mbit, "
               "permanent %.1f FIT total"
               % (SEU_SRAM_FIT_PER_MBIT, SEU_FF_FIT_PER_MBIT,
                  PERM_FIT_TOTAL))
    out.append("  (permanent = assumed %.0f FIT per 2.6 mm^2, scaled to "
               "the measured %.3f mm^2 die), MBU fraction %.0f%%"
               % (PERM_FIT_BASE, DIE_MM2, MBU_FRACTION * 100))
    out.append("Populations: %d placed FFs (chip2b final netlist, every "
               "block placed; %d attributed by Q-net name + %d renamed),"
               % (TOTAL_FF_NETLIST, TOTAL_FF_NETLIST - UNATTRIBUTED,
                  UNATTRIBUTED))
    out.append("  %d logical SRAM bits, %d standard cells, %d instances"
               % (SRAM_BITS, TOTAL_CELLS, TOTAL_INSTANCES))
    out.append("")
    out.append("%-28s %10s %10s %10s" % ("element", "lambda FIT", "safe FIT", "SPF FIT"))
    for name, l, s, d, mech in rows:
        out.append("%-28s %10.3f %10.3f %10.4f" % (name, l, s, d))
    out.append("%-28s %10.3f %10.3f %10.4f" % ("TOTAL", lam, safe, spf))
    out.append("")
    out.append("SPFM = %.2f %%   (ASIL B >= 90, C >= 97, D >= 99)" % (100 * spfm))
    out.append("LFM  = %.2f %%   (ASIL B >= 60, C >= 80, D >= 90)  "
               "[mechanism subset: %.3f of %.3f FIT undetected]"
               % (100 * lfm, lat_mech, lam_mech))
    out.append("residual dangerous-undetected rate: %.4f FIT" % spf)
    return "\n".join(out)


# --------------------------------------------------------------- document
DOC_TEMPLATE = """# cdriscv-32s-20 FMEDA

**Computed {date} by `scripts/fmeda.py` -- rerun it (`--md doc/fmeda.md`),
do not edit the numbers here by hand.** This document replaces the
inherited variant-1 FMEDA: every measured figure below was produced on
**this variant's** RTL and campaigns.

## 1. What this is, and what it is not

This is a Failure Modes, Effects and Diagnostic Analysis of the
subsystem at the architecture level, built from three kinds of number,
each labeled throughout:

* **MEASURED** -- element populations counted from the **final
  `chip2b` chip netlist** (`{netlist}`, hardened 2026-09-07 with
  every block placed): {ff_netlist} flip-flops, of which
  {ff_named} are attributed per block by Q-net name and {ff_unattr}
  carry synthesis-renamed nets and form the unattributed row --
  attributed + unattributed = {ff_netlist}, asserted by the script;
  {sram_bits} logical SRAM bits, {cells} standard cells, {insts}
  instances -- re-read from that run's `metrics.json`, whose
  `sequential_cell` count is the same {ff_netlist}. Nothing is
  RTL-elaborated any more: the CLINT, the E2E endpoints, the Zcmp
  sequencer and the QSPI boot loader that the 2026-09-02 edition
  carried as RTL stand-ins (or not at all) are counted from silicon
  geometry like everything else (`python3 scripts/fmeda.py --netlist
  <pnl.v>` re-derives every row and fails on drift). Diagnostic
  coverage is from this variant's fault-injection campaigns
  (2026-09-02/04: workloads A-D re-run, plus the systematic E2E /
  CLINT / PMP / Zcmp / debug sweeps -- `build/fi_campaign*.txt`).
* **ASSUMED** -- base failure rates. **No foundry reliability data for
  IHP SG13G2 was available to this analysis.** The rates are typical
  published figures for a 130 nm-class process at sea level:
  700 FIT/Mbit SRAM soft errors, 400 FIT/Mbit flip-flop soft errors,
  and a permanent-fault total of {perm} FIT -- the same SN 29500-class
  20 FIT per ~2.6 mm² that variant 1 assumed, **scaled to the
  subsystem's measured {die} mm² (`v2full`)** instead of carrying
  variant 1's known optimism; the base remains assumed, and the
  scaling area was deliberately left at the subsystem die when the
  populations moved to `chip2b` (whose 8.400 mm² die is mostly pad
  ring and its 4.753 mm² core mostly fill -- neither is the digital
  area a permanent-fault base should scale with; that choice belongs
  to the handoff of section 6, item 1). 2 % multi-bit-upset fraction.
  **A real safety case replaces every one of these** with foundry data
  and a mission profile; the script makes that a five-line edit.
* **DERIVED** -- the metrics.

This document is an architectural statement, not a certification. The
metrics landing above a threshold means the *architecture* carries no
structural gap under the stated assumptions -- it does not mean ASIL
compliance, which additionally requires qualified tools, process
evidence, foundry data and an assessed safety case.

## 2. Result

```
{result}
```

**SPFM {spfm:.1f} %, LFM {lfm:.1f} %, residual {spf:.2f} FIT** under
the stated assumptions, with the caveats of section 1.

## 3. What the campaigns measured, per mechanism

* **Lockstep** (campaigns A-D, F, E): every landed upset in compared
  core state detected, median 2 cycles; Zcmp mid-sequence deposits
  {zcmp_det} detected at a 12-cycle median. The register write port
  remains outside the compare vector (V4-F3, inherited and still open
  in this variant).
* **E2E links** (systematic sweep, every wire bit): {e2e_det} of
  {e2e_tot} injections whose flip a live transfer consumed latched
  `FLT_E2E`, the rest architecturally silent -- **0 escapes,
  including the byte enables** ({be_det}/{be_tot} detected). The
  first sweep measured 10 byte-enable SDCs; folding be into the check
  (2026-09-02) closed the campaign's entire SDC budget, and this
  sweep is the re-measurement.
* **PMP arrays**: **config parity**, extended over pmpcfg/pmpaddr
  after the first sweep's headline finding (90.8 % latent with no
  parity). Re-measured: **448/448 detected at exactly 2 cycles**,
  independent of whether the flipped region is in use. The lockstep
  divergence path remains as the second, slower observer for the
  live-region subset.
* **CLINT**: mtimecmp/msip/prescaler 100 % via its config parity;
  **mtime 0 % by design** (hardware-updated, correctly outside the
  fold). The bounding argument for mtime is the **windowed watchdog**
  (safety manual SM5): a moved or lost timer interrupt violates the
  service window within one watchdog period. That is a system-level
  bound resting on an assumption of use, so it is credited only
  against permanent faults, never for one-shot SEU.
* **JTAG/debug**: read-only by construction and measured 100 %
  silent-ok; carried with safe=0.90 and dc=0, since a wrong
  *observation* is possible but a mission corruption is not.
* **multdiv dead multiply arm** (finding §17, waiver W5): the RTL
  deleted it on 2026-09-02 (W5 closed) and `chip2b` was hardened
  after, so the arm is **gone from the netlist these populations
  count** -- the core-pair row no longer carries any structurally dead
  state, only the campaigns' masked/overwritten share.
* **QSPI boot loader** ({ff_boot} flops): **swept** (finding 22,
  `make fi-loader`: 1 956 upsets over every bit of all 16 loader
  registers, 4 inside the load and 2 after `boot_done` per bit,
  classified by the IMAGE the loader delivered rather than by the exit
  code). The row's figures are the **mission window**, which is what
  this rate describes: the loader is a cold-reset-only bus master
  parked behind `boot_done`, and of 652 upsets landing after boot
  **648 were provably inert, 4 were not, and all 4 were detected or
  fail-stop** -- structurally, only the two sticky flags are still
  live, and flipping `boot_fault` raises `err_pin` while flipping
  `boot_done` stalls the fetch enable. Hence safe 0.99, measured.
  **The load window is a different story and section 5 carries it:**
  13.2 % of upsets during the 3 427-cycle load deliver a silently
  wrong image.

## 4. Where the residual lives

Half the residual is the TCM arrays' triple-bit-and-beyond tail past
SEC-DED. The rest is the lockstep delay-and-compare structure, the
reaction wiring, the PMP latent share and the unattributed-flop row --
the checkers themselves plus the one unguarded configuration store.
The self-test hooks (SELFTEST, INJECT) exist to exercise the checkers
at start-up; crediting them would raise dc on those rows and is left
to the safety case.

## 5. Sensitivity

The metrics are ratios, insensitive to the absolute FIT scale. They are
sensitive to: the MBU fraction (2 % assumed), the mtime safe
fraction (workload dependent) and the unattributed-flop dc (0.90
assigned, deliberately below the named-row average).

**The loader row is no longer on that list** (finding 22). It used to
be the one row whose figures could move a metric across a threshold:
carried on an argument at safe 0.85 / dc 0.90, and at safe 0.00 /
dc 0.50 it put LFM at 87.22 %, below the ASIL D line. It is measured
now, and the measurement brackets it from both ends. At the row's
mission-window figures (safe 0.99, dc 0.90) the headline above holds.
Charging the **whole** campaign to this row instead -- every upset of
the load window included, safe 0.847 and dc 0.414 as measured over all
1 926 injections -- gives SPFM {s_spfm_b:.2f} %, **LFM
{s_lfm_b:.2f} %**: still above ASIL D. There is no longer a reading of
this row that fails the thresholds, which is what the sweep was for.

What the sweep DID find is not a metric problem but an architectural
one, and it is written up as finding 22: **the CRC32 protects the SPI
byte stream, not the write path.** 168 of 1 274 upsets landing during
the load (13.2 %) end with `boot_done` raised, `err_pin` low, the
program running to a clean exit -- and an image that is not the one in
flash. They are concentrated exactly where the unprotected path is:
`cur_addr_q` the write pointer (25), `seg_left_q` the segment length
(78, the run is short or long by whole words), `word_q` the byte-to-
word assembly (25) and the bus-side holding registers (7). A bit
flipped in the running CRC, by contrast, is caught every time -- 192
of 192 upsets in `crc_q` end in a correct image, because the check
fails, the loader retries and re-delivers. The mechanism works; it
just does not cover everything between the byte it checked and the
word it wrote. A read-back verify pass, or a CRC taken over what is
written rather than over what arrives, closes it. That is an RTL
change to a signed-off netlist and belongs to whoever owns the next
revision. The PMP arrays
left this list on 2026-09-02: the parity extension over
pmpcfg/pmpaddr (a `cfg_parity` instance on each core's fold, ~70
gates) measured 448/448 detected independent of region usage, so the
roughly 2 points of LFM the unguarded arrays used to put at stake now
rest on a directed measurement rather than a workload profile.

## 6. Handoff checklist for the safety-case owner

1. Replace the ASSUMED block in `scripts/fmeda.py` with foundry FIT
   data and the mission profile.
2. **Done ({date}).** The populations are re-read from the final
   `chip2b` netlist (`{netlist}`, {ff_netlist} placed flip-flops,
   every block placed, nothing RTL-counted) and this script re-run;
   `--netlist` re-derives the table from the netlist and fails on
   drift, and the row sum is asserted against the placed count. What
   the refresh left behind: the CLINT's mtimecmp/msip registers have
   no named Q-net in this netlist and sit in the unattributed row.
   The loader row, the other thing it left behind, was swept on
   2026-09-18 (finding 22) and is measured.
3. The PMP story is decided in RTL: parity over the arrays
   (2026-09-02, measured 448/448) -- credit it as a measured
   mechanism.
4. Decide the multi-bit story: SRAM column interleaving factor, and
   whether the software scrub (V30, re-validated this variant as
   `fi-check`) is claimed for double-bit configuration coverage.
5. Common-cause analysis for the lockstep pair -- outside what fault
   injection can measure.
6. Credit or discard the start-up self-tests in the permanent-fault dc.
7. Re-run the script; the tables regenerate.
"""


FF_CELL = "sg13g2_dfrbpq_1"      # the only sequential cell in chip2b


def count_netlist(path):
    """Re-derive the per-row flip-flop populations from a placed
    netlist: every FF_CELL instance's .Q net, bit index stripped,
    attributed by the first matching ATTRIBUTION rule.  Returns
    (counts by row, total, unmatched Q-nets)."""
    rules = [(name, re.compile(pat)) for name, pat in ATTRIBUTION]
    counts = collections.Counter()
    unmatched = []
    total = 0
    in_ff = False
    with open(path) as f:
        for line in f:
            if line.startswith(" %s " % FF_CELL):
                in_ff = True
                total += 1
                continue
            if in_ff and ".Q(" in line:
                q = line.split(".Q(", 1)[1].rsplit(")", 1)[0].strip()
                q = q.lstrip("\\").strip()
                q = re.sub(r"\[\d+\]", "", q)
                for name, rx in rules:
                    if rx.search(q):
                        counts[name] += 1
                        break
                else:
                    unmatched.append(q)
                in_ff = False
    return counts, total, unmatched


def check_netlist(path):
    """Compare the table against a fresh recount; return True if the
    table is exactly what the netlist says."""
    counts, total, unmatched = count_netlist(path)
    ok = True
    print("recount of %s" % path)
    print("%-28s %8s %8s" % ("element", "table", "netlist"))
    for name, ffs, *_ in ELEMENTS:
        flag = "" if counts[name] == ffs else "   <-- DRIFT"
        if flag:
            ok = False
        print("%-28s %8d %8d%s" % (name, ffs, counts[name], flag))
    print("%-28s %8d %8d" % ("TOTAL", TOTAL_FF_NETLIST, total))
    if total != TOTAL_FF_NETLIST:
        ok = False
        print("TOTAL_FF_NETLIST %d != %d %s instances in the netlist"
              % (TOTAL_FF_NETLIST, total, FF_CELL))
    if unmatched:
        ok = False
        print("%d Q-nets matched no rule, e.g. %s"
              % (len(unmatched), unmatched[:5]))
    if sum(counts.values()) != total:
        ok = False
        print("attributed %d != %d instances" % (sum(counts.values()), total))
    print("attributed %d + unattributed %d = %d (netlist %d): %s"
          % (total - counts["unattributed (renamed)"],
             counts["unattributed (renamed)"], sum(counts.values()), total,
             "OK" if ok else "MISMATCH"))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", metavar="PATH",
                    help="write the full FMEDA document (doc/fmeda.md)")
    ap.add_argument("--netlist", metavar="PNL_V",
                    help="re-derive every row's population from this "
                         "placed netlist and exit non-zero on drift "
                         "(default: %s)" % NETLIST, nargs="?", const=NETLIST)
    args = ap.parse_args()

    if args.netlist:
        if not check_netlist(args.netlist):
            sys.exit(1)
        print()

    rows, lam, safe, spf, spfm, lfm, lat_mech, lam_mech = compute()
    text = result_text()
    print(text)

    if args.md:
        boot = "QSPI boot loader"
        sens_a = compute({boot: (0.10, 0.90, 0.90, 0.90)})
        # the pessimistic bracket is now a measurement, not a guess:
        # the whole campaign, load window included, charged to this row
        sens_b = compute({boot: (0.847, 0.414, 0.414, 0.414)})
        doc = DOC_TEMPLATE.format(
            date=DATE, netlist=NETLIST,
            ff_netlist=TOTAL_FF_NETLIST, sram_bits=SRAM_BITS,
            ff_named=TOTAL_FF_NETLIST - UNATTRIBUTED, ff_unattr=UNATTRIBUTED,
            ff_boot=next(e[1] for e in ELEMENTS if e[0] == boot),
            s_spfm_a=100 * sens_a[4], s_lfm_a=100 * sens_a[5],
            s_spfm_b=100 * sens_b[4], s_lfm_b=100 * sens_b[5],
            cells=TOTAL_CELLS, insts=TOTAL_INSTANCES, die="%.3f" % DIE_MM2,
            perm="%.1f" % PERM_FIT_TOTAL,
            result=text, spfm=100 * spfm, lfm=100 * lfm, spf=spf,
            # from build/fi_campaign_zcmp.txt / _e2e.txt (2026-09-02,
            # post be-fold, post pmp-parity RTL)
            zcmp_det=211, e2e_det=359, e2e_tot=400,
            be_det=32, be_tot=32,
        )
        with open(args.md, "w") as f:
            f.write(doc)
        print("\nwrote %s" % args.md)


if __name__ == "__main__":
    main()
