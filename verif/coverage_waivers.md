# Coverage waivers

Objective O6 asks for 100 % line coverage **with a reviewed waiver for
each exclusion**. This file is that review. A waiver here is a claim
that a line cannot be reached by simulation *and* that something else
covers it — not a note that nobody got round to it.

Anything not listed here is a gap to be closed by a test, and the
current list of those is in `doc/verification_findings_20.md`.

## W2 — defensive `default` arms over constrained selectors (2026-08-21, re-reviewed 2026-09-01, reconciled 2026-09-02)

**Re-reviewed against the variant-2 RTL on 2026-09-01**, after the O6/O7
re-run: every line number below was re-derived from the fresh annotated
database (the Zcmp sequencer and PMP moved most of them), six new
lines entered the class (three decompressor quadrant-01 defaults, the
two PMP checker defaults, the JTAG TAP state default), and — the part
that needed actual review —
**the original "fully enumerated" claim is no longer true for four of
the selectors** and their arguments have been re-made below. W4 and W5
were added in the same review.

**Re-reconciled against the 2026-09-02 final-RTL run** (the three
measured-finding fixes, revision `2ecf4b2`): with W2 and W4 applied,
line coverage is 100 % (584 of 584); without them, 96.1 % (561 of
584). The waived total is **23 lines: 19 here (7 in W2a, 12 in W2b),
4 in W4**. Two lines left the list with that revision: W5's (the
waived line was deleted with `multdiv`'s dead multiply half — W5 is
closed below) and W2b's multdiv result-mux default, which the
2026-09-02 annotated database records as covered (26 hits) in the
rewritten divider — no longer an exclusion, so no longer waived.
Line numbers below are from the 2026-09-02 annotated database
(`build/cov/ann_line/`).

*The 2026-09-01 reconciliation, for the record: 593 lines, 95.8 %
measured (568 of 593), 25 waived (20 in W2, 4 in W4, 1 in W5).*

### A correction: this waiver was wrong when first written

It originally claimed seventeen lines and said "every one of them" was
an unreachable default. Its own tables only accounted for fourteen.
The three unlisted lines were the decoder's illegal-instruction
defaults, and checking them properly gave three different answers:

* `cdriscv_32s_20_decoder.sv:252` really is unreachable — the OP-IMM `funct3`
  case lists all eight values — and is now waived under W2b below.
* `cdriscv_32s_20_decoder.sv:322` is **reachable**: a SYSTEM instruction with
  `funct3 = 100` leaves `csr_op` undecodable.
* `cdriscv_32s_20_decoder.sv:327` is **reachable**: the top level opcode
  default, which any unknown opcode falls through to.

Two lines had been waived as unreachable without anyone checking, in a
document whose entire purpose is to be that check. Both are now covered
by `fence_csr_test.S`, which executes `0x00004073` and `0x0000000b` and
requires each to trap as an illegal instruction.

The lesson is the obvious one and it is recorded here rather than
quietly fixed: a waiver list that does not reconcile against the actual
uncovered count is not a review, and the arithmetic is the cheapest
part of it.

### W2a — state machine recovery arms

| file | line | note |
|------|------|------|
| `cdriscv_32s_20_ams_if.sv` | 161 | |
| `cdriscv_32s_20_apb_bridge.sv` | 73 | |
| `cdriscv_32s_20_core.sv` | 682 | enum is now 3 bits with **5 of 8** values used (ST_SEQ) |
| `cdriscv_32s_20_jtag_tap.sv` | 85 | new 2026-09-01; 16 of 16 values used |
| `cdriscv_32s_20_lsu.sv` | 105 | |
| `cdriscv_32s_20_mbist.sv` | 132 | |
| `cdriscv_32s_20_multdiv.sv` | 126 | divider-only since 2026-09-02 (W5) |

