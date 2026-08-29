// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 v2 -- JTAG TAP, without pulp-platform/riscv-dbg.
//
// riscv-dbg is the usual way to get RISC-V external debug, but it
// brings a large third-party codebase that would have to be qualified
// alongside the core.  For a safety part the cheaper argument is a
// small TAP written and verified in-house, exposing a deliberately
// narrow debug surface rather than the full RISC-V Debug spec.
//
// This is a standard IEEE 1149.1 TAP: the 16-state controller, IR/DR
// scan chains, and the mandatory BYPASS and IDCODE instructions.  On
// top sit two private instructions that reach a simple memory-mapped
// debug bus -- address, then data -- which is all the halt/resume and
// memory peek/poke logic needs.
//
// What this deliberately does NOT implement: abstract commands, program
// buffer, system bus access, or the DM register map of the RISC-V Debug
// specification.  A standard OpenOCD RISC-V config will NOT attach.
// That is the trade: no third-party code to qualify, at the cost of a
// custom debug adapter script.
//
// The TAP is in its own clock domain (tck) and every crossing into the
// core domain goes through cdriscv_32s_20_sync, as variant 1 does for its
// reference-domain signals.
//
// STATUS: NEW AND UNVERIFIED -- not through the O1-O9 gate.  Do not use.

