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
| `csr` | PMP registers; `mepc` halfword aligned; `misa` reports B **and C** | equivalence-checked against variant 1's CSR file |
| `core` | wider operator, PMP checker instantiated; **ST_SEQ Zcmp sequencer** (2026-08-31) | PMP resets to all-regions-off, so behaviour out of reset is identical to variant 1; a cm.* retires once, as Spike does |

New modules. The **in** column says whether the subsystem instantiates
it — a module that is written and block-verified but not wired up is not
part of this design's behaviour, and the distinction is the point of this
table:

| Module | Purpose | in |
|---|---|---|
| `mult` | single-cycle 33×33 multiplier — the ONLY multiply path since 2026-09-02, when `multdiv`'s dead iterative multiply half was deleted | yes |
| `pmp` | 8-region physical memory protection checker | yes, data accesses |
| `decompress` | Zca/Zcb 16 → 32 bit expander; flags (not expands) Zcmp | yes |
| `zcmp` | Zcmp micro-operation step table, walked by the core's `ST_SEQ` | yes |
| `if_align` | 16-bit fetch granularity and straddle handling | yes |
| `jtag_tap` | IEEE 1149.1 TAP, no riscv-dbg dependency | yes |
| `dbg_bridge` | tck ↔ system handshake for the TAP's debug bus | yes |
| `dbg_win` | read-only observation window the TAP reaches | yes |
| `clint` | standard timer / software interrupt controller | yes, on the main bus |
| `clint_obi` | req/gnt/rvalid adapter for the CLINT (rejects sub-word) | yes |
| `e2e` | end-to-end bus payload protection (generator/checker pair) | yes, via `e2e_link` |
| `e2e_link` | E2E master/slave endpoints for one protected bus link | yes, both TCM links |

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
| `jtag_tap` | `block-jtag` | 23 | 7/7 | IEEE 1149.1 mandatory sequences, now with the Pause-IR detour and an undecoded IR behaving as BYPASS (2026-09-01) |
| `dbg_bridge` + `dbg_win` | `block-dbg` | 35 | 9/10 | the same reads at three tck:clk ratios |
| `decompress` | `block-decompress` | 65 536 | 7/7 | **binutils**, over every 16-bit encoding — now including the Zcmp flag both ways |
| `zcmp` (+ core `ST_SEQ`) | `block-zcmp` | 312 seq / 1 744 steps | 9/9 | **Spike**, replaying the dumped micro-ops against a commit log built from binutils-assembled cm.* mnemonics (`scripts/check_zcmp.py`); the 9 mutants span the table AND the core sequencer (`scripts/mutate_zcmp.py`, killed by block-zcmp or the `zcmp` directed test) |
| `if_align` | `block-if-align` | 101 317 | 9/9 | byte-stream walker written from the ISA rule alone |
| `decoder` | `block-decoder-equiv` | 1 073 728 | 10/10 | **variant 1's decoder**, instantiated beside it |
| `csr` | `block-csr-equiv` | 400 018 | 10/10 | **variant 1's CSR file**, in lockstep |
| `e2e_link` | `block-e2e-link` | 12 024 | 10/10 | corruptible wires between the two endpoints, in front of a TCM-shaped slave; only fault classes the Hsiao fold detects with certainty, so every expectation is deterministic — since 2026-09-02 including byte-enable corruption (write beat and read request), and two be mutants: the fold-drop and the live-vs-held phase |

`make block-20` runs all thirteen: **2 051 674 checks**.

The one surviving mutant in `block-dbg` is named rather than rounded
away: moving the bridge's acknowledge a cycle earlier, so it is sent in
the same cycle the read data is captured. It survives because the
acknowledge still has to cross a two-stage synchroniser, which in
zero-delay RTL simulation always outlasts a same-cycle register write.
The extra stage is a **timing** margin — it matters when two tck edges
are shorter than one system clock period — and a functional bench is the
wrong instrument for it. A mutant that only static timing can kill is
worth reporting as such, not counted as a kill.

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

1. `misa` reports B and C as well as I and M. C was deliberately
   withheld until the fetch path could deliver a compressed
   instruction, and the bench guards the rule in whichever direction
   currently applies: it now fails if C is *absent*. That guard was
   left pointing the old way for several commits — see §12 of
   [verification_findings_20.md](verification_findings_20.md);
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

