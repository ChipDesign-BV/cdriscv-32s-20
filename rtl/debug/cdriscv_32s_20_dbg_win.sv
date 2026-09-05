// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- JTAG observation window.
//
// What the TAP can reach.  Read-only, six words, in the system clock
// domain (cdriscv_32s_20_dbg_bridge does the crossing).
//
//   0x00  IDCODE   the TAP's own IDCODE, so a scan can confirm it is
//                  talking to the window and not to a floating bus
//   0x04  STATUS   [0] core_sleep   [1] fault_any   [2] err_pin
//                  [3] reset_req    [4] retire_seen
//                  [5] boot_done    [6] boot_fault
//                  (5 and 6 appended for the QSPI boot loader; a
//                  subsystem built with BootEnable=0 reads boot_done=1,
//                  boot_fault=0 -- the bypass ties them so)
//   0x08  FAULTINT the internal fault vector, as the safety controller
//                  sees it
//   0x0c  FAULTEXT the external fault vector
//   0x10  LASTPC   PC of the last retired instruction
//   0x14  LASTINSN its encoding (16-bit for a compressed instruction,
//                  as retire_instr_o presents it)
//
// Any other address -- including anything above 0x1f -- reads
// 32'hffff_ffff.  That is a deliberate poison
// value rather than zero: every real register here can legitimately read
// zero, so zero cannot double as "no such address".
//
// WHAT THIS IS NOT
//
// It is an observation window, not a debug module.  It cannot halt the
// core, single-step it, read memory, or write anything at all -- writes
// are accepted by the bus and discarded.  Reaching memory would make the
// TAP a second master on cdriscv_32s_20_bus, which needs arbitration
// against the core and changes the safety argument (a debug port that
// can write TCM is a fault injection path that has to be justified in
// the FMEDA and disabled in the field).  That work is not done, so the
// window is read-only by construction rather than by configuration.
//
// LASTPC/LASTINSN are held from the last cycle retire_valid_i was high,
// not sampled live, so a scan taken after the core has stopped or parked
// still reports what it last executed.

// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem.  No signoff gate is met in this
// repository -- see README.md.  NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_32s_20_dbg_win #(
    parameter logic [31:0] IdCode        = 32'h0CD1_507B,
    parameter int unsigned NumIntFaults  = 16,
    parameter int unsigned NumExtFaults  = 16
) (
    input  wire         clk_i,
    input  wire         rst_ni,

    // bridge side
    input  wire         acc_i,
    input  wire  [31:0] acc_addr_i,
    input  wire  [31:0] acc_wdata_i,   // accepted and discarded
    input  wire         acc_we_i,      // accepted and discarded
    output logic [31:0] acc_rdata_o,

    // observed state
    input  wire         boot_done_i,
    input  wire         boot_fault_i,
    input  wire         core_sleep_i,
    input  wire         fault_any_i,
    input  wire         err_pin_i,
    input  wire         reset_req_i,
    input  wire  [NumIntFaults-1:0] fault_int_i,
    input  wire  [NumExtFaults-1:0] fault_ext_i,
    input  wire         retire_valid_i,
    input  wire  [31:0] retire_pc_i,
    input  wire  [31:0] retire_instr_i
);

  localparam logic [31:0] Poison = 32'hffff_ffff;

  // ---- last retired instruction, held -----------------------------

  logic [31:0] last_pc_q, last_insn_q;
  logic        retire_seen_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      last_pc_q     <= 32'h0;
      last_insn_q   <= 32'h0;
      retire_seen_q <= 1'b0;
    end else if (retire_valid_i) begin
      last_pc_q     <= retire_pc_i;
      last_insn_q   <= retire_instr_i;
      retire_seen_q <= 1'b1;
    end
  end

  // ---- read decode ------------------------------------------------
  //
  // Combinational: the bridge registers the result on the same cycle it
  // raises acc_i.  acc_i itself is not in the decode -- there is nothing
  // to gate, and a read with no side effects costs nothing when idle.

  logic [31:0] status;
  assign status = {25'b0,
                   boot_fault_i,
                   boot_done_i,
                   retire_seen_q,
                   reset_req_i,
                   err_pin_i,
                   fault_any_i,
                   core_sleep_i};

  // The whole 32-bit address is decoded, not just the low byte.  Decoding
  // [7:0] alone would mirror these six words across every 256-byte page
  // of the debug address space, so a debugger reading a wrong address
  // would get a plausible answer instead of the poison value.

  always_comb begin
    acc_rdata_o = Poison;
    if (acc_addr_i[31:8] == 24'h00_0000) begin
      unique case (acc_addr_i[7:0])
        8'h00:   acc_rdata_o = IdCode;
        8'h04:   acc_rdata_o = status;
        8'h08:   acc_rdata_o = {{(32-NumIntFaults){1'b0}}, fault_int_i};
        8'h0c:   acc_rdata_o = {{(32-NumExtFaults){1'b0}}, fault_ext_i};
        8'h10:   acc_rdata_o = last_pc_q;
        8'h14:   acc_rdata_o = last_insn_q;
        default: acc_rdata_o = Poison;
      endcase
    end
  end

  // acc_i / acc_we_i / acc_wdata_i are intentionally unused: the window
  // is read-only and stateless with respect to the debug bus.  Named
  // here so lint reports a real omission rather than these three.
  logic unused;
  assign unused = acc_i ^ acc_we_i ^ (|acc_wdata_i);

endmodule

`default_nettype wire
