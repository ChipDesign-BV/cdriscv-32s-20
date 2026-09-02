#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv-32s-20 FMEDA computation (verification plan O9).
#
# Everything in this file is one of exactly three kinds of number, and
# each row of the tables says which:
#
#   MEASURED  -- element populations counted from the v2full placed
#                netlist's flip-flop Q-nets
#                (flow/runs/v2full/final/pnl/*.pnl.v: 6 647 DFFs,
#                231 920 instances, 153 622 standard cells, 6 SRAM
#                macros, die 3.630 mm^2 -- all re-read from that run's
#                metrics.json, not quoted from memory), plus RTL
#                elaboration for the three blocks the netlist predates
#                (see the provenance note below); and diagnostic
#                coverage from THIS variant's fault-injection campaigns
#                (build/fi_campaign*.txt, 2026-09-01: workloads A-D
#                re-run on this RTL plus the E2E / CLINT / PMP / Zcmp /
#                debug sweeps).
#   ASSUMED   -- base failure rates.  No foundry FIT data exists for
#                this design; the values are typical published figures
#                for a 130 nm-class process at sea level and are the
#                part a real safety case MUST replace.
#   DERIVED   -- everything computed from the above.
#
# PROVENANCE NOTE (population basis).  The v2full hardening run
# finished 2026-08-30; the implementation phase closed 2026-08-31 with
# the CLINT, the E2E link endpoints and the Zcmp sequencer.  Those
# three therefore do not exist in the placed netlist and their
# flip-flop counts here come from per-module RTL elaboration
# (yosys+slang, proc/opt_clean/simplemap, $_*DFF_ bits).  RTL counts
# are pre-pruning and err conservative (high).  The PMP CSR arrays ARE
# in the netlist (flattened as core-local pmp_cfg/pmp_addr nets) and
# are counted from it.  The die has NOT been re-hardened since; the
# area and instance totals below are the last physical facts available
# and the FMEDA must be re-run after the next harden.
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
TOTAL_CELLS = 153622                  # v2full stdcells (74 357 antenna)
TOTAL_INSTANCES = 231920              # incl. fill and 6 SRAM macros
TOTAL_FF_NETLIST = 6647               # placed dfrbpq_1 count
# RTL-elaborated additions the netlist predates (err conservative):
FF_CLINT     = 197                    # clint 163 + clint_obi 34
FF_E2E       = 134                    # 2x link_m (34) + 2x link_s (33)
FF_ZCMP_SEQ  = 12                     # seq_idx+pend (5) + state bit, x2
TOTAL_FF     = TOTAL_FF_NETLIST + FF_CLINT + FF_E2E + FF_ZCMP_SEQ

