# cdriscv-32s-20

**A 32-bit RISC-V core subsystem for safety-critical mixed-signal SoCs,
with higher performance.**

This is **variant 2** of [cdriscv-32s-10](https://github.com/ChipDesign-BV/cdriscv-32s-10).
It starts from that design and adds a wider ISA (bit manipulation and
compressed instructions, including Zcmp), physical memory protection on
data **and** fetch, a standard CLINT, a JTAG TAP with a read-only debug
window, and end-to-end protection on both TCM bus links — all
integrated in the subsystem ([doc/variant_status.md](doc/variant_status.md)
has the per-module evidence). It also carries a **full-chip top**
(`rtl/chip/`) in an IHP SG13G2 pad ring, hardened and timing-closed —
[doc/chip.md](doc/chip.md). Variant 1 remains the signed-off
configuration and is not modified by anything here.

**On the name.** The `s` denotes what the part is *designed for*, not what
it has been *certified as*. It is an architectural statement — dual-core
lockstep, SEC-DED memories, configuration parity, a watchdog and a clock
monitor are in the design because safety-critical use is the target — and
it carries no compliance claim whatsoever. A reader who notices the
tension between a safety-oriented name and a disclaimer of any safety
claim is reading correctly; both statements are true because they
describe different things.

(c) 2026 ChipDesign B.V. — [Apache-2.0](LICENSE)

> [!WARNING]
> **Work in progress — but no longer unverified. Every result below was
> produced in this repository, on this variant's RTL; none of variant
> 1's signoff was inherited, and none needed to be.**
>
> The baseline came from a design that meets its O1–O7 gate, but
> **inheritance is not evidence**. The ISA is wider here and three core
> modules were replaced, so every result that depended on the
> instruction set or on those modules was produced again:
>
> | What variant 1 established | State here |
> |---|---|
> | `riscv-arch-test`, 85 of 85 | **re-run and extended** — 143 of 143 pass, including the B and C tests |
> | 10⁹-instruction co-simulation vs Spike | **re-run and met** — 1 015 480 871 instructions, zero mismatches, on the final RTL (`2ecf4b2`) |
> | formal decoder proof over all 2³² encodings | **superseded** — that proof was of variant 1's decoder; see the equivalence benches below |
> | coverage (O6/O7) | **re-run and met, 2026-09-02** — line 96.1 % measured / **100 % with 23 reviewed waivers**, toggle **96.3 %** (≥ 95 criterion met), functional **100 % of 92 points** covering C/Zcmp, PMP, CLINT, E2E and the debug path |
> | fault injection, FMEDA | **re-measured on this design** — eight campaigns on the final RTL; FMEDA **SPFM 99.50 %, LFM 92.66 %, residual 1.22 FIT** on *assumed* base rates ([doc/fmeda.md](doc/fmeda.md)) |
> | RTL2GDS: DRC, LVS, timing closure | **closed at chip level** (`chip1`): setup **+0.373 ns** at the slow corner, hold clean, route DRC/antenna/XOR 0, **LVS matches uniquely** (161 742 devices / 86 330 nets, pad ring included). Seal ring and density fill deferred on PDK bugs; two checks still open — [doc/chip.md](doc/chip.md) |
> | gate-level simulation (O8) | **not done** — awaits work on the `chip1` netlist |
>
> What keeps this a warning: O8 is open, the FMEDA's base failure rates
> are assumed rather than foundry data, and nothing here is qualified
> for safety-critical use — see the naming note above and
> [doc/safety_manual.md](doc/safety_manual.md).
>
> The run-it-yourself checks:
>
> | Check | Result | How |
> |---|---|---|
> | Lint, whole subsystem | clean, hard gate | `make lint` |
> | Base block benches | pass | `make block` |
> | New block benches | pass, **2 087 437 checks**, 13 benches, mutation-validated | `make block-20` |
> | Subsystem smoke simulation | pass | `make sim` |
> | Safety, peripherals, traps, register walk | pass | `make safety periph trap regwalk` |
>
> Two of the new benches are **equivalence checks against variant 1**,
> instantiating the frozen originals from [verif/ref/](verif/ref/)
> beside this repo's versions: the decoder must produce an identical
> control word on every encoding variant 1 accepts, and the CSR file
> must behave identically cycle by cycle outside the three registers
> that deliberately differ. That is what makes "the base ISA is
> untouched" a measured statement rather than an intention.
>
> Per-module status is in
> [doc/variant_status.md](doc/variant_status.md); what the benches and
> the campaigns actually found is in
> [doc/verification_findings_20.md](doc/verification_findings_20.md).


## What it is

A small, deterministic RISC-V control subsystem meant to sit in the
digital corner of a mixed-signal SoC — a sensor front-end, a motor or
power controller, a battery monitor — where a failure of the control
loop has to be *detected and signalled*, not tolerated.

The design goal is not performance. It is that every structure in the
subsystem is small enough to reason about, and that a fault in it is
either detected by a mechanism that reports it, or bounded by one.

* **Core** — `rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb_zcmp`.
  Machine mode only, two stages, one
  instruction in the execute stage at a time. No forwarding, no
  speculation, no caches: every instruction has a statically known
  worst-case latency. Straight-line code retires one instruction per
  cycle (measured CPI 1.20 on a dependent ALU loop, the residual being
  the taken-branch redirect).
* **Dual core lockstep (DCLS)** — a checker core runs the same program
  delayed by a configurable number of cycles, and every output is
  compared. The delay makes the pair diverse in time, so a disturbance
  that hits both cores in the same cycle hits them in different parts of
  the program.
* **SEC-DED protected memories** — 39-bit words (Hsiao code) in both
  tightly coupled memories, single bit errors corrected, double bit
  errors reported as a bus error and as a fault.
* **March C- memory BIST** — over the raw 39-bit words, so the check bit
  storage is tested too.
* **Register file parity**, checked on every register an instruction
  actually reads.
* **Windowed watchdog** with a two step key sequence: catches servicing
  too late *and* too early, and locks its own configuration.
* **Clock monitor** in an independent reference clock domain, so it can
  report the loss of the clock it is watching.
* **Safety controller** — one sticky status bit per fault source, a
  configurable reaction per source (interrupt, warm reset, external
  error pin), a lockable configuration, and fault injection so that the
  detection paths themselves can be proven in the field.
* **Mixed-signal interface** — ADC sequencer with per-channel result
  range checking and conversion time-out, trim/DAC output, analog test
  bus control, and analog supervisor flag inputs routed into the safety
  controller. The analog domain becomes a monitored safety element
  rather than an unobserved black box.
* **APB expansion slot** for the SoC's own mixed-signal registers.

## Repository layout

| Path | Contents |
|------|----------|
| [rtl/core/](rtl/core/) | core: fetch, decode, ALU, multiplier, divider, LSU, CSR, register file |
| [rtl/safety/](rtl/safety/) | lockstep, SEC-DED, safety controller, watchdog, clock monitor, memory BIST |
| [rtl/bus/](rtl/bus/) | interconnect, TCM, APB bridge |
| [rtl/periph/](rtl/periph/) | timer, interrupt controller, CLINT, AMS interface |
| [rtl/debug/](rtl/debug/) | JTAG TAP (IEEE 1149.1, no riscv-dbg dependency), its clock-domain bridge and the read-only observation window it reaches |
| [rtl/common/](rtl/common/) | clock domain crossing primitives |
| [rtl/cdriscv_32s_20_subsys.sv](rtl/cdriscv_32s_20_subsys.sv) | subsystem top level |
| [rtl/chip/](rtl/chip/) | full-chip top: the subsystem in the SG13G2 IO pad ring ([doc/chip.md](doc/chip.md)) |
| [verif/ref/](verif/ref/) | **frozen** variant-1 modules, reference only for the equivalence benches |
| [tb/](tb/) | smoke bench and smoke program |
| [scripts/](scripts/) | ECC generator, memory image builder |
| [flow/](flow/) | LibreLane 3 hardening flows: subsystem (`run_v2.sh`) and chip (`run_chip.sh`) |
| [doc/](doc/) | architecture, register map, safety manual draft, verification plan, integration guide |

## Physical implementation (RTL2GDS)

<img src="doc/img/cdriscv_chip_gds.png" width="50%"
     alt="cdriscv_32s_20_chip GDS, 2400 x 3500 um on IHP SG13G2">

*`cdriscv_32s_20_chip` (run `chip1`) — 2400 × 3500 µm on IHP SG13G2:
99-pad `sg13g2_io` ring (83 signal, 16 supply, 4 corners), six TCM SRAM
macros, no ADC on die. The gap inside the die edge is the 140 µm
allowance reserved for the deferred seal ring.*

Two levels, both on the complete RTL:

**Subsystem** (`flow/runs/v2full`, 1440 × 2521 µm at 40 ns): everything
physical clean — routing DRC 0, antenna 0, KLayout DRC 0, XOR 0, LVS
matching uniquely (153 626 devices, 79 499 nets), hold clean — but
setup missed by **−0.719 ns** at the slow corner, all 46 violating
paths in the fetch stage. The cause was measured, not guessed: chains
of minimum-strength `buf_1` fanout-repair buffers
([doc/verification_findings_20.md](doc/verification_findings_20.md)
§15). A probe with `buf_4` and larger resizer margins recovered
−0.719 → −0.059 ns.

**Chip** (`flow/runs/chip1`, 2026-09-03/04, with those knobs): **timing
closed** — setup **+0.373 ns** at slow 1.08 V/125 °C, TNS 0; hold
+0.14 ns; route DRC 0; XOR 0; antenna clean; **LVS matches uniquely
across 161 742 devices and 86 330 nets including the pad ring**. Seal
ring and density fill are **deferred on reproduced PDK bugs** (the
sealring PCell emits INT32_MIN coordinates for every size; the filler
OOMs >13 GB on this die) with the die reserving the ring allowance;
the chip-level KLayout DRC re-run and the classification of magic's
obstruction-overlap messages are still open. Evidence and status:
[doc/chip.md](doc/chip.md).

```sh
cd flow && ./run_v2.sh <run-tag>     # subsystem
cd flow && ./run_chip.sh <run-tag>   # chip
```

For variant 1's signed-off physical results, see
[cdriscv-32s-10](https://github.com/ChipDesign-BV/cdriscv-32s-10).

## Documentation

* [doc/architecture.md](doc/architecture.md) — how it is built and why
* [doc/programming_manual.md](doc/programming_manual.md) — firmware view: ISA, traps, peripherals, safety duties, idioms
* [doc/register_map.md](doc/register_map.md) — address map, CSRs, every peripheral register
* [doc/integration.md](doc/integration.md) — integration manual: deliverables, checklist, ports, clocking, reset, CDC, boot, safety hooks, DFT, physical implementation
* [doc/safety_manual.md](doc/safety_manual.md) — mechanisms, assumptions of use, remaining gaps
* [doc/verification_plan.md](doc/verification_plan.md) — the objectives and their results
* [doc/verification_findings_20.md](doc/verification_findings_20.md) — this variant's evidence log, §1–§19
* [doc/verification_findings.md](doc/verification_findings.md) — variant 1's evidence log, V0–V52
* [doc/fmeda.md](doc/fmeda.md) — FMEDA: measured populations and coverage, assumed rates, derived metrics
* [doc/chip.md](doc/chip.md) — the full-chip level: die, pinout, hardening result, deferred items
* [doc/variant_status.md](doc/variant_status.md) — the per-module, per-objective inventory

## Building

```sh
make lint     # verilator --lint-only
make sw       # build the smoke program and its ECC encoded memory image
make sim      # iverilog + vvp, boots the smoke program
make synth    # yosys generic synthesis, area statistics
make ecc      # regenerate rtl/safety/cdriscv_32s_20_ecc_secded.sv
```

Inside the IIC-OSIC-TOOLS container the tools need an explicit path:

```sh
export PATH="/foss/tools/bin:/foss/tools/verilator/bin:$PATH"
```

## Status

| Area | State | Evidence |
|------|-------|----------|
| Lint & structure | **clean** | `make lint lint-tb`, hard gate; waivers argued in [verif/lint/waivers.vlt](verif/lint/waivers.vlt) |
| Base block benches | **pass** | `make block` — ALU (453 840 vectors, against the *new* ALU), SEC-DED, the divider (divide vectors only since 2026-09-02 — the dead multiply half of `multdiv` was removed; `block-mult` owns the multiplies), clock monitor, TCM, IF-stage equivalence |
| New block benches | **pass, 2 087 437 checks**, 13 benches, mutation-validated | `make block-20` — see [doc/variant_status.md](doc/variant_status.md) for the per-module breakdown and the mutation results |
| Subsystem simulation | **pass** | `make sim`, plus `make safety periph trap regwalk` |
| Architectural suite | **143 of 143 pass**, incl. B and C | `make riscof` against Spike, on the RTL with Zcmp; 43 PMP tests dropped by selection, and the suite is a vintage release — see [verif/riscof/README.md](verif/riscof/README.md) |
| Co-simulation vs Spike | **O2 met, on the final RTL** | 1 015 480 871 instructions, 27 000 programs, zero mismatches, against frozen revision `2ecf4b2` (2026-09-02) — checked, not assumed |
| Formal | **not re-run** | variant 1's decoder proof was of variant 1's decoder |
| Coverage (O6/O7) | **met, 2026-09-02** | `make coverage` on the final RTL: line **96.1 % measured / 100 % with 23 reviewed waivers** ([verif/coverage_waivers.md](verif/coverage_waivers.md)); toggle **96.3 %** (≥ 95 criterion met); functional **100 %, 92 of 92 points** covering C/Zcmp, PMP, CLINT, E2E and the tck-domain debug blocks |
| Fault injection | **re-measured, eight campaigns** | `build/fi_campaign*.txt` on the final RTL; two findings fed back into the RTL and re-measured closed — fi-e2e 10 SDCs → **0**, fi-pmp 90.8 % latent → **448/448 detected in 2 cycles** ([doc/verification_findings_20.md](doc/verification_findings_20.md) §18) |
| FMEDA (O9) | **computed on this design** | **SPFM 99.50 %, LFM 92.66 %, residual 1.22 FIT** — past the ASIL D thresholds *on assumed base rates* ([doc/fmeda.md](doc/fmeda.md), 2026-09-02) |
| Gate-level simulation (O8) | **not done** | awaits work on the `chip1` netlist |
| Physical, subsystem (`v2full`) | **clean except setup** | routing DRC 0, antenna 0, KLayout DRC 0, XOR 0, LVS unique (153 626 devices / 79 499 nets); setup −0.719 ns slow — root-caused to buf_1 fanout chains and fixed at chip level |
| Physical, chip (`chip1`) | **timing closed, LVS clean** | setup **+0.373 ns** slow / TNS 0, hold +0.14 ns, route DRC 0, XOR 0, antenna 0; **LVS unique: 161 742 devices / 86 330 nets incl. the pad ring**. Open: chip DRC re-run (first pass judged a stale GDS), 956 obstruction-overlap messages to classify — [doc/chip.md](doc/chip.md) |
| Seal ring | **deferred — PDK bug, reproduced** | sealring PCell emits INT32_MIN coordinates at every size incl. the PDK's own example; die reserves the 140 µm allowance so the ring adds later without floorplan change ([doc/chip.md](doc/chip.md), findings §19) |
| Density fill | **deferred — tool OOM** | PDK filler >13 GB on the 8.4 mm² die, one fill area at a time; the subsystem flow never ran metal fill either ([doc/chip.md](doc/chip.md)) |

The honest summary: the O1–O7 and O9 objectives are met on this
variant's own runs, the chip level is hardened and timing-closed, and
what remains is O8 (gate level), the tapeout-preparation geometry
deferred on reproduced PDK bugs, and everything that separates measured
evidence from a safety case — assumed failure rates above all. The two
equivalence benches remain the strongest evidence here, because they
compare against an implementation that is already signed off rather
than against a model written alongside the DUT.

What each remaining item needs is enumerated in
[doc/variant_status.md](doc/variant_status.md); the defects the benches
and campaigns found — five of nine new modules had real ones, and two
findings were measured, fixed and re-measured closed — are written up
in [doc/verification_findings_20.md](doc/verification_findings_20.md).
