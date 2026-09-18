# cdriscv-32s-20 FMEDA

**Computed 2026-09-13 by `scripts/fmeda.py` -- rerun it (`--md doc/fmeda.md`),
do not edit the numbers here by hand.** This document replaces the
inherited variant-1 FMEDA: every measured figure below was produced on
**this variant's** RTL and campaigns.

## 1. What this is, and what it is not

This is a Failure Modes, Effects and Diagnostic Analysis of the
subsystem at the architecture level, built from three kinds of number,
each labeled throughout:

* **MEASURED** -- element populations counted from the **final
  `chip2b` chip netlist** (`flow/runs/chip2b/final/pnl/cdriscv_32s_20_chip.pnl.v`, hardened 2026-09-07 with
  every block placed): 7538 flip-flops, of which
  6915 are attributed per block by Q-net name and 623
  carry synthesis-renamed nets and form the unattributed row --
  attributed + unattributed = 7538, asserted by the script;
  319488 logical SRAM bits, 172368 standard cells, 335518
  instances -- re-read from that run's `metrics.json`, whose
  `sequential_cell` count is the same 7538. Nothing is
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
  and a permanent-fault total of 27.9 FIT -- the same SN 29500-class
  20 FIT per ~2.6 mm² that variant 1 assumed, **scaled to the
  subsystem's measured 3.630 mm² (`v2full`)** instead of carrying
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
cdriscv-32s-20 FMEDA -- computed 2026-09-13
ASSUMED rates: SRAM 700 FIT/Mbit, FF 400 FIT/Mbit, permanent 27.9 FIT total
  (permanent = assumed 20 FIT per 2.6 mm^2, scaled to the measured 3.630 mm^2 die), MBU fraction 2%
Populations: 7538 placed FFs (chip2b final netlist, every block placed; 6915 attributed by Q-net name + 623 renamed),
  319488 logical SRAM bits, 172368 standard cells, 335518 instances

element                      lambda FIT   safe FIT    SPF FIT
TCM arrays (SEC-DED)            227.243     90.897     0.5454
core pair (lockstep)              7.554      3.399     0.0415
lockstep delay+compare            1.240      0.124     0.1116
PMP arrays (both cores)           1.358      0.000     0.0113
TCM control+ECC logic             0.241      0.072     0.0084
E2E link endpoints                0.322      0.032     0.0289
safety controller                 0.440      0.022     0.0349
watchdog                          0.020      0.001     0.0016
clock monitor                     0.333      0.033     0.0374
interrupt controller              0.230      0.046     0.0154
APB timer                         0.217      0.065     0.0127
CLINT config+adapter              0.150      0.007     0.0119
CLINT mtime (no parity)           0.143      0.060     0.0348
AMS interface                     0.815      0.245     0.0713
memory BIST (x2)                  0.264      0.158     0.0352
bus + sync + APB glue             0.286      0.014     0.0136
JTAG/debug observation            0.614      0.553     0.0360
QSPI boot loader                  1.193      1.181     0.0012
Zcmp sequencer                    0.027      0.000     0.0003
unattributed (renamed)            1.392      0.139     0.1252
TOTAL                           244.080     97.050     1.1785

SPFM = 99.52 %   (ASIL B >= 90, C >= 97, D >= 99)
LFM  = 93.63 %   (ASIL B >= 60, C >= 80, D >= 90)  [mechanism subset: 0.592 of 9.283 FIT undetected]
residual dangerous-undetected rate: 1.1785 FIT
```

**SPFM 99.5 %, LFM 93.6 %, residual 1.18 FIT** under
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
* **multdiv dead multiply arm** (finding §17, waiver W5): the RTL
  deleted it on 2026-09-02 (W5 closed) and `chip2b` was hardened
  after, so the arm is **gone from the netlist these populations
  count** -- the core-pair row no longer carries any structurally dead
  state, only the campaigns' masked/overwritten share.
* **QSPI boot loader** (534 flops): **swept** (finding 22,
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
1 926 injections -- gives SPFM 99.47 %, **LFM
92.49 %**: still above ASIL D. There is no longer a reading of
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
2. **Done (2026-09-13).** The populations are re-read from the final
   `chip2b` netlist (`flow/runs/chip2b/final/pnl/cdriscv_32s_20_chip.pnl.v`, 7538 placed flip-flops,
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