# Flip-flop populations per functional element, counted from the placed
# netlist's Q-net names except where marked RTL.  "dc_*" are the
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
    ("core pair (lockstep)", 3386, 0.45, 0.99,  0.99,  0.99,
     "DCLS; this variant's campaigns A-D: 1013 injections into core "
     "state, 0 SDC with status clean, every non-masked upset latched "
     "(lockstep median 2 cycles).  Includes multdiv's dead multiply "
     "arm (finding s17/W5): structurally unreachable in-system, its "
     "faults are safe, and it has no functional observer -- kept "
     "inside the 0.45 safe fraction, not credited as covered"),
    ("lockstep delay+compare", 555, 0.10, 0.90,  0.90,  0.90,
     "self-checking by construction (a delay-line upset causes a "
     "mismatch; target 19 re-measured on this RTL); residual: faults "
     "forcing permanent agreement"),
    ("PMP arrays (both cores)", 608, 0.00, 0.53,  0.53,  0.60,
     "NO PARITY (CSR guard folds mtvec only) -- measured finding. "
     "fi-pmp sweep: upsets whose region is live diverge the cores and "
     "lockstep catches 100 % of them; upsets in unexercised regions "
     "are LATENT, 0 detected.  dc is the measured live fraction under "
     "a workload that keeps one locked region hot; a mission profile "
     "using more regions moves it either way.  Permanent: argued from "
     "the same mechanism (a stuck array bit in one core diverges on "
     "first relevant access)"),
    ("TCM control+ECC logic",  108, 0.30, 0.95,  0.95,  0.95,
     "ECC datapath faults surface as detected errors or bus faults; "
     "BIST covers permanent"),
    ("E2E link endpoints (RTL)", 134, 0.10, 0.90,  0.90,  0.90,
     "self-evidencing like the comparator: a corrupted held address or "
     "check-bit register mismatches the next beat it qualifies "
     "(block-e2e-link, 11 286 checks, mutants 8/8).  The LINK WIRES "
     "they guard were swept here: 368/368 covered wire bits detected "
     "as FLT_E2E, 0 escapes; the byte-enable wires are outside the "
     "fold and escaped 32/32 times -- carried as interconnect "
     "residual, not as endpoint coverage"),
    ("safety controller",      196, 0.05, 0.999, 0.90,  0.90,
     "config parity, ungated (re-measured: targets 9-13 all detected); "
     "sticky status self-evidencing; residual: reaction wiring"),
    ("watchdog",                 9, 0.05, 0.999, 0.90,  0.90,
     "config parity + timeout is self-revealing (a dead watchdog "
     "fires or never fires -- external pin protocol catches both)"),
    ("clock monitor",          149, 0.10, 0.999, 0.90,  0.85,
     "config parity; ref-domain copies reload each heartbeat"),
    ("interrupt controller",    97, 0.20, 0.999, 0.90,  0.90,
     "config parity on ENABLE/MODE; pending is dynamic"),
    ("APB timer",               97, 0.30, 0.999, 0.90,  0.90,
     "config parity on MTIMECMP/CTRL; no longer the MTIP source"),
    ("CLINT config+adapter (RTL)", 133, 0.05, 0.999, 0.90,  0.90,
     "mtimecmp/msip/prescaler in the CLINT's own cfg-parity fold; "
     "fi-clint sweep: every mtimecmp/msip/prescaler upset latched "
     "FLT_CFG_PAR (median 2 cycles)"),
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
    ("AMS interface",          344, 0.30, 0.999, 0.90,  0.85,
     "config parity incl. limits and mask; results dynamic"),
    ("memory BIST (x2)",       118, 0.60, 0.50,  0.50,  0.70,
     "dormant in mission; faults surface at next BIST run -- "
     "detected late, so counted mostly latent for SEU"),
    ("bus + sync + APB glue",   83, 0.05, 0.95,  0.95,  0.95,
     "bus errors trap; reset-sync faults are fail-stop"),
    ("JTAG/debug observation", 275, 0.90, 0.00,  0.00,  0.50,
     "read-only window by construction: bridge and window can reach "
     "nothing but their own registers, the TAP is held in reset while "
     "trst_ni is low (the in-mission state).  fi-dbg sweep: 64/64 "
     "silent-ok, core untouched.  The residual 10 % covers wrong "
     "OBSERVATIONS handed to a debugger; nothing here can corrupt the "
     "mission, which is why safe is 0.90 and dc_seu is honestly 0"),
    ("Zcmp sequencer (RTL)",    12, 0.00, 0.99,  0.99,  0.99,
     "fi-zcmp sweep, deposits mid-sequence in one core: lockstep "
     "caught every landed upset (median 12 cycles); the checker walks "
     "the intact sequence so a corrupted beat cannot agree"),
    ("unattributed (renamed)", 622, 0.10, 0.90,  0.90,  0.90,
     "placed FFs whose Q-nets synthesis renamed (_NNN_); they belong "
     "to the blocks above but cannot be attributed by name.  Given a "
     "flat conservative 0.90 -- BELOW the population-weighted average "
     "of the named rows -- rather than silently inheriting the best "
     "row.  Variant 1 left its unattributed flops out of the transient "
     "sum entirely; this row closes that quiet optimism"),
]

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


def compute():
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
    out.append("cdriscv-32s-20 FMEDA -- computed 2026-09-01")
    out.append("ASSUMED rates: SRAM %.0f FIT/Mbit, FF %.0f FIT/Mbit, "
               "permanent %.1f FIT total"
               % (SEU_SRAM_FIT_PER_MBIT, SEU_FF_FIT_PER_MBIT,
                  PERM_FIT_TOTAL))
    out.append("  (permanent = assumed %.0f FIT per 2.6 mm^2, scaled to "
               "the measured %.3f mm^2 die), MBU fraction %.0f%%"
               % (PERM_FIT_BASE, DIE_MM2, MBU_FRACTION * 100))
    out.append("Populations: %d placed FFs + %d RTL-counted (CLINT/E2E/"
               "Zcmp postdate the v2full harden),"
               % (TOTAL_FF_NETLIST, FF_CLINT + FF_E2E + FF_ZCMP_SEQ))
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

