# cdriscv-32s-20 FMEDA

**Computed 2026-09-02 by `scripts/fmeda.py` -- rerun it (`--md doc/fmeda.md`),
do not edit the numbers here by hand.** This document replaces the
inherited variant-1 FMEDA: every measured figure below was produced on
**this variant's** RTL and campaigns.

## 1. What this is, and what it is not

This is a Failure Modes, Effects and Diagnostic Analysis of the
subsystem at the architecture level, built from three kinds of number,
each labeled throughout:

* **MEASURED** -- element populations counted from the `v2full` placed
  netlist (6647 flip-flops attributed per block by Q-net name,
  319488 logical SRAM bits, 153622 standard cells, 231920
  instances, die 3.63 mm² -- re-read from that run's `metrics.json`),
  plus RTL elaboration for the CLINT (197), the E2E link
  endpoints (134) and the Zcmp sequencer (12), which
  **postdate the v2full harden (2026-08-30)** and exist only in RTL
  until the next harden; and diagnostic coverage from this variant's
  fault-injection campaigns (2026-09-02/04: workloads A-D re-run, plus
  the systematic E2E / CLINT / PMP / Zcmp / debug sweeps --
  `build/fi_campaign*.txt`).
* **ASSUMED** -- base failure rates. **No foundry reliability data for
  IHP SG13G2 was available to this analysis.** The rates are typical
  published figures for a 130 nm-class process at sea level:
  700 FIT/Mbit SRAM soft errors, 400 FIT/Mbit flip-flop soft errors,
  and a permanent-fault total of 27.9 FIT -- the same SN 29500-class
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
cdriscv-32s-20 FMEDA -- computed 2026-09-01
ASSUMED rates: SRAM 700 FIT/Mbit, FF 400 FIT/Mbit, permanent 27.9 FIT total
  (permanent = assumed 20 FIT per 2.6 mm^2, scaled to the measured 3.630 mm^2 die), MBU fraction 2%
Populations: 6647 placed FFs + 343 RTL-counted (CLINT/E2E/Zcmp postdate the v2full harden),
  319488 logical SRAM bits, 153622 standard cells, 231920 instances

element                      lambda FIT   safe FIT    SPF FIT
TCM arrays (SEC-DED)            227.243     90.897     0.5454
core pair (lockstep)              8.055      3.625     0.0443
lockstep delay+compare            1.320      0.132     0.1188
PMP arrays (both cores)           1.446      0.000     0.0122
TCM control+ECC logic             0.257      0.077     0.0090
E2E link endpoints (RTL)          0.319      0.032     0.0287
safety controller                 0.466      0.023     0.0374
watchdog                          0.021      0.001     0.0017
clock monitor                     0.354      0.035     0.0403
interrupt controller              0.231      0.046     0.0156
APB timer                         0.231      0.069     0.0136
CLINT config+adapter (RTL)        0.316      0.016     0.0254
CLINT mtime (no parity)           0.152      0.064     0.0364
AMS interface                     0.818      0.245     0.0724
memory BIST (x2)                  0.281      0.168     0.0373
bus + sync + APB glue             0.197      0.010     0.0094
JTAG/debug observation            0.654      0.589     0.0380
Zcmp sequencer (RTL)              0.029      0.000     0.0003
unattributed (renamed)            1.480      0.148     0.1332
TOTAL                           243.871     96.178     1.2193

SPFM = 99.50 %   (ASIL B >= 90, C >= 97, D >= 99)
LFM  = 92.66 %   (ASIL B >= 60, C >= 80, D >= 90)  [mechanism subset: 0.630 of 8.573 FIT undetected]
residual dangerous-undetected rate: 1.2193 FIT
```

**SPFM 99.5 %, LFM 92.7 %, residual 1.22 FIT** under
the stated assumptions, with the caveats of section 1.

## 3. What the campaigns measured, per mechanism

* **Lockstep** (campaigns A-D, F, E): every landed upset in compared
  core state detected, median 2 cycles; Zcmp mid-sequence deposits
  211 detected at a 12-cycle median. The register write port
  remains outside the compare vector (V4-F3, inherited and still open
  in this variant).
* **E2E links** (systematic sweep, every wire bit): 359 of
  400 injections whose flip a live transfer consumed latched
  `FLT_E2E`, the rest architecturally silent -- **0 escapes,
  including the byte enables** (32/32 detected). The
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
