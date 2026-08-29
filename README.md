# cdriscv-32s-20

**A 32-bit RISC-V core subsystem for safety-critical mixed-signal SoCs,
with higher performance.**

This is **variant 2** of [cdriscv-32s](https://github.com/ChipDesign-BV/cdriscv-32s).
It starts from that design and adds a wider ISA (bit manipulation and
compressed instructions), physical memory protection, end-to-end bus
protection, a standard CLINT and a JTAG TAP. Variant 1 remains the
signed-off configuration and is not modified by anything here.

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
> **Work in progress. No verification gate is met in this repository,
> and none of variant 1's signoff carries over.**
>
> The baseline is inherited from a design that meets its O1–O7 gate, but
> **inheritance is not evidence**. The ISA is wider here and three core
> modules were replaced, so every result that depended on the
> instruction set or on those modules has to be produced again:
>
> | What variant 1 established | State here |
> |---|---|
> | `riscv-arch-test`, 85 of 85 | **re-run and extended** — 114 of 114 now pass, including 29 B tests |
> | 10⁹-instruction co-simulation vs Spike | **in progress** — harness retargeted, generator emits bitmanip |
> | formal decoder proof over all 2³² encodings | **superseded** — that proof was of variant 1's decoder; see the equivalence bench below |
> | coverage, fault injection, FMEDA | **not re-run** — all measured on variant 1's netlist |
> | RTL2GDS: DRC, LVS, timing closure | **not run** — no physical implementation of this variant exists |
>
> What *has* been established in this repository, from runs in it:
>
> | Check | Result | How |
> |---|---|---|
> | Lint, whole subsystem | clean, hard gate | `make lint` |
> | Base block benches | pass | `make block` |
> | New block benches | pass, **2 040 038 checks** | `make block-20` |
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
> Per-module status, including what each new block still needs, is in
> [doc/variant_status.md](doc/variant_status.md); what the benches
> actually found is in
> [doc/verification_findings_20.md](doc/verification_findings_20.md).


## What it is

A small, deterministic RISC-V control subsystem meant to sit in the
digital corner of a mixed-signal SoC — a sensor front-end, a motor or
power controller, a battery monitor — where a failure of the control
loop has to be *detected and signalled*, not tolerated.

The design goal is not performance. It is that every structure in the
subsystem is small enough to reason about, and that a fault in it is
either detected by a mechanism that reports it, or bounded by one.

* **Core** — `rv32im_zba_zbb_zbs_zicsr_zifencei` today, with
  `_zca_zcb` written and block-verified but not yet in the fetch path.
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
| [rtl/core/](rtl/core/) | core: fetch, decode, ALU, multiply/divide, LSU, CSR, register file |
| [rtl/safety/](rtl/safety/) | lockstep, SEC-DED, safety controller, watchdog, clock monitor, memory BIST |
| [rtl/bus/](rtl/bus/) | interconnect, TCM, APB bridge |
| [rtl/periph/](rtl/periph/) | timer, interrupt controller, CLINT, AMS interface |
| [rtl/debug/](rtl/debug/) | JTAG TAP (IEEE 1149.1, no riscv-dbg dependency) |
| [rtl/common/](rtl/common/) | clock domain crossing primitives |
| [rtl/cdriscv_32s_20_subsys.sv](rtl/cdriscv_32s_20_subsys.sv) | subsystem top level |
| [verif/ref/](verif/ref/) | **frozen** variant-1 modules, reference only for the equivalence benches |
| [tb/](tb/) | smoke bench and smoke program |
| [scripts/](scripts/) | ECC generator, memory image builder |
| [flow/](flow/) | LibreLane 3 hardening flow: config and wrapper |
| [doc/](doc/) | architecture, register map, safety manual draft, verification plan, integration guide |

## Physical implementation (RTL2GDS)

**Not run for this variant.** `flow/` is inherited from cdriscv-32s and
the configuration is carried over unchanged, but no die exists for
cdriscv-32s-20 and none of variant 1's physical results describe it.

That matters more than it looks: this variant's core carries a wider ALU
operator, the bit-manipulation datapath and an instantiated PMP checker,
so its area, congestion and critical path are all different from the
numbers variant 1 measured. Variant 1 closed 25 MHz on a 1.90 mm square
die and 50 MHz on a 2.10 mm square die; **neither figure is a prediction
for this design.**

```sh
cd flow && librelane --manual-pdk --pdk-root $PDK_ROOT config.json
```

For variant 1's measured physical results, see
[cdriscv-32s](https://github.com/ChipDesign-BV/cdriscv-32s).

## Documentation

* [doc/architecture.md](doc/architecture.md) — how it is built and why
* [doc/programming_manual.md](doc/programming_manual.md) — firmware view: ISA, traps, peripherals, safety duties, idioms
* [doc/register_map.md](doc/register_map.md) — address map, CSRs, every peripheral register
* [doc/integration.md](doc/integration.md) — integration manual: deliverables, checklist, ports, clocking, reset, CDC, boot, safety hooks, DFT, physical implementation
* [doc/safety_manual.md](doc/safety_manual.md) — mechanisms, assumptions of use, remaining gaps
* [doc/verification_plan.md](doc/verification_plan.md) — the objectives and their results
* [doc/verification_findings.md](doc/verification_findings.md) — the evidence log, V0–V44
* [doc/fmeda.md](doc/fmeda.md) — FMEDA: measured populations and coverage, assumed rates, derived metrics

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
| Base block benches | **pass** | `make block` — ALU (453 840 vectors, against the *new* ALU), SEC-DED, mul/div, clock monitor, TCM, IF-stage equivalence |
| New block benches | **pass, 2 040 038 checks** | `make block-20` — see [doc/variant_status.md](doc/variant_status.md) for the per-module breakdown and the mutation results |
| Subsystem simulation | **pass** | `make sim`, plus `make safety periph trap regwalk` |
| Architectural suite | **114 of 114 pass**, 29 of them B | `make riscof` against Spike; 43 PMP tests dropped by selection, and the suite is a vintage release — see [verif/riscof/README.md](verif/riscof/README.md) |
| Co-simulation vs Spike | **running** | retargeted and extended to emit Zba/Zbb/Zbs; the 10⁹ marathon is in progress, so O2 is not yet met |
| Formal | **not re-run** | variant 1's decoder proof was of variant 1's decoder |
| Coverage, fault injection, FMEDA | **not re-run** | all measured on variant 1's netlist |
| Gate level, timing, RTL2GDS | **not run** | no physical implementation of this variant exists |

The honest summary is that this repository holds a design whose *blocks*
are well verified and whose *integration* is verified only to the depth
of a smoke test. The two equivalence benches are the strongest evidence
here, because they compare against an implementation that is already
signed off rather than against a model written alongside the DUT.

What each remaining item needs is enumerated in
[doc/variant_status.md](doc/variant_status.md), and the defects the new
benches found — five of nine modules had real ones — are written up in
[doc/verification_findings_20.md](doc/verification_findings_20.md).
