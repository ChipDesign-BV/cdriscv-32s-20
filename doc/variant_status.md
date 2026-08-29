# cdriscv-32s-20 — what is done, what is not

This variant starts from [cdriscv-32s-10](https://github.com/ChipDesign-BV/cdriscv-32s-10),
which meets its own O1–O7 gate. **None of that gate carries over.** The
instruction set is wider here and three core modules were replaced, so
every result that depended on the ISA or on those modules has to be
produced again in this repository.

This file is the honest inventory. It is meant to be read before anyone
relies on anything here.

---

## 1. What changed from variant 1

| Module | Change | Consequence |
|---|---|---|
| `pkg` | `alu_op_e` widened 4 → 6 bits, 27 bitmanip operators added; PMP and E2E types; PMP CSR addresses | base operator encodings are **unchanged**, which is what lets the decoder be compared field for field against the frozen reference |
| `alu` | Zba + Zbb + Zbs, 27 new operations | base ALU bench passes unchanged against it (453 840 vectors) |
| `decoder` | Zba + Zbb + Zbs decode | equivalence-checked against variant 1's decoder |
| `csr` | PMP registers; `mepc` halfword aligned; `misa` reports B (**not** C — the fetch path cannot yet deliver compressed instructions) | equivalence-checked against variant 1's CSR file |
| `core` | wider operator, PMP checker instantiated | PMP resets to all-regions-off, so behaviour out of reset is identical to variant 1 |

New modules, none of them yet in the subsystem's datapath:

| Module | Purpose |
|---|---|
| `mult` | single-cycle 33×33 multiplier (the multi-cycle `multdiv` still serves the core) |
| `pmp` | 8-region physical memory protection checker |
| `decompress` | Zca/Zcb 16 → 32 bit expander |
| `if_align` | 16-bit fetch granularity and straddle handling |
| `clint` | standard timer / software interrupt controller |
| `e2e` | end-to-end bus payload protection |
| `jtag_tap` | IEEE 1149.1 TAP, no riscv-dbg dependency |

---

## 2. Per-module verification

Every bench below is **mutation tested**: a deliberate defect is injected
and the bench must fail. A bench that has not been shown to fail is not
evidence, and two of these found holes in themselves before they found
anything in the RTL.

| Module | Bench | Checks | Mutants killed | What the reference is |
|---|---|---|---|---|
| `alu` | `block-alu-bitmanip` | 135 111 | 6/6 | independent model (loop where the DUT uses a tree) |
| `mult` | `block-mult` | 80 900 | 4/4 | explicit widening where the DUT slices one product |
| `pmp` | `block-pmp` | 52 419 | 9/9 | independent address-match model |
| `e2e` | `block-e2e` | 119 071 | defect found | fault-injection escape statistics, split by fault class |
| `clint` | `block-clint` | 11 918 | 7/7 | independent register model |
| `jtag_tap` | `block-jtag` | 21 | 7/7 | IEEE 1149.1 mandatory sequences |
| `decompress` | `block-decompress` | 65 536 | 7/7 | **binutils**, over every 16-bit encoding |
| `if_align` | `block-if-align` | 101 317 | 9/9 | byte-stream walker written from the ISA rule alone |
| `decoder` | `block-decoder-equiv` | 1 073 728 | 10/10 | **variant 1's decoder**, instantiated beside it |
| `csr` | `block-csr-equiv` | 400 018 | 10/10 | **variant 1's CSR file**, in lockstep |

`make block-20` runs all ten: **2 040 039 checks**.

### The two equivalence benches

These are the strongest evidence in the repository, because they compare
against an implementation that is already signed off rather than against
a model written alongside the DUT.

**Decoder.** Where variant 1 says legal, this decoder must produce an
identical control word — all 24 fields, not just the ALU operator. Where
variant 1 says illegal, this one may accept only a Zba/Zbb/Zbs encoding,
and only with the operator an independently written table expects. Five
of the ten mutants were deliberate perturbations of the *base* ISA
(S-immediate LSB, load sign-extension, BGE→BGEU, the CSR immediate form,
SUB→ADD); all five were caught, which is the property that matters.

**CSR.** Both files are driven from identical stimulus cycle by cycle and
every output compared, so a divergence in a register that is only read
much later still shows up. Phase A *constrains* the stimulus — no PMP
addresses, word-aligned trap PCs, `mepc` writes with bit 1 clear — so it
stays a strict equality check rather than a whitelist. The three
deliberate differences are tested separately in phase B:

1. `misa` reports B as well as I and M — and deliberately **not** C,
   because Zca/Zcb are not in the fetch path yet;
2. `mepc` keeps bit 1, because IALIGN is 16 once Zca exists — variant 1's
   waiver `V0-A5` named `mepc[1:0]` as "the exact bit that changes if Zca
   is added", and this is that change;
3. the PMP registers exist, with their WARL and locking rules — including
   the one that is easy to miss: **locking a TOR region must also lock
   `pmpaddr[i-1]`**, because that address is the region's lower bound.
   Two mutants targeted exactly that.

### Both simulators

Every bench runs under Icarus and Verilator. This is not redundancy: the
realignment bench had a reset race that **Icarus passed and Verilator
failed**, and the CLINT had an unconnected pin that Verilator reported as
`PINMISSING` while Icarus accepted it silently. A single simulator would
have signed off both.

---

## 3. What is NOT done

Largest first.

1. **Co-simulation against Spike is running, not finished.** The harness
   is retargeted to `rv32im_zba_zbb_zbs_zicsr_zifencei` and the random
   program generator now emits Zba/Zbb/Zbs, so the comparison covers the
   new instructions. Results so far: the directed ISA program matches
   (208 instructions), and 25 random programs match over 191 778
   instructions, with and without 35 % memory back-pressure. The 10⁹
   marathon (`scripts/o2_marathon.sh`) is grinding; **variant 1's O2
   objective is not met here until it completes.**
2. **The architectural suite runs and passes** — 114 of 114 selected
   tests, including all 29 `rv32i_m/B` tests, against Spike
   (`make riscof`). Two caveats keep this short of variant 1's O1 claim:
   the suite is a vintage release, and 43 PMP tests are dropped by
   selection rather than by result — the vintage suite selects them on
   any RV32 I+Zicsr core, and although this variant now has PMP *CSRs*,
   its checker is not in the access path, so they would not be
   meaningful yet. Zcb still has no architectural tests upstream at all
   and will need directed tests.
3. **Zca/Zcb are in the fetch path.** `if_align` sits between the
   word-level prefetcher and decode; `misa` now reports C. The core
   changed with it: a compressed jump links PC+2 rather than PC+4,
   IALIGN is 16 so a control transfer to a halfword address is legal,
   an illegal compressed encoding traps with `mtval` holding the 16-bit
   encoding rather than the expansion, and the retire trace reports the
   instruction as fetched. Co-simulation against Spike matches on
   programs that are ~30 % compressed.
4. **Zcmp is not written and cannot go in the decompressor.**
   `cm.push`/`cm.pop`/`cm.popret` expand to a *variable-length sequence*
   of loads and stores plus a stack adjustment, not to one 32-bit
   instruction. They need a sequencer in the core.
5. **PMP gates data accesses; instruction fetch is not checked yet.**
   A denied load or store raises `EXC_LOAD_FAULT` / `EXC_STORE_FAULT`
   *before* the request reaches the bus — the exception is raised in the
   same pre-issue block as a misaligned address, and `start_lsu` is gated
   on `!take_exc`, so nothing is issued and then retracted. Checking the
   fetch address needs the check on the fetch side and is a separate
   change.

   `make pmp` is the directed test, mutation-validated 3/3. It checks
   **both directions**, because a checker that denied everything would
   pass a one-sided test: an entry that is programmed but **unlocked**
   must not bind machine mode, and only a **locked** entry with no
   permission may deny. That asymmetry is the part of the privileged
   spec that catches people out.

   One consequence worth knowing: a PMP denial reports through the
   safety controller's **bus-error** event, because it raises the same
   `EXC_*_FAULT` causes. A software access violation therefore sets the
   same sticky status bit as a real memory fault. Distinguishing them
   would need a separate event source.
6. **CLINT, E2E and the JTAG TAP are not instantiated** by the subsystem.
   The existing `timer` and `irq_ctrl` still serve it.
7. **The single-cycle multiplier is in the core.** The two paths are
   split on `md_op[2]`, which separates the four multiplies from the four
   divides — one reason the operator encoding is kept identical to
   funct3. A multiply no longer visits `ST_WAIT_MD` at all; only a divide
   stalls the pipeline. Measured: the smoke program fell from 348 to 315
   cycles and the trap test from 596 to 563, both exactly 33 cycles,
   which is the sequential unit's own constant latency, and both contain
   one multiply. The cost is a combinational 33×33 multiplier on the
   writeback path; whether the 40 ns period absorbs it is a question for
   the next hardening run, not for simulation.
8. **No physical implementation exists.** Nothing has been through
   synthesis-to-GDS for this variant, so there is no area, timing, DRC or
   LVS result. Variant 1's numbers are not a prediction: this core has a
   wider ALU operator, the bitmanip datapath and an extra checker.
9. **Coverage, fault injection and the FMEDA have not been re-run.**

---

## 3a. What the benches found

Five of the nine new modules had real RTL defects, and two more had
defects in the bench rather than the design. The write-ups — the HINT
class of decompressor bugs, the binutils reference traps, the three bench
races and the two lint findings fixed rather than waived — are in
[verification_findings_20.md](verification_findings_20.md).

---

## 4. Reading the inherited documentation

`doc/` is carried over from variant 1 and describes variant 1. Where a
document states a measured result — the FMEDA numbers, the coverage
figures, the RTL2GDS tables, the verification findings — that result was
produced on variant 1 and has not been reproduced here. The architecture
and register-map documents are structurally accurate for the shared
baseline but do not yet describe the new blocks.

They are kept rather than deleted because the baseline they describe is
genuinely this design's baseline, and deleting them would lose the
reasoning. They will be revised as each item in section 3 closes.