1. **O2 is met, on the current RTL.** 1 015 480 871 instructions over
   27 000 randomly generated programs in 54 batches, every batch
   500/500, zero mismatches on retire PC, instruction, register writes
   and memory writes, with memory grants held off on 30 % of cycles —
   re-run 2026-08-31 against revision `49079a3`, the revision that
   closed the implementation phase (JTAG, CLINT, E2E, PMP on data and
   fetch, Zcmp all in).

   The one-unchanging-design condition was checked against recorded
   facts, not memory: the log header names the revision, the runner was
   rebuilt from scratch at 16:13:32 UTC — 57 minutes after the last
   commit touching `rtl/` or `verif/core/` — batch 0 started 16:21,
   batch 53 finished 23:20, and the tree stayed clean throughout.

   **The total is identical to the previous campaign's, and that is
   determinism, not a stale log.** The campaign runs a fixed seed
   sequence (1000 + 500·k) through an unchanged generator, so the
   27 000 programs — and therefore their retired-instruction counts —
   are identical batch for batch (verified against the archived log,
   `build/o2_marathon_completed_20260830.log`); what differs is the RTL
   that executed them, which now includes the Zcmp sequencer and the
   multi-write retirement comparison in the runner. Anyone auditing
   this number should expect it to repeat exactly until the generator
   or seed plan changes.

   Two earlier campaigns are archived rather than deleted: the
   2026-08-30 run (same result, pre-implementation-phase RTL) and the
   first attempt, which reached 1 015 491 890 instructions but spanned
   the Zca/Zcb and multiplier changes and therefore closed nothing —
   §10 of [verification_findings_20.md](verification_findings_20.md).

   Caveat carried honestly: the program generator emits no cm.*
   instructions of its own, so the marathon exercises Zcmp only
   lightly; the 312-sequence block bench and the directed test carry
   that weight until the generator is extended.

   Comparable to variant 1's objective: 1 008 435 332 instructions over
   27 500 programs.

2. **The architectural suite runs and passes on the current RTL** —
   **143 of 143** selected tests against Spike (`make riscof`,
   2026-09-01, revision with Zcmp): the C-extension tests joined the
   selection and all pass.

   Getting there was itself a finding. The re-run first reported **8
   failures — all of them because the DUT is right**: the ISA yaml the
   test selection reads still said `RV32IM...` without C, so the suite
   selected the `misalign-*` tests, which are valid only at IALIGN=32,
   and skipped `rv32i_m/C` entirely. A halfword branch target is legal
   on this core, the expected trap never comes, and the test fails
   against the healthy half of the system. Declaring C deselected those
   8 and selected the C tests: 114 → 143. Same shape as the misa guard
   in §12 of [verification_findings_20.md](verification_findings_20.md):
   a selection input went stale and quietly shaped which tests ran.

   One layer deeper: the yaml's `misa` reset value now differs from the
   RTL's by exactly one bit (`misa.B`), because the installed
   riscv-config's ISA regex predates the ratified B letter and cannot
   accept it. The divergence is confined to the yaml and documented in
   place; nothing in the suite reads misa's reset value from the DUT.

   Remaining caveats: the suite is a vintage release; 43 PMP tests are
   still dropped by selection rather than by result and have not been
   revisited now that PMP gates both data and fetch; Zcb and Zcmp have
   no architectural tests upstream — their coverage is the directed
   tests and the 312-sequence block bench.
3. **Zca/Zcb are in the fetch path.** `if_align` sits between the
   word-level prefetcher and decode; `misa` now reports C. The core
   changed with it: a compressed jump links PC+2 rather than PC+4,
   IALIGN is 16 so a control transfer to a halfword address is legal,
   an illegal compressed encoding traps with `mtval` holding the 16-bit
   encoding rather than the expansion, and the retire trace reports the
   instruction as fetched. Co-simulation against Spike matches on
   programs that are ~30 % compressed.