Each is `default: state_d = <IDLE>;` in a `unique case (state_q)` whose
register is only ever assigned members of its enum, so no sequence of
inputs can reach the arm in simulation. The original wording said the
enums were fully enumerated; for the core that stopped being true when
ST_SEQ widened the state to three bits with five values used, and the
argument now rests (as it always really did) on the register's
assignments, plus the gate-level forcing below.

The JTAG TAP line is the same shape (its 4-bit enum does use all 16
values), and its recovery property has direct functional evidence
instead of a gate-level forcing: tb_jtag test 4 drives the machine into
a spread of states and requires five TMS=1 clocks to reach
Test-Logic-Reset from every one — the recovery an attached debugger
actually uses.

**They must not be deleted, and that is the point of the waiver.** An
upset in a state register *can* put the machine into an unused
encoding, and these arms are what returns it to a defined state rather
than leaving it stuck. Removing them to reach 100 % would trade a
safety property for a coverage number. The fault injection campaign is
where this behaviour is exercised, not the functional tests — and the
campaign has so far recorded no hang across 3 000 injections, which is
the evidence that the recovery works.

**Re-argued against the netlist for all six (2026-08-22).**
`make gate-fsm` forces the synthesised multiplier into each of the four
encodings its two state flops allow; the unused one returns to idle,
none produces X, and it computes correctly afterwards. `make
gate-fsm-apb` does the same for the APB bridge over all sixteen
encodings of its four-bit state, and then checks it still services a
read. Both recoveries survive synthesis.

`make gate-fsm-lsu` covers the LSU's eight encodings and
`make gate-fsm-mbist` the BIST's sixteen, the latter synthesised at
`Depth=16` so that a restarted march finishes inside the settle window.

`make gate-fsm-ams` and `make gate-fsm-core` complete the set. **No
machine in this waiver now rests on the RTL argument alone.**

*2026-09-01 caveat:* that sentence was written about the original six
machines. The JTAG TAP row rests on tb_jtag's five-TMS recovery sweep
rather than a gate-level forcing, and `gate-fsm-core` was run against
the pre-Zcmp core, whose state machine was two bits — the current one
is three bits with ST_SEQ. Re-running `gate-fsm-core` against the
five-state machine is a to-do attached to this waiver, not an omission
to hide.

The core needed a different check, and the reason is worth stating: its
RTL enum (at the time of the gate run) was two bits with all four
values used, so the `default:` arm was unreachable in the RTL — but
synthesis re-encodes to **three** bits,
and the netlist therefore has unused encodings the RTL never had. Every
value of the driven bits maps to a legal state, so "recovers to a legal
state" is true by construction and says nothing. What the check asserts
instead is that the state never goes X and that the core is **still
fetching** afterwards rather than wedged.

**"Recovers" does not mean "returns to idle", and assuming it did cost
three false failures.** The BIST legitimately ends a forced march in
`BS_DONE`, not `BS_IDLE`; both are quiescent and defined and both are a
successful recovery. Its bench therefore *measures* the terminal state
by running one normal BIST first, and accepts either. The right
question is whether the machine reaches a defined state it can
legitimately hold — not whether it reaches one particular state.

**The environment matters as much as the netlist.** A machine whose
handshake inputs are all tied low sits for ever in a legal state
waiting for a response, and a bench that requires "returns to idle"
then reports a recovery failure that is nothing of the kind. The LSU
does exactly this until `data_gnt_i` and `data_rvalid_i` are held high.
Two of these three checks needed no such tie and one did, which is
worth knowing before reading a failure as a defect.

**How this has to be done, learned the hard way.** The check must run
against a *standalone* netlist, not the flattened subsystem. Two
reasons, both about what synthesis does to the state register:

* yosys runs `FSM_DETECT` / `FSM_EXTRACT` / `FSM_OPT`, which pulls the
  machine out and re-encodes it. The RTL name may or may not survive as
  a driven net, and where it does the width can differ — the
  multiplier's state is two bits synthesised standalone and three bits
  inside the subsystem.
