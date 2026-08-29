# Frozen variant-1 reference

Verbatim, unmodified copies of the signed-off cdriscv-32s modules, kept
here so the equivalence benches can instantiate them beside this repo's
own versions and compare field for field.

| file | why it is here |
|---|---|
| `cdriscv_pkg.sv` | the original 4-bit `alu_op_e` and CSR map |
| `cdriscv_decoder.sv` | reference for `tb_decoder_equiv` |
| `cdriscv_csr.sv` | reference for `tb_csr_equiv` |
| `cdriscv_counter64.sv`, `cdriscv_cfg_parity.sv` | instantiated by the reference CSR; unchanged between variants, vendored so this directory stands alone |

**Rules.**

1. These files are **never synthesised** and are not part of any design
   filelist — they appear only in the two equivalence benches.
2. They are **never edited**. If one of them changes, the comparison
   stops meaning what it claims to mean, which is the whole point of the
   check. Re-copy from cdriscv-32s instead.
3. They keep their original `cdriscv_*` names on purpose. This repo's
   own modules are `cdriscv_32s_20_*`, so the two sets cannot collide
   and a bench can hold both at once.

Source: https://github.com/ChipDesign-BV/cdriscv-32s
