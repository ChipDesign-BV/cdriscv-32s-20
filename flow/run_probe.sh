#!/bin/bash
# Variant 2's hardening run.  Sized from its own synthesis: 62201 cells
# against variant 1's 54422, so the die is wider than variant 1's to keep
# utilisation clear of the diode-legalisation cliff.
#
# Pass a run tag as $1; it defaults to the current complete-RTL run.
# v2first was the first run and predates Zca/Zcb, the single-cycle
# multiplier and the JTAG TAP -- keep it, it is what the timing
# comparison in doc/variant_status.md is against.
cd /foss/designs/cdriscv-32s-20/flow || exit 1
TAG=${1:-probe1}
export PATH=/foss/tools/verilator/bin:/foss/tools/openroad-librelane/bin:/foss/tools/magic/bin:/foss/tools/netgen/bin:/foss/tools/iverilog/bin:/foss/tools/klayout:/foss/tools/bin:$PATH
librelane --manual-pdk --pdk-root /foss/pdks --run-tag "$TAG" \
          config_timing_probe.json > "librelane_$TAG.log" 2>&1
echo "[$TAG] exited $? at $(date +%H:%M:%S)"