4. **Zcmp is implemented — as the sequencer the previous entry said it
   needed.** (This entry used to say "Zcmp is not written and cannot go
   in the decompressor"; as with the CLINT, E2E and PMP-on-fetch
   entries, the prediction has been replaced by the result, 2026-08-31.)
   `cm.push`/`cm.pop`/`cm.popret`/`cm.popretz`/`cm.mva01s`/`cm.mvsa01`
   expand to a *variable-length sequence* of loads and stores plus a
   stack adjustment, so they could not live in the combinational
   decompressor.  The decompressor now *flags* the 312 legal encodings
   (`zcmp_o`, checked both ways against binutils in `block-decompress`),
   a stateless step table (`cdriscv_32s_20_zcmp`) says what each
   micro-operation does, and a fifth core FSM state `ST_SEQ` walks it
   over the existing one-at-a-time datapath — one LSU access per memory
   beat, the ALU for the moves and the final sp add.  The ISA string
   grew `_zcmp` everywhere (`ARCH`, `COSIM_ARCH`, cosim.py, the random
   regression); `misa` is untouched because Zcmp has no `misa` bit.

   The semantics that needed deciding, and where each is proven:

   * **One retirement per cm.*** (retire_valid once, pc += 2, the raw
     16-bit encoding), exactly as Spike retires it.  The cosim bench
     accumulates the sequence's register/memory writes and prints them
     on the one TRACE line the way Spike prints its commit line
     (registers sorted by index, memory beats in execution order), and
     cosim.py now tokenises the whole write list per retirement instead
     of matching one register + one memory field.  Proven by `make
     cosim` / `cosim-stall` (both simulators) and the minstret
     arithmetic in the directed test.
   * **Not interruptible mid-sequence** — interrupts are taken at
     instruction boundaries only, the simplest correct choice for a
     lockstep safety core.  The cost is bounded and recorded as a WCET
     fact (worst case `cm.push {ra, s0-s11}`: 13 memory beats + the sp
     write, ~28 cycles on zero-wait-state TCMs, plus bus wait states) in
     programming_manual.md §1.2.  Proven by sweeping a CLINT deadline
     across a `cm.pop` in 1-cycle steps: whenever the handler sees
     `mepc` = the cm PC, the first-loaded register must still hold its
     poison (`make zcmp` check 14) — the partially-executed state a
     mid-sequence interrupt would present.
   * **Mid-sequence exceptions restart cleanly**: each beat passes the
     same pre-issue checks as an ordinary access (misalign, then PMP —
     a denied beat never reaches the bus), the trap reports mepc = the
     cm PC and mtval = the beat address, and **sp is written last** so
     the faulted instruction's sources are intact.  The Zc spec permits
     the completed stores below the final sp (that region is volatile
     across the instruction).  Proven by a cm.push into a locked
     PMP-denied word (mcause 7, mtval, mepc, sp unchanged, the guarded
     word untouched) and a misaligned-sp push (mcause 6) in `make
     zcmp`; the sp-written-first mutant is killed by exactly the
     sp-unchanged check (exit code 18).
   * **Lockstep untouched**: the sequencer is a function of
     core-internal state and core inputs only, entirely inside
     `u_core`; the wrapper and comparator are unchanged.

   Verification: `block-zcmp` (312 sequences / 1 744 steps against a
   Spike commit log generated from binutils-assembled mnemonics — the
   repo's independent-reference pattern), `block-decompress` extended
   with the flag column, the 22-check directed test (`make zcmp`,
   including nested popret frames and both mv forms), cosim on both
   simulators with cm.* sections in cosim_isa.S, and 9/9 mutants killed
   (`scripts/mutate_zcmp.py`: wrong rlist count, sp written first,
   retire per beat, interrupt mid-sequence, popretz without the zero,
   swapped mv pair, wrong rounding, wrong pop base, denied beat
   reaching the bus).  Known gap: `gen_random_prog.py` does not emit
   cm.* (or any compressed) instructions itself — random Zcmp coverage
   is a generator extension left open.  The decoder equivalence bench
   needed no new expectation entries: cm.* never reach the 32-bit
   decoder (the decompressor hands it a nop and the core diverts to
   ST_SEQ), so the decoder is byte-identical to before Zcmp.
5. **PMP gates data accesses — and now instruction fetch.**
   A denied load or store raises `EXC_LOAD_FAULT` / `EXC_STORE_FAULT`
   *before* the request reaches the bus — the exception is raised in the
   same pre-issue block as a misaligned address, and `start_lsu` is gated
   on `!take_exc`, so nothing is issued and then retracted.

   Fetch is checked the same way now. (This entry used to say checking
   the fetch address "is a separate change"; as with the CLINT and E2E
   entries below, the prediction has been replaced by the result,
   2026-08-31.) A second instance of the verified checker,
   `u_pmp_fetch`, fed the same CSR arrays with `req_type = execute`,
   judges the word address the prefetcher offers on `instr_addr_o` —
   one check per fetched word, so an instruction straddling a word
   boundary is covered by the checks on both words, whose error bits
   `if_align` already ORs. A denied word never reaches the bus either:
   the fetch stage suppresses the request and injects a faulted buffer
   entry in its place, as if the bus had answered instantly with an
   error. From there the denial rides the existing fetch-error path, so
   it traps as `EXC_INSTR_FAULT` (cause 1, `mtval` = `mepc` = the
   denied instruction's PC — the same convention as a fetch bus error)
   only if and when the instruction is actually executed, and a denied
   *prefetch* beyond a taken branch dies silently in the ordinary
   redirect flush. The added logic sits on the request/write side of
   the fetch buffer, deliberately away from the `rd_ptr_*_q` read
   muxes that carry the timing-critical path (§3.8); the cost is the
   8-region compare now in series with `instr_req_o`.

   `make pmp` is the directed test, now 23 checks; mutation-validated
   3/3 on the data side and **5/5 on the fetch side**
   (`scripts/mutate_pmp_fetch.py`). It checks **both directions**,
   because a checker that denied everything would pass a one-sided
   test: an entry that is programmed but **unlocked** must not bind
   machine mode — for data *and* for execution — and only a **locked**
   entry may deny. The locked fetch region deliberately keeps R=1 so a
   checker testing the wrong permission bit is caught, and a locked
   no-permission region sits over a word the prefetcher runs into but
   execution jumps over, proving the discard. That last check was born
   inert: a surviving mutant showed the prefetcher had fetched the word
   *before* the `csrw` locking its region retired, so no fetch was ever
   denied — the check now carries a `fence.i` to force a refetch under
   the new rules. A checker's kill list is also a test of the test.

   One consequence worth knowing: a PMP denial reports through the
   safety controller's **bus-error** event, because it raises the same
   `EXC_*_FAULT` causes — and a denied fetch (cause 1) is on that list
   too. A software access violation therefore sets the same sticky
   status bit as a real memory fault. Distinguishing them would need a
   separate event source.

   **The arrays themselves carry configuration parity since
   2026-09-02.** fi-pmp measured the reason (§18 of
   verification_findings_20.md): 90.8 % of PMP-array SEUs — 407 of
   448 — were silently latent, protection rewritten under a passing
   workload with nothing to say so. A second `cfg_parity` instance in
   the CSR file (`u_pmp_par`, 320 bits over `pmpcfg0/1` storage +
   `pmpaddr0..7`) now folds the STORED arrays — after the WARL
   masking, which is what makes the capture structurally unable to
   disagree with the registers it guards — and reports on the same
   `fault_cfg_par_o` the mtvec guard uses, so both lockstep cores get
   it by construction and no subsystem port moved. Attribution is the
   core's existing CFG_SRC bit 6 (one export per core; mtvec and PMP
   share the group). tb_safety adds three directed checks: a pmpcfg
   shadow flip, a pmpaddr flip, and a flip of the guard's own parity
   bit — measured self-detecting through the same path.
6. **The CLINT is instantiated; so, now, is E2E.**

   The CLINT owns MTIP and MSIP now. It sits on the **main bus** at
   `0x0200_0000` in a 64 KB window — the standard map puts `mtime` at
   `+0xBFF8`, which a 256-byte APB slot's 12-bit address cannot reach,
   and remapping the offsets would make it a non-standard CLINT, which
   defeats the point of having one. A small adapter (`clint_obi`) joins
   its combinational slave interface to the bus protocol and **rejects
   sub-word accesses** rather than widening them: a byte write into a
   64-bit counter has no defined meaning, and performing it as a word
   write would corrupt the other three bytes.

   The APB timer at slot 2 keeps its registers and its config parity;
   only its interrupt moved — it is now **source 16** of the interrupt
   controller, appended so that sources 0–15 keep the meaning software
   already had. The CLINT's config-parity error appends the same way, at
   bit 7 of the safety controller's `CFGSRC`. The irq_ctrl's own MSIP
   register still exists but no longer reaches the core.

   `periph_test` was rewritten to the new architecture and now proves
   both routes: MTIP from the CLINT (including the hi-then-lo comparator
   write order that keeps the 64-bit compare value from passing through
   a smaller intermediate state while `mtime` runs), the WFI wake, MSIP
   from the CLINT's `msip`, **and** the APB timer arriving as the
   external interrupt through source 16. Full regression green after the
   change (12 targets).

   **E2E is now instantiated too**, on the two TCM links. (This entry
   used to say E2E "remains the open one" because it inserts a generator
   and a checker into the bus datapath; as with the CLINT above, the
   prediction has been replaced by the result.) The insertion turned out
   not to touch the bus datapath at all: the generator/checker pair is
   wrapped into per-link endpoints (`e2e_link` — master side generates
   the write-path check bits and checks read responses, slave side
   checks delivered writes and generates read-path check bits over the
   held address of the outstanding access), instantiated beside the
   masters and the TCMs in the subsystem. The bus's own muxing is
   untouched; its one change is exporting the existing I-TCM owner bit
   so responses can be attributed. A mismatch latches as `STATUS`
   bit 14 (`FLT_E2E`, the former spare — nothing moved); the access
   still completes, because gating it would change bus timing.

   Scope and the two honest caveats:

   * Only the TCM links are protected. The peripheral bridge and the
     CLINT answer for themselves through `err_o`, so those links are
     out of this pass's scope.
   * **Sub-word writes are covered**, because the write-path check is
     made on the delivered request wires *before* the TCM's internal
     read-modify-write — nothing compares against what the TCM stores,
     so the RMW merge cannot false-flag. **The byte-enable wires are
     covered too, since 2026-09-02.** This entry used to name them as
     the one thing the fixed `{data, addr}` fold could not cover, and
     fi-e2e then measured that residual as the campaign's ENTIRE SDC
     budget — all 10 SDCs were `be` flips (§18 of
     verification_findings_20.md). The fold is now `{data, addr, be}`,
     the four `be` bits run through the same Hsiao encoder so each
     gets a distinct odd-weight column (the no-two-bits-cancel
     property the address fold was rebuilt for — the naive slice-XOR
     mistake was not repeated), both endpoints hold the `be` of the
     outstanding access for the read path, and the instruction master
     folds the constant `4'b1111` the bus drives for a fetch.

   `block-e2e-link` (11 286 checks, mutants 8/8 — including the one
   that matters: address dropped from the fold at *both* ends, which
   clean traffic and data faults cannot see and only wrong-address
   delivery kills) proves the endpoints; the full regression and
   co-simulation against Spike prove the integration adds no
   functional change and no spurious flags.

   **The JTAG TAP is now instantiated**, with six pins on the subsystem
   (`tck_i`, `tms_i`, `tdi_i`, `trst_ni`, `tdo_o`, `tdo_oe_o`). What it
   reaches is deliberately narrow, and the boundary is worth stating
   plainly:

   * `dbg_bridge` crosses the tck domain to the system domain with a
     closed-loop toggle handshake in both directions. It needs no
     assumption about the tck:clk ratio, and the bench proves that by
     running the identical reads with tck slower than, equal to, and
     faster than the system clock.
   * `dbg_win` is **six read-only words**: IDCODE, a status word, the
     two fault vectors, and the PC and encoding of the last retired
     instruction. Writes are accepted by the bus and discarded.
   * It **cannot** halt the core, single-step, or read memory. Doing any
     of that makes the TAP a second master on `cdriscv_32s_20_bus`,
     needing arbitration against the core, and turns the debug port into
     a fault-injection path that the FMEDA would have to account for and
     the product would have to disable in the field. That argument is
     not made, so the window is read-only by construction rather than by
     configuration.
7. **The single-cycle multiplier is in the core, and it is not the
   timing problem.** The two paths are split on `md_op[2]`, which
   separates the four multiplies from the four divides — one reason the
   operator encoding is kept identical to funct3. A multiply no longer
   visits `ST_WAIT_MD` at all; only a divide stalls the pipeline.
   Measured: the smoke program fell from 348 to 315 cycles and the trap
   test from 596 to 563, both exactly 33 cycles, which is the sequential
   unit's own constant latency, and both contain one multiply.

   This entry used to say the combinational 33×33 multiplier on the
   writeback path was the thing to watch, and that if 25 MHz failed to
   close it should be the first candidate for removal. **The hardening
   run says otherwise**: all 46 setup-violating paths start in the fetch
   stage and the multiplier is on none of them (item 8). Removing it
   would cost performance and recover nothing.

   What WAS removed (2026-09-02) is the other half of the split:
   `multdiv`'s inherited iterative multiply datapath, which this
   integration could never select (`start_md` fires only for divides)
   and which the coverage re-run exposed as verified-but-dead logic —
   waiver W5, finding §17 of verification_findings_20.md. `multdiv` is
   now a pure 32-cycle restoring divider (same name, same ports, same
   divide behaviour byte for byte); the dispatch invariant is stated
   structurally in the core and checked at the divider's `req_i` in
   simulation, `block-multdiv` runs divide vectors only (the multiply
   vectors belong to `block-mult`, with the logic they exercised), and
   W5 is closed because the waived line no longer exists.
8. **The re-harden with the complete RTL is done. Everything physical
   passes; setup timing at the slow corner does not.**

   `v2full` — Zca/Zcb in the fetch path, the single-cycle multiplier, the
   JTAG TAP with its bridge and window, and all three clocks constrained
   for the first time. Same die as `v2first`: 1440 × 2521 µm (3.630 mm²)
   at 40 ns. 11 h 30 m end to end (routing 2:51, netgen LVS 6:51).

   | Gate | Result |
   |---|---|
   | Detailed routing | **0 DRC violations** |
   | Antenna, post-route | **0 violations** |
   | KLayout signoff DRC | **0 errors** |
   | Magic illegal overlap | clear |
   | GDS XOR | **0 differences** |
   | **LVS** (netgen) | **circuits match uniquely** — 153 626 devices, 79 499 nets, zero unmatched |
   | Hold, fast 1.32 V/−40 °C | **+0.145 ns**, TNS 0, 0 violations |
   | Hold, slow | +0.705 ns, 0 violations |
   | Setup, typ 1.20 V/25 °C | +11.875 ns |
   | Setup, fast 1.32 V/−40 °C | +18.898 ns |
   | **Setup, slow 1.08 V/125 °C** | **−0.719 ns**, TNS −8.713 ns, **46 violating endpoints** |

   231 920 instances — 153 622 standard cells of which **74 357 are
   antenna diodes**, plus 78 292 fill and the 6 SRAM macros. Utilisation
   0.803 overall, 0.685 standard cell (`v2first`: 0.709 / 0.533). The die
   held: global placement came in at 47.7 % against a 55 % target.

   **The multiplier is not the cause, and the fetch stage always was.**
   All 46 violating paths start in `u_core_main.u_if`; none touches the
   multiplier. `v2first`'s critical path started at the *same net* —
   `u_if.rd_ptr_rdata_q`, the instruction buffer's read pointer — and
   closed with +1.393 ns. Zca/Zcb's realignment deepened a path that was
   already the limiting one:

   | | `v2first` | `v2full` |
   |---|---|---|
   | worst-path start | `u_if.rd_ptr_rdata_q` | `u_if.rd_ptr_rdata_q` |
   | cells on the path | 70 | 82 |
   | of which max-fanout repair buffers | 22 | **32** |
   | setup slack, slow | +1.393 ns | **−0.719 ns** |

   **32 of those 82 cells are `sg13g2_buf_1`** — the weakest buffer in
   the library — inserted by max-fanout repair, several contributing
   0.45–0.59 ns each at 0.37–0.66 ns slew. `SYNTH_BUFFER_CELL` is
   `sg13g2_buf_1` and `MAX_FANOUT_CONSTRAINT` is 10, so a high-fanout net
   in the fetch stage gets a chain of minimum-strength buffers that the
   resizer then does not fully undo. That is a *buffering* observation,
   not a proof: whether restyling it recovers 719 ps is an experiment.
   It is the cheapest one to run, because it is a configuration change
   with no RTL risk.

   Ordered candidates, cheapest first:

   1. a stronger `SYNTH_BUFFER_CELL`, and/or a larger setup slack margin
      for the resizer (`GRT_RESIZER_SETUP_SLACK_MARGIN` is 0.025);
   2. restructure the fetch path in RTL — it was the critical path in
      both runs, so this is the durable fix;
   3. drop the clock to 20 MHz (50 ns), which closes by inspection and
      costs a fifth of the throughput.

   Removing the multiplier is **not** on that list: it is on none of the
   violating paths.

   Max-slew violations at the slow corner: 762 (`v2first`: 1098). The
   flow does not gate on these.

   **The clock constraints landed.** Every flip-flop in the design is now
   on a clock tree — `clk_i` 6457, `ref_clk_i` 107, `tck_i` 190, and
   **none** on a raw or fanout-repair net. In `v2first` those 107
   `ref_clk_i` flops had no tree and no timing check at all (§13 of
   [verification_findings_20.md](verification_findings_20.md)).

   `v2first` is kept: it is the reference the timing comparison above is
   against. It predates Zca/Zcb, the multiplier and the TAP, and its
   `ref_clk_i` domain was unconstrained, so it is a comparison point and
   not a fallback.

9. **Coverage (O6/O7) is done for this RTL; fault injection and the
   FMEDA have not been re-run.** `make coverage` (2026-09-01, on the
   complete RTL): RTL line **95.8 %** measured (568 of 593), **100 %
   with the 25 reviewed waivers** in
   [verif/coverage_waivers.md](../verif/coverage_waivers.md) (W2: 20
   defensive default arms, re-reviewed and renumbered; W4: the
   fetch-misalign trap C makes unreachable; W5: `multdiv`'s dead
   multiply arm — a finding, §17 of verification_findings_20.md).
   Toggle **94.4 %**, functional **100 % (91 of 91 points)** — and the
   model now describes *this* design: 26 points added for compressed
   execution (16-bit retire, word-boundary straddle, every Zcmp op
   class, max-rlist, irq-deferred-at-a-cm-boundary), PMP (data and
   fetch denial trapping, the M-mode-through-unlocked rule direction,
   locked-region deny, a denial mid-Zcmp-sequence), CLINT (MTIP rise,
   MSIP, the sub-word reject as a bus error), the straddle machinery,
   and the three fault sources the safety model postdated (cfg parity,
   E2E via INJECT — the checker's own detection is waiver W3, covered
   by block-e2e-link's mutation run — and the FLT_E2E latch).

   What changed to make the numbers honest rather than merely better:
   `pmp_test` and `zcmp_test` joined the coverage run list (with their
   verdicts grepped, since the bench exits 0 on FAIL — §17); the
   tck-domain benches `tb_jtag` and `tb_dbg` got Verilator coverage
   builds merged into the same database, taking `jtag_tap`,
   `dbg_bridge` and `dbg_win` from 0 % to 97.5/100/100 %; `pmp_test`
   grew NAPOT/TOR/pmpcfg1 checks (24-31), `trap_test` the four
   reserved Zbb/Zcb encodings (27/28/29/31), `periph_test` the sub-word
   CLINT reject (10/11), `safety_test` the FLT_E2E injection (10/11),
   `cosim_isa` the c.xor/c.zext.b/c.not forms (re-proven against
   Spike), and `tb_jtag` the Pause-IR path and undecoded-IR-as-BYPASS.

   **Open:** toggle sits at 94.4 % against the plan's inherited ≥ 95 %
   criterion — 0.6 points short, unwaived and uninvestigated, so O6 is
   met on its line-coverage half and open on toggle; the pre-existing
   coverage runs still trust the bench's exit code (only pmp/zcmp grep
   the verdict); `gate-fsm-core` predates the 3-bit ST_SEQ state
   machine (to-do attached to W2a); fault injection and the FMEDA
   remain variant-1 results.

   *(Updated 2026-09-02 — most of that Open list has since closed:
   every coverage run now captures its log and greps the verdict (the
   cosim runs, which have no PASS verdict, are guarded against their
   failure words instead); fault injection is re-measured on the final
   RTL — all eight campaigns, `build/fi_campaign*.txt`, including
   fi-e2e at zero SDC after the byte-enable fold and fi-pmp at 448/448
   detected in 2 cycles after the PMP parity extension (§18 of
   verification_findings_20.md carries the before/after tables); the
   coverage and toggle numbers from the 2026-09-02 re-run are in the
   paragraph below. Still open: `gate-fsm-core` vs the 3-bit ST_SEQ
   machine, and the FMEDA regeneration, which waits for the O2
   marathon by design.)*

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
