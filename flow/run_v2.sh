#!/bin/bash
# Variant 2's first hardening run.  Sized from its own synthesis: 62201
# cells against variant 1's 54422, so the die is wider than variant 1's
# to keep utilisation clear of the diode-legalisation cliff.
cd /foss/designs/cdriscv-32s-20/flow || exit 1
export PATH=/foss/tools/verilator/bin:/foss/tools/openroad-librelane/bin:/foss/tools/magic/bin:/foss/tools/netgen/bin:/foss/tools/iverilog/bin:/foss/tools/klayout:/foss/tools/bin:$PATH
librelane --manual-pdk --pdk-root /foss/pdks --run-tag v2first \
          config.json > librelane_v2first.log 2>&1
echo "[v2first] exited $? at $(date +%H:%M:%S)"
