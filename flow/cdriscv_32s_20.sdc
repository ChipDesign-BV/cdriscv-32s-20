# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv-32s-20 -- timing constraints.
#
# WHY THIS FILE EXISTS
#
# LibreLane's built-in base.sdc constrains exactly one clock.  It says so
# itself: "Multi-clock files are not currently supported by the base SDC
# file. Only the first clock will be constrained."  This design has three
# clock domains, so two of them were being signed off with no constraint
# at all:
#
#   ref_clk_i  the clock monitor's independent reference.  In the v2first
#              run its 107 flip-flops were clocked through a chain of
#              max-fanout repair buffers (ref_clk_i -> input83 ->
#              fanout7111 -> fanout7102 -> fanout7094 -> flops), not a CTS
#              tree, because OpenROAD never knew it was a clock.  STA had
#              constrained the port as a *data* input instead
#              (set_input_delay ... [get_ports {ref_clk_i}]).
#   tck_i      the JTAG TAP domain (cdriscv_32s_20_jtag_tap).
#
# An unconstrained domain does not fail timing.  It reports nothing, which
# reads as a pass.
#
# This file is self-contained: it reproduces what base.sdc does and then
# does it for all three clocks.  It deliberately does not `source` the
# LibreLane copy -- that path is an internal detail of the installed
# version, and a constraint file that silently changes when the tool is
# upgraded is not a signoff artefact.

# ---------------------------------------------------------------------
# 0. domains present in this design
# ---------------------------------------------------------------------
#
# Both extra clocks are constrained at the system clock period.  That is
# deliberately the most demanding realistic bound rather than a guess at
# the intended frequency: the reference oscillator is specified as "slow,
# always-on" and a 1149.1 TCK is conventionally well under the core
# clock, so constraining both at CLOCK_PERIOD covers every frequency
# either is meant to run at, up to 25 MHz.  Faster than that is outside
# the assumptions of use and is not signed off.
#
# Each entry is {port  reset-port  {other input ports}  {output ports}}.

set domains {
    {clk_i     rst_ni     {}                  {}}
    {ref_clk_i ref_rst_ni {}                  {}}
    {tck_i     trst_ni    {tms_i tdi_i}       {tdo_o tdo_oe_o}}
}

set io_pct       $::env(IO_DELAY_CONSTRAINT)
set clock_period $::env(CLOCK_PERIOD)
set io_delay     [expr {$clock_period * $io_pct / 100}]

if { ![info exists ::env(SYNTH_CLK_DRIVING_CELL)] } {
    set ::env(SYNTH_CLK_DRIVING_CELL) $::env(SYNTH_DRIVING_CELL)
}
set data_cell [split $::env(SYNTH_DRIVING_CELL) "/"]
set clk_cell  [split $::env(SYNTH_CLK_DRIVING_CELL) "/"]

# ---------------------------------------------------------------------
# 1. create every clock that is actually on this block
# ---------------------------------------------------------------------

# `get_property ... name` is not portable across OpenSTA builds; get_full_name
# is.  Try it first and fall back, rather than assuming either.
proc cd_port_name {obj} {
    if { ![catch {set n [get_full_name $obj]}] } { return $n }
    return [get_property $obj name]
}

set present  [list]
set clk_ports [list]
foreach d $domains {
    set port [lindex $d 0]
    if { [llength [get_ports -quiet $port]] } {
        create_clock -name $port -period $clock_period [get_ports $port]
        set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) [get_clocks $port]
        set_clock_transition  $::env(CLOCK_TRANSITION_CONSTRAINT)  [get_clocks $port]
        set_driving_cell -lib_cell [lindex $clk_cell 0] -pin [lindex $clk_cell 1] \
            [get_ports $port]
        lappend present   $d
        lappend clk_ports $port
    } else {
        puts "\[INFO] cdriscv: no port $port on this block, domain skipped."
    }
}
if { [llength $present] == 0 } {
    puts "\[ERROR] cdriscv: none of the expected clock ports exist."
}

# ---------------------------------------------------------------------
# 2. design-wide electrical constraints (as base.sdc)
# ---------------------------------------------------------------------

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

# ---------------------------------------------------------------------
# 3. reference every port to the clock it actually belongs to
# ---------------------------------------------------------------------
#
# base.sdc referenced all inputs and all outputs to the single clock it
# knew about.  Here each port named in `domains` is referenced to its own
# clock, and everything left over belongs to clk_i.

set claimed $clk_ports
foreach d $present {
    set port [lindex $d 0]
    foreach p [concat [list [lindex $d 1]] [lindex $d 2]] {
        if { $p ne "" && [llength [get_ports -quiet $p]] } {
            set_input_delay $io_delay -clock [get_clocks $port] [get_ports $p]
            set_driving_cell -lib_cell [lindex $data_cell 0] -pin [lindex $data_cell 1] \
                [get_ports $p]
            lappend claimed $p
        }
    }
    foreach p [lindex $d 3] {
        if { [llength [get_ports -quiet $p]] } {
            set_output_delay $io_delay -clock [get_clocks $port] [get_ports $p]
            lappend claimed $p
        }
    }
}

# remaining inputs / outputs -> the system clock
set sys [lindex [lindex $present 0] 0]

set rest_in [list]
foreach p [all_inputs] {
    if { [lsearch -exact $claimed [cd_port_name $p]] < 0 } { lappend rest_in $p }
}
if { [llength $rest_in] } {
    set_input_delay $io_delay -clock [get_clocks $sys] $rest_in
    set_driving_cell -lib_cell [lindex $data_cell 0] -pin [lindex $data_cell 1] $rest_in
}

set rest_out [list]
foreach p [all_outputs] {
    if { [lsearch -exact $claimed [cd_port_name $p]] < 0 } { lappend rest_out $p }
}
if { [llength $rest_out] } {
    set_output_delay $io_delay -clock [get_clocks $sys] $rest_out
}

set cap_load [expr {$::env(OUTPUT_CAP_LOAD) / 1000.0}]
set_load $cap_load [all_outputs]

# ---------------------------------------------------------------------
# 4. the domains are mutually asynchronous
# ---------------------------------------------------------------------
#
# Every crossing between them goes through cdriscv_32s_20_sync_lvl or
# cdriscv_32s_20_pulse_sync, and the JTAG debug bus additionally uses a
# closed-loop toggle handshake (cdriscv_32s_20_dbg_bridge), so no path
# between the groups is meant to be timed.  Without this the tool would
# try to time them against each other -- and either fail, or over-
# constrain the design into a worse clk_i result.

if { [llength $clk_ports] > 1 } {
    set groups [list]
    foreach c $clk_ports { lappend groups -group [get_clocks $c] }
    set_clock_groups -asynchronous -name cdriscv_async_domains {*}$groups
}

# ---------------------------------------------------------------------
# 5. derating and propagation (as base.sdc)
# ---------------------------------------------------------------------

set_timing_derate -early [expr {1 - [expr {$::env(TIME_DERATING_CONSTRAINT) / 100}]}]
set_timing_derate -late  [expr {1 + [expr {$::env(TIME_DERATING_CONSTRAINT) / 100}]}]

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}

puts "\[INFO] cdriscv-32s-20: constrained clocks -> $clk_ports"