* After flattening, what survives is an escaped identifier whose *name*
  contains dots, declared at the RTL width with constant bits optimised
  away. So a four-bit declaration can have three flops and one
  permanently floating bit, and a bench that compares the whole vector
  reads X where it should read a state.

A bench built on those references spends its effort on naming artefacts
rather than on the design. An attempt to cover all six machines at once
from the subsystem netlist was abandoned for exactly that reason.

### W2b — mux arms over selectors the design never drives there

| file | line | selector | spare encodings? |
|------|------|----------|------------------|
| `cdriscv_32s_20_alu.sv` | 163 | ALU operation enum, **6 bits, 38 of 64 used** | yes — see below |
| `cdriscv_32s_20_decoder.sv` | 324 | OP-IMM `funct3`, all eight values listed | no |
| `cdriscv_32s_20_decompress.sv` | 193 | `instr[6:5]`, all four listed (c.sub/xor/or/and) | no |
| `cdriscv_32s_20_decompress.sv` | 220 | `instr[11:10]`, all four listed | no |
| `cdriscv_32s_20_decompress.sv` | 226 | quadrant-01 `funct3`, all eight listed | no |
| `cdriscv_32s_20_core.sv` | 333, 344 | operand select enums, 3 of 4 values used | yes — see below |
| `cdriscv_32s_20_core.sv` | 752 | writeback select enum, all four listed | no |
| `cdriscv_32s_20_lsu.sv` | 81, 143 | `addr[1:0]`, all four values listed | no |
| `cdriscv_32s_20_pmp.sv` | 107 | `pmpcfg.A`, all four values listed (OFF/TOR/NA4/NAPOT) | no |
| `cdriscv_32s_20_pmp.sv` | 116 | access type enum, 3 of 4 values used | yes — see below |