`default_nettype none

module cdriscv_32s_20_jtag_tap #(
    parameter logic [31:0] IdCode = 32'h0CD1_507B   // ChipDesign, part 1, rev 0
) (
    // ---- JTAG pins -------------------------------------------------
    input  logic        tck_i,
    input  logic        tms_i,
    input  logic        tdi_i,
    output logic        tdo_o,
    output logic        tdo_oe_o,
    input  logic        trst_ni,

    // ---- debug bus, tck domain (synchronise outside) ---------------
    output logic [31:0] dbg_addr_o,
    output logic [31:0] dbg_wdata_o,
    output logic        dbg_req_o,
    output logic        dbg_we_o,
    input  logic [31:0] dbg_rdata_i
);

  // ---- TAP state machine ---------------------------------------------
  typedef enum logic [3:0] {
    TEST_LOGIC_RESET, RUN_TEST_IDLE,
    SELECT_DR, CAPTURE_DR, SHIFT_DR, EXIT1_DR, PAUSE_DR, EXIT2_DR, UPDATE_DR,
    SELECT_IR, CAPTURE_IR, SHIFT_IR, EXIT1_IR, PAUSE_IR, EXIT2_IR, UPDATE_IR
  } tap_state_e;

  tap_state_e state_q, state_d;

  // Written as if/else rather than `state_d = tms ? A : B`: a ternary
  // whose arms are enum literals needs an explicit cast in Icarus, and
  // the plan runs it beside Verilator.  This is finding V0-F6, already
  // recorded for the decoder, LSU and AMS interface -- reintroduced here
  // and caught by the same second opinion that caught it originally.
  always_comb begin
    unique case (state_q)
      TEST_LOGIC_RESET : if (tms_i) state_d = TEST_LOGIC_RESET; else state_d = RUN_TEST_IDLE;
      RUN_TEST_IDLE    : if (tms_i) state_d = SELECT_DR;        else state_d = RUN_TEST_IDLE;
      SELECT_DR        : if (tms_i) state_d = SELECT_IR;        else state_d = CAPTURE_DR;
      CAPTURE_DR       : if (tms_i) state_d = EXIT1_DR;         else state_d = SHIFT_DR;
      SHIFT_DR         : if (tms_i) state_d = EXIT1_DR;         else state_d = SHIFT_DR;
      EXIT1_DR         : if (tms_i) state_d = UPDATE_DR;        else state_d = PAUSE_DR;
      PAUSE_DR         : if (tms_i) state_d = EXIT2_DR;         else state_d = PAUSE_DR;
      EXIT2_DR         : if (tms_i) state_d = UPDATE_DR;        else state_d = SHIFT_DR;
      UPDATE_DR        : if (tms_i) state_d = SELECT_DR;        else state_d = RUN_TEST_IDLE;
      SELECT_IR        : if (tms_i) state_d = TEST_LOGIC_RESET; else state_d = CAPTURE_IR;
      CAPTURE_IR       : if (tms_i) state_d = EXIT1_IR;         else state_d = SHIFT_IR;
      SHIFT_IR         : if (tms_i) state_d = EXIT1_IR;         else state_d = SHIFT_IR;
      EXIT1_IR         : if (tms_i) state_d = UPDATE_IR;        else state_d = PAUSE_IR;
      PAUSE_IR         : if (tms_i) state_d = EXIT2_IR;         else state_d = PAUSE_IR;
      EXIT2_IR         : if (tms_i) state_d = UPDATE_IR;        else state_d = SHIFT_IR;
      UPDATE_IR        : if (tms_i) state_d = SELECT_DR;        else state_d = RUN_TEST_IDLE;
      default          : state_d = TEST_LOGIC_RESET;
    endcase
  end

  always_ff @(posedge tck_i or negedge trst_ni) begin
    if (!trst_ni) state_q <= TEST_LOGIC_RESET;
    else          state_q <= state_d;
  end

  // ---- instruction register -------------------------------------------
  localparam logic [3:0] IR_BYPASS   = 4'b1111;
  localparam logic [3:0] IR_IDCODE   = 4'b0001;
  localparam logic [3:0] IR_DBG_ADDR = 4'b1000;   // private
  localparam logic [3:0] IR_DBG_DATA = 4'b1001;   // private

  logic [3:0] ir_shift_q, ir_q;

  always_ff @(posedge tck_i or negedge trst_ni) begin
    if (!trst_ni) begin
      ir_shift_q <= 4'b0;
      ir_q       <= IR_IDCODE;          // mandatory reset instruction
    end else begin
      unique case (state_q)
        TEST_LOGIC_RESET : ir_q       <= IR_IDCODE;
        CAPTURE_IR       : ir_shift_q <= 4'b0001;   // spec: LSBs = 01
        SHIFT_IR         : ir_shift_q <= {tdi_i, ir_shift_q[3:1]};
        UPDATE_IR        : ir_q       <= ir_shift_q;
        default          : ;
      endcase
    end
  end

  // ---- data registers ---------------------------------------------------
  logic        bypass_q;
  logic [31:0] idcode_q, addr_q, data_q;

  always_ff @(posedge tck_i or negedge trst_ni) begin
    if (!trst_ni) begin
      bypass_q <= 1'b0;
      idcode_q <= IdCode;
      addr_q   <= 32'b0;
      data_q   <= 32'b0;
    end else begin
      unique case (state_q)
        CAPTURE_DR : begin
          idcode_q <= IdCode;
          data_q   <= dbg_rdata_i;      // reads present the last result
          bypass_q <= 1'b0;
        end
        SHIFT_DR : begin
          unique case (ir_q)
            IR_IDCODE   : idcode_q <= {tdi_i, idcode_q[31:1]};
            IR_DBG_ADDR : addr_q   <= {tdi_i, addr_q[31:1]};
            IR_DBG_DATA : data_q   <= {tdi_i, data_q[31:1]};
            IR_BYPASS   : bypass_q <= tdi_i;
            default     : bypass_q <= tdi_i;
          endcase
        end
        default : ;
      endcase
    end
  end

  // ---- TDO --------------------------------------------------------------
  // While shifting the INSTRUCTION register, TDO presents the IR shift
  // register -- not a data register.  Selecting only among the DRs left
  // the instruction register unreadable, so a debugger could never scan
  // the IR back out and the mandatory Capture-IR ...01 pattern never
  // reached TDO.  Caught by tb_v2_jtag.
  logic tdo_dr;
  always_comb begin
    unique case (ir_q)
      IR_IDCODE   : tdo_dr = idcode_q[0];
      IR_DBG_ADDR : tdo_dr = addr_q[0];
      IR_DBG_DATA : tdo_dr = data_q[0];
      IR_BYPASS   : tdo_dr = bypass_q;
      default     : tdo_dr = bypass_q;
    endcase
  end

  always_comb begin
    if (state_q == SHIFT_IR) tdo_o = ir_shift_q[0];
    else                     tdo_o = tdo_dr;
  end
  // TDO is only driven while shifting, as the standard requires.
  assign tdo_oe_o = (state_q == SHIFT_DR) || (state_q == SHIFT_IR);

  // ---- debug bus request -------------------------------------------------
  // An UPDATE_DR on the data register issues the access: a write if the
  // scan carried data, a read otherwise.  One tck-domain pulse; the
  // consumer synchronises it into the core domain.
  assign dbg_addr_o  = addr_q;
  assign dbg_wdata_o = data_q;
  assign dbg_req_o   = (state_q == UPDATE_DR) &&
                       ((ir_q == IR_DBG_ADDR) || (ir_q == IR_DBG_DATA));
  assign dbg_we_o    = (state_q == UPDATE_DR) && (ir_q == IR_DBG_DATA);

endmodule