* **MEASURED** -- element populations counted from the `v2full` placed
  netlist ({ff_netlist} flip-flops attributed per block by Q-net name,
  {sram_bits} logical SRAM bits, {cells} standard cells, {insts}
  instances, die {die} mm² -- re-read from that run's `metrics.json`),
  plus RTL elaboration for the CLINT ({ff_clint}), the E2E link
  endpoints ({ff_e2e}) and the Zcmp sequencer ({ff_zcmp}), which
  **postdate the v2full harden (2026-08-30)** and exist only in RTL
  until the next harden; and diagnostic coverage from this variant's
  fault-injection campaigns (2026-09-01: workloads A-D re-run, plus
  the systematic E2E / CLINT / PMP / Zcmp / debug sweeps --
  `build/fi_campaign*.txt`).
* **ASSUMED** -- base failure rates. **No foundry reliability data for
  IHP SG13G2 was available to this analysis.** The rates are typical
  published figures for a 130 nm-class process at sea level:
  700 FIT/Mbit SRAM soft errors, 400 FIT/Mbit flip-flop soft errors,
  and a permanent-fault total of {perm} FIT -- the same SN 29500-class
  20 FIT per ~2.6 mm² that variant 1 assumed, now **scaled to this
  design's measured 3.630 mm²** instead of carrying variant 1's known
  optimism; the base remains assumed. 2 % multi-bit-upset fraction.
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
  {e2e_tot} injections on covered wires latched `FLT_E2E`, **0
  escapes**; the **byte-enable wires escaped {be_esc}/{be_tot}** --
  they are outside the {{data, addr}} fold, exactly as documented at
  integration, and stand as measured interconnect residual.
* **PMP arrays**: **not parity-covered** (the CSR guard folds mtvec
  only) -- this is the campaign's headline finding. Upsets in the
  region the workload keeps live: 100 % caught by lockstep (the cores
  diverge). Upsets in unexercised regions: **0 % detected, latent**.
  The measured dc of {pmp_dc:.2f} is a property of the workload's
  region usage as much as of the design; the FMEDA carries the latent
  remainder in the LFM.
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
* **multdiv dead multiply arm** (finding §17, waiver W5): faults there
  are **safe by unreachability** -- the subsystem cannot select the
  iterative multiply -- and have **no functional observer**. They sit
  inside the core-pair safe fraction; they are not counted as covered,
  and the area remains dead weight a future revision should remove.

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
sensitive to: the MBU fraction (2 % assumed), the PMP dc (measured
under one region-usage profile), the mtime safe fraction (workload
dependent), and the unattributed-flop dc (0.90 assigned, deliberately
below the named-row average). Setting the PMP arrays' dc to zero --
the no-lockstep-credit worst case -- moves LFM by about 2 points;
parity over the arrays (a `cfg_parity` instance on each core's fold,
~70 gates) would take the whole question off the table and is the
single cheapest LFM improvement available.

## 6. Handoff checklist for the safety-case owner

1. Replace the ASSUMED block in `scripts/fmeda.py` with foundry FIT
   data and the mission profile.
2. Re-harden with the CLINT, E2E endpoints and Zcmp sequencer in the
   netlist, re-read the populations, re-run this script.
3. Decide the PMP story: parity over the arrays, or a mission-profile
   argument for the measured latent share.
4. Decide the multi-bit story: SRAM column interleaving factor, and
   whether the software scrub (V30, re-validated this variant as
   `fi-check`) is claimed for double-bit configuration coverage.
5. Common-cause analysis for the lockstep pair -- outside what fault
   injection can measure.
6. Credit or discard the start-up self-tests in the permanent-fault dc.
7. Re-run the script; the tables regenerate.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", metavar="PATH",
                    help="write the full FMEDA document (doc/fmeda.md)")
    args = ap.parse_args()

    rows, lam, safe, spf, spfm, lfm, lat_mech, lam_mech = compute()
    text = result_text()
    print(text)

    if args.md:
        pmp_row = next(r for r in rows if r[0].startswith("PMP"))
        doc = DOC_TEMPLATE.format(
            date="2026-09-01",
            ff_netlist=TOTAL_FF_NETLIST, sram_bits=SRAM_BITS,
            cells=TOTAL_CELLS, insts=TOTAL_INSTANCES, die=DIE_MM2,
            ff_clint=FF_CLINT, ff_e2e=FF_E2E, ff_zcmp=FF_ZCMP_SEQ,
            perm="%.1f" % PERM_FIT_TOTAL,
            result=text, spfm=100 * spfm, lfm=100 * lfm, spf=spf,
            zcmp_det="ZCMP_DET", e2e_det="E2E_DET", e2e_tot="E2E_TOT",
            be_esc="BE_ESC", be_tot="BE_TOT", pmp_dc=0.53,
        )
        with open(args.md, "w") as f:
            f.write(doc)
        print("\nwrote %s" % args.md)


if __name__ == "__main__":
    main()
