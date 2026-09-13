#!/bin/bash
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# The O8 arch-test subset on the FINAL hardened netlist (chip2b), the
# chip-level counterpart of gate_arch_subset.sh.  Each test is built
# exactly as there (same link script, same per-test macro set from the
# riscof Makefile), but instead of being preloaded into the TCMs it is
# packed by scripts/mkbootimg.py into a quad-payload QSPI flash image,
# booted through the loader on the pads of the flat post-route netlist
# with SDF timing (verif/gate/tb_sdf_chip.sv), and its signature is
# then read back from the D-TCM macro arrays and compared word-for-word
# against the Spike reference riscof recorded.
#
#   scripts/gate_chip_arch.sh I/add-01 M/mul-01 ...
#   CHIP_CORNER      SDF corner (default nom_typ_1p20V_25C); the filtered
#                    SDF build/gate/chip/chip_<corner>.sdf must exist
#   CHIP_JOBS        parallel vvp runs (default 2 -- memory-bound)
#   CHIP_ARCH_CYCLES per-test cycle budget (default 300000)
#
# Quad payload: the arch images are 20-24 KiB, which the 1-bit command
# would move at 16 clk/byte; quad is 4.  The header and every command
# phase still go 1-bit, so both loader paths are exercised; the smoke
# target boots both image types.
#
# A test that does not build is reported SKIP, a test whose run did
# not produce a verdict or a signature is FAIL -- a missing result is
# never a pass.
set -u
cd "$(dirname "$0")/.."
export PATH="/foss/tools/iverilog/bin:/foss/tools/riscv-gnu-toolchain/bin:/foss/tools/bin:$PATH"
SUITE=verif/riscof/riscv-arch-test/riscv-test-suite
WORK=verif/riscof/riscof_work
CORNER=${CHIP_CORNER:-nom_typ_1p20V_25C}
JOBS=${CHIP_JOBS:-2}
CYCLES=${CHIP_ARCH_CYCLES:-300000}
B=build/gate/chip
VVP=$B/tb_sdf_chip.vvp
SDF=$B/chip_$CORNER.sdf
for f in $VVP $SDF; do
  [ -s "$f" ] || { echo "gate_chip_arch: missing $f"; exit 1; }
done

PASS=0; FAIL=0; SKIP=0
RUNS=()
# ---- build every image first (fast, sequential) ---------------------
for spec in "$@"; do
  grp=${spec%%/*}; t=${spec##*/}
  src=$SUITE/rv32i_m/$grp/src/$t.S
  b=$B/arch_$t
  MACROS=$(grep -A4 "/$t\.S" $WORK/Makefile.DUT-cdriscv | grep -oE -- "-D[a-zA-Z_0-9=]+" | sort -u | tr '\n' ' ')
  [ -z "$MACROS" ] && MACROS="-DTEST_CASE_1=True -DXLEN=32"
  rm -f $b.elf
  riscv64-unknown-elf-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -mno-relax \
    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -T verif/gate/arch/link.ld -I verif/gate/arch -I $SUITE/env \
    "$src" -o $b.elf $MACROS 2>/dev/null
  if [ ! -f $b.elf ]; then echo "SKIP  $spec (build failed / does not fit)"; SKIP=$((SKIP+1)); continue; fi
  riscv64-unknown-elf-objcopy -O binary --only-section=.text.init --only-section=.text $b.elf $b.itcm.bin
  riscv64-unknown-elf-objcopy -O binary --only-section=.data $b.elf $b.dtcm.bin
  python3 scripts/mkbootimg.py $b.flash.hex \
    --seg 0x00000000 $b.itcm.bin --seg 0x10000000 $b.dtcm.bin --pad0 64 --quad >/dev/null \
    || { echo "SKIP  $spec (mkbootimg failed)"; SKIP=$((SKIP+1)); continue; }
  RUNS+=("$spec")
done

if [ -n "${CHIP_BUILD_ONLY:-}" ]; then
  for spec in "${RUNS[@]}"; do t=${spec##*/}; echo "built $spec: $(wc -l < $B/arch_$t.flash.hex) flash bytes"; done
  echo "gate-chip-arch: images only (CHIP_BUILD_ONLY), $SKIP skip"; exit 0
fi

# ---- run, JOBS at a time ---------------------------------------------
run_one() {
  spec=$1; t=${spec##*/}; b=$B/arch_$t
  SB=$(riscv64-unknown-elf-nm $b.elf | awk '/ begin_signature/{print $1}')
  SE=$(riscv64-unknown-elf-nm $b.elf | awk '/ end_signature/{print $1}')
  rm -f $b.$CORNER.sig $b.$CORNER.log
  /usr/bin/time -f "[TB-CHIP] wall %e s, maxrss %M KiB" \
    vvp $VVP +FLASH_HEX=$b.flash.hex +SDF=$SDF +MAX_CYCLES=$CYCLES \
    +SIGFILE=$b.$CORNER.sig +SIGBEGIN=$SB +SIGEND=$SE > $b.$CORNER.log 2>&1
}
export -f run_one
export B CORNER SDF VVP CYCLES
if [ ${#RUNS[@]} -gt 0 ]; then
  printf "%s\n" "${RUNS[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one {}'
fi

# ---- verdicts ------------------------------------------------------------
for spec in "${RUNS[@]}"; do
  grp=${spec%%/*}; t=${spec##*/}; b=$B/arch_$t
  ref=$WORK/rv32i_m/$grp/src/$t.S/ref/Reference-spike.signature
  log=$b.$CORNER.log; sig=$b.$CORNER.sig
  W=$(grep -oE "wall [0-9.]+ s" $log 2>/dev/null | head -1)
  if [ -s "$sig" ] && grep -q "\[TB-CHIP\] PASS" $log && diff -q $sig "$ref" >/dev/null 2>&1; then
    C=$(grep -m1 -oE "PASS after [0-9]+ cycles" $log | tr -dc 0-9)
    BC=$(grep -m1 -oE "boot at [0-9]+" $log | tr -dc 0-9)
    echo "PASS  $spec ($C cycles, boot at $BC, $W, $CORNER, signature matches Spike: $(wc -l < $sig) words)"
    PASS=$((PASS+1))
  else
    why="no verdict"
    grep -q "\[TB-CHIP\] PASS" $log 2>/dev/null && why="signature differs from Spike"
    grep -q "\[TB-CHIP\] FAIL" $log 2>/dev/null && why="bench FAIL: $(grep -m1 '\[TB-CHIP\] FAIL' $log)"
    grep -q "\[TB-CHIP\] TIMEOUT" $log 2>/dev/null && why="TIMEOUT: $(grep -m1 '\[TB-CHIP\] TIMEOUT' $log)"
    [ -s "$sig" ] || why="$why; no signature written"
    echo "FAIL  $spec ($why, $W, see $log)"
    FAIL=$((FAIL+1))
  fi
done
echo "gate-chip-arch subset ($CORNER): $PASS pass, $FAIL fail, $SKIP skip"
[ $FAIL -eq 0 ] && [ $SKIP -eq 0 ]
