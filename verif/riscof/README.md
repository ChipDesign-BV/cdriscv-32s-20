# RISCOF — architectural test suite (objective O1)

**Status: producing a result — 143 of 143 selected tests pass**
(2026-09-01, RTL with C and Zcmp), including all 29 `rv32i_m/B` and the
`rv32i_m/C` tests, against Spike as the reference. Read the caveats
section before quoting anything from here; in particular the suite is a
vintage release and 43 PMP tests are dropped by selection rather than
by result. The `misalign-*` tests are now *correctly* deselected: with
C implemented, IALIGN is 16 and the traps they expect cannot occur —
running them was a staleness bug in the ISA yaml, not evidence.

## What this is

RISCOF runs the official `riscv-arch-test` suite against the DUT and a
reference model, and compares signatures. It is the only thing that
answers "does this core implement the RISC-V specification" — Spike
co-simulation answers the weaker question "does it agree with Spike on
the programs we happened to write".

## Setup

The test suite is 1.7 GB and is not vendored:

```sh
pip install "cython<3" && pip install --no-build-isolation riscof
cd verif/riscof && riscof arch-test --clone
git -C riscv-arch-test checkout old-framework-3.x   # main no longer has the suite
```

The plugins expect a `riscv32-unknown-elf-*` toolchain prefix and this
environment ships `riscv64-`, which targets rv32 perfectly well through
`-march`/`-mabi`. Symlink rather than patch the vendor plugin:

```sh
for t in gcc objcopy nm objdump ld as; do
  ln -sf "$(command -v riscv64-unknown-elf-$t)" ~/.local/bin/riscv32-unknown-elf-$t
done
```

Then `make riscof`.

## How the DUT plugin works

`cdriscv/riscof_cdriscv.py` builds each test and runs it on the Icarus
co-simulation bench:

1. `objcopy` the ELF to a flat binary from `0x8000_0000`, padded to
   `end_signature`, so code, `.tohost` and the signature region land at
   the right word offsets;
2. `mkimage.py` turns that into the 39-bit ECC hex image the TCM loads
   — the same builder the rest of the suite uses;
3. `vvp` runs it with `+TOHOST`, `+SIGBEGIN`, `+SIGEND` and `+SIGFILE`.

The bench watches for the store to `tohost`, then dumps the signature
words straight out of the I-TCM array. The SEC-DED encoding is
systematic — `cw = {parity, data}` — so the data half is the low 32
bits. All four plusargs come from the ELF symbol table via `nm`;
nothing about the addresses is assumed.

`env/model_test.h` and `env/link.ld` are the target environment. There
is no console, so the IO macros are empty and the signature is the only
output.

## Two selection interventions, still in force

Both live in `cdriscv/riscof_cdriscv.py` / `spike/riscof_spike.py` and
are written up with reproductions in
[upstream-issues.md](upstream-issues.md):

* **`-mno-relax`.** On `old-framework-3.x` the suite's `LA` macro
  brackets its alignment in `.option rvc`, so the assembler pads with
  `c.nop` and linker relaxation keeps the padding in the executed
  stream. On the pre-C core that made the suite unrunnable — an RV32I
  core must trap on a 16-bit encoding — and turning relaxation off
  resolved it (replacing the earlier workaround of pinning release
  3.5.3). The flag stays so the DUT and reference builds match byte
  for byte.
* **The `pmp` group is dropped from the generated test list.** All 43
  gate PMP on `verify (PMP['implemented'])`, which RISCOF never
  evaluates — it selects on `check` clauses only — so they select on
  any RV32 I+Zicsr core regardless of what it implements. The drop
  dates from when this core had no PMP; the core **now implements PMP
  on data and fetch**, and re-admitting the 43 tests has not been
  revisited. They are dropped by selection, not by result — an open
  caveat, not evidence. `make riscof` prints how many it dropped.

### One trap to be careful of

`RVMODEL_DATA_SECTION` must expand inside `RVMODEL_DATA_END`, after
`end_signature` — never inside `RVMODEL_DATA_BEGIN`. On RISC-V `.align 8`
means 256 bytes, so that block drags ~400 bytes of padding with it, and ahead
of the signature the padding sits between `rvtest_data` and `mtrap_sigptr`.
The arch-test trap handler records `mtval` *relative to `mtrap_sigptr`*, so
the same faulting address then encodes as a different number than in the
reference build, and every misaligned-**load** test fails while everything
else passes. See finding V35.

## History

The suite was first unrunnable (the `LA` macro's `c.nop` padding traps
any non-C core — `-mno-relax` resolves it), then pinned to release
3.5.3, then unpinned. The selection grew with the ISA yaml: 85 tests
on the inherited RV32IM_Zicsr_Zifencei declaration (39 I, 8 M, 22
hints, 15 privilege, 1 Zifencei — all passing), 114 with B declared,
143 with C declared (which also correctly deselected the 8
`misalign-*` tests). The whole trail, including the three misaligned-
load failures that turned out to be this repository's own environment
defect, is findings V34–V36 and [upstream-issues.md](upstream-issues.md).