The full-selector rows are unreachable by construction — a two-bit
selector has no fifth value. The three rows marked **yes** are the ones
the 2026-09-01 review had to re-argue, because the original claim ("no
spare encodings") went false when `alu_op_e` widened to 6 bits for the
bitmanip operators and the operand/access enums were counted honestly:

* `alu_op_o` is driven only by the decoder, which assigns only enum
  members (the equivalence bench `block-decoder-equiv` pins every
  control word against variant 1); in ST_SEQ the core forces `ALU_ADD`.
* `op_a_sel_o` / `op_b_sel_o`: same driver, same argument.
* `req_type_i` of the PMP checker is a constant per instance
  (`PMP_ACC_EXEC` on the fetch port, READ/WRITE on the data port).

So reaching any of these arms requires an upset in a control register,
not a stimulus — which is W2a's argument in combinational form, and is
the fault-injection campaign's territory, not the functional tests'.

These are cheap to keep and give a defined output for an undefined
selector.

### W2c — WITHDRAWN (2026-08-21)

This waived `cdriscv_32s_20_mbist.sv:253`, the read decode's `default`, on the
grounds that a word access could only ever produce offsets `0x0`,
`0x4`, `0x8` or `0xc` — each controller claimed sixteen bytes and every
one of those had an arm.

**Closing finding V0-F1 invalidated it.** Adding `FAILDATH` at `+0x10`
required widening each controller's claim from sixteen bytes to
thirty-two, which makes `0x14`, `0x18` and `0x1c` reachable. The line
is now covered by a test in `rdback_test.S` rather than waived.

The waiver's own "what would invalidate this" section anticipated the
decode changing. It was right to, and it took one register to do it.

### What would invalidate this waiver

* A decoder gaining an opcode or `funct3` arm, which can turn a
  "fully enumerated" claim false. That is how two lines were waived
  wrongly the first time.
* A peripheral widening its address decode, which is what withdrew
  W2c: one new register at `+0x10` turned three previously impossible
  offsets into reachable ones.
* Any state enum gaining a value without an arm, which would turn a
  W2a default from unreachable into a live path.
* Gate level simulation, where synthesis may encode states differently
  and the "unreachable" argument has to be re-made against the netlist
  rather than the RTL. Done for the multiplier, see above; not done for
  the other five state machines.

## W1 — WITHDRAWN (2026-08-21)

The prefetch was deepened (V2-P1), and as this waiver predicted, the
three lines it covered became reachable: the fetcher now runs ahead, so
a redirect routinely finds a transaction in flight. The invariant
assertion that justified the waiver failed on the very first run after
the change, which is what it was written for.

Nothing is waived here any more. The original text is kept below,
because a withdrawn waiver is part of the argument's history.

### Original text

## W1 — `cdriscv_32s_20_if_stage.sv:87-89`, redirect coincident with a response

```systemverilog
end else if (resp_accepted) begin
  outstanding_q <= 1'b0;
  discard_q     <= 1'b0;
end
```

**Reached when** a redirect arrives while a fetch is still in flight,
and that fetch's response lands in the same cycle.

**These lines are not dead code.** Bounded model checking finds a
five-step counterexample to the invariant "no fetch is outstanding at a
redirect" when the block is checked against its own input space: a
redirect arriving while the buffer is empty leaves a fetch in flight,
and the block handles it correctly. The lines are defensive, and a
reuse of this block with a different execute stage would need them.

**Why the assembled subsystem cannot reach them.** `cdriscv_32s_20_core` only
asserts `redirect` in a cycle where it holds a valid instruction —
every redirect comes from a trap or a retire, and both require
`instr_valid`. With that as an assumption, `p_no_outstanding_at_redirect`
in `verif/formal/if_stage_fv.sv` **passes** to depth 20: with a
one-deep buffer, no fetch can be in flight at a redirect, so neither
this branch nor the `outstanding_q` branch below it can execute.

**The assumption is itself checked**, not merely assumed:
`verif/core/tb_cosim.sv` asserts `redirect |-> instr_valid` on every
co-simulation cycle, so every directed and random run discharges it.

**What covers the lines instead.** For the general case, `p_pc_stream`
to depth 20; its mutation test removes the discard on a coincident
redirect and is caught at step 6.

**Status.** Accepted for the current prefetch depth, and deliberately
*not* removed from the RTL. Finding V2-P1 proposes deepening the
prefetch, and the moment that happens these branches become live —
`p_no_outstanding_at_redirect` is expected to fail then, which is
exactly why it is written down as an assertion rather than a comment.

### How this waiver changed

The first version of it said the lines were merely hard to reach in
simulation, and guessed at a structural reason. Formal disproved the
guess in five steps. Writing the invariant down as a property, rather
than asserting it in prose, is what turned an assumption into either a
proof or a counterexample — and here it produced one of each,
depending on whether the core's own discipline is assumed.

## W3 — the E2E checker's detection cannot fire in a fault-free simulation (2026-09-01)

**No line is waived here** — `cdriscv_32s_20_e2e.sv` and
`cdriscv_32s_20_e2e_link.sv` are at 100 % line coverage, because their
compare logic runs on every transfer. What is waived is the
*situation*: `rd_err_o` / `wr_err_o` asserting because the check bits
genuinely disagree, and FLT_E2E latching from that.

**Reached when** the interconnect corrupts payload or address between
an E2E master and slave endpoint.

**Why simulation cannot reach it.** The check bits are generated and
checked over the same wires by the same proven (39,32) Hsiao code; in a
fault-free netlist there is nothing on the path to disagree with. This
is not a gap in the stimulus — it is the definition of the mechanism.

**What covers it instead.**

* The *detection* is proven by `block-e2e-link` (12 024 checks, mutants
  10/10, `scripts/mutate_e2e_link.py`), which puts corruptible wires
  between the endpoints and drives every deterministic fault class —
  since 2026-09-02 including byte-enable corruption, the fold's third
  field.
* The *latching and reaction* path behind FLT_E2E is covered in the
  real subsystem: `safety_test` check 10 pulses bit 14 through the
  safety controller's INJECT register and requires STATUS[14] to latch
  and W1C-clear (functional point `cp_flt_e2e`, hit).
* **Re-reviewed 2026-09-02** (the fold changed: byte enables joined
  it). The waived situation is now also *simulated* in the subsystem:
  `tb_safety` forces a be flip onto a live write beat and a corrupted
  check onto a read response and requires FLT_E2E both times, so the
  checker's own detection fires in a coverage-instrumented run rather
  than being argued from the block bench alone. What remains waived is
  only the exhaustive escape statistics, which stay `block-e2e`'s
  business.

**Status**: permanent, re-review only if the E2E fold or the fault
wiring changes (last re-review 2026-09-02, for the be fold).

## W4 — `cdriscv_32s_20_core.sv:523-526`, fetch-target misalignment trap (2026-09-01)

```systemverilog
end else if (instr_misalign) begin
  exc_valid = 1'b1;
  exc_cause = EXC_INSTR_MISALIGN;
  exc_tval  = target_pc;
end
```

**Reached when** a control transfer targets an odd byte address
(`target_pc[0]` set — with the C extension the halfword-misaligned
case, bit 1, is legal by definition).

**Why simulation cannot reach it.** JALR clears bit 0 in hardware, as
the spec requires; branch and JAL immediates are even multiples of two
by construction; `mepc` writes have bit 0 cleared in the CSR file; the
trap vector is aligned. No instruction this core can execute produces
an odd target. `trap_test` section 11 documents exactly this and tests
the property in the only honest direction left: it jumps to a
halfword-aligned target and requires that it executes and does NOT trap
(checks 12 and 30).

**These lines are not dead code.** They are the machine-mode trap the
spec mandates for a misaligned fetch, and they become live the moment a
variant drops the C extension (misa here hard-wires C, so no CSR write
can re-enable the case). Removing them would couple trap correctness
to the decoder's immediate construction.

**Status**: permanent while C is hard-wired; re-review if misa gains a
writable C bit or a non-C variant forks from this RTL.

## W5 — RESOLVED 2026-09-02: the dead multiply half was removed

W5 waived `cdriscv_32s_20_multdiv.sv:193` (the MULH/MULHSU/MULHU result
arm), verified logic that variant 2's integration could never select:
the core routes every multiply to the single-cycle
`cdriscv_32s_20_mult`, so `multdiv`'s iterative multiply datapath was
dead in-system — a latent-fault surface with no functional observer.
The waiver carried a to-do ("revisit when `multdiv` is next touched"),
and the revisit resolved it by taking the honest fix it named:
**the multiply datapath was parameterised out — deleted — on
2026-09-02**, together with its FSM service, sign-correction register
and result arms. The waived line no longer exists.

What remains is a divider whose divide/remainder behaviour is
byte-for-byte the inherited one (`block-multdiv` re-verified against
the reference model, divide vectors only — the multiply vectors moved
to `block-mult`'s jurisdiction with the logic they exercised), plus a
structural contract: the core's dispatch (`start_md` gated by
`!md_is_mul`) is the only path to `req_i`, and the module carries a
simulation-only check that a multiply encoding reaching it is an
error. The module's own defensive `default` arms are argued in W2a/W2b
above like everyone else's.

**Status**: closed. Kept as a record because the finding
(verification_findings_20.md §17 — a coverage report counting a dead
feature as alive via its reset encoding) is worth more than the waiver
was.

## Format for future entries

Each waiver states: the lines, when they would be reached, why
simulation cannot reach them, what covers them instead, and whether the
waiver is permanent or has a to-do attached. A waiver without the third
and fourth parts is not a waiver, it is an excuse.
