// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- JTAG debug bus clock-domain bridge.
//
// cdriscv_32s_20_jtag_tap drives a small request/response bus entirely in
// the tck domain.  Anything it reaches lives in the system domain.  This
// block is the crossing.
//
// It is a closed-loop toggle handshake in both directions, built from the
// same cdriscv_32s_20_pulse_sync the clock monitor uses:
//
//   tck : accept a request, latch addr/wdata/we, toggle, go busy
//   clk : the toggle arrives as a one-cycle strobe -> perform the access,
//         register the read data, then toggle back
//   tck : the return toggle arrives -> capture the read data, clear busy
//
// Two properties follow, and both matter:
//
//   * No assumption about the tck:clk ratio.  The address and write data
//     are written in the tck domain *before* the request toggle is sent,
//     and are held until the acknowledge comes back, so they are static
//     for the whole time the destination could sample them.  The read
//     data is symmetric.  This is why the bridge does not need the usual
//     "TCK must be slower than the core clock" rule -- a rule which is
//     easy to state, easy to violate on a bench, and impossible to check
//     in silicon.
//
//   * A request arriving while the previous one is outstanding is
//     dropped, not queued.  The TAP cannot in fact produce one -- a full
//     DR scan separates any two UPDATE_DR events -- but a dropped request
//     is a stalled debugger, whereas an overwritten one is a debugger
//     reading somebody else's address.
//
// The system side is a single-cycle strobe with combinational read data,
// which is what cdriscv_32s_20_dbg_win presents.  It is deliberately not
// an APB master: this bridge reaches an observation window, not the
// system bus.  See cdriscv_32s_20_dbg_win for what that costs.

// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem.  No signoff gate is met in this
// repository -- see README.md.  NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_32s_20_dbg_bridge #(
    parameter int unsigned Stages = 2
) (
    // ---- TAP side, tck domain --------------------------------------
    input  wire         tck_i,
    input  wire         trst_ni,
    input  wire  [31:0] dbg_addr_i,
    input  wire  [31:0] dbg_wdata_i,
    input  wire         dbg_req_i,
    input  wire         dbg_we_i,
    output logic [31:0] dbg_rdata_o,
    output logic        dbg_busy_o,

    // ---- system side, clk domain -----------------------------------
    input  wire         clk_i,
    input  wire         rst_ni,
    output logic        acc_o,
    output logic [31:0] acc_addr_o,
    output logic [31:0] acc_wdata_o,
    output logic        acc_we_o,
    input  wire  [31:0] acc_rdata_i
);

  // ---- tck domain: request capture --------------------------------

  logic        busy_q;
  logic [31:0] addr_q, wdata_q;
  logic        we_q;

  logic        req_accept;
  logic        ack_tck;

  assign req_accept = dbg_req_i && !busy_q;

  always_ff @(posedge tck_i or negedge trst_ni) begin
    if (!trst_ni) begin
      busy_q  <= 1'b0;
      addr_q  <= 32'h0;
      wdata_q <= 32'h0;
      we_q    <= 1'b0;
    end else begin
      if (req_accept) begin
        // Written before the toggle is sent and held until the
        // acknowledge returns -- this is what makes the crossing
        // ratio-independent.
        addr_q  <= dbg_addr_i;
        wdata_q <= dbg_wdata_i;
        we_q    <= dbg_we_i;
        busy_q  <= 1'b1;
      end else if (ack_tck) begin
        busy_q  <= 1'b0;
      end
    end
  end

  assign dbg_busy_o = busy_q;

  // ---- tck -> clk: the request ------------------------------------

  logic acc_strobe;

  cdriscv_32s_20_pulse_sync #(.Stages(Stages)) u_req_sync (
      .src_clk_i   (tck_i),
      .src_rst_ni  (trst_ni),
      .src_pulse_i (req_accept),
      .dst_clk_i   (clk_i),
      .dst_rst_ni  (rst_ni),
      .dst_pulse_o (acc_strobe)
  );

  assign acc_o       = acc_strobe;
  assign acc_addr_o  = addr_q;
  assign acc_wdata_o = wdata_q;
  assign acc_we_o    = we_q;

  // ---- clk domain: perform the access, then acknowledge ------------

  logic [31:0] rdata_q;
  logic        ack_pulse;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_q   <= 32'h0;
      ack_pulse <= 1'b0;
    end else begin
      if (acc_strobe) rdata_q <= acc_rdata_i;
      // One cycle behind the strobe, so rdata_q is already settled when
      // the acknowledge starts its way back.
      ack_pulse <= acc_strobe;
    end
  end

  // ---- clk -> tck: the acknowledge ---------------------------------

  cdriscv_32s_20_pulse_sync #(.Stages(Stages)) u_ack_sync (
      .src_clk_i   (clk_i),
      .src_rst_ni  (rst_ni),
      .src_pulse_i (ack_pulse),
      .dst_clk_i   (tck_i),
      .dst_rst_ni  (trst_ni),
      .dst_pulse_o (ack_tck)
  );

  always_ff @(posedge tck_i or negedge trst_ni) begin
    if (!trst_ni)     dbg_rdata_o <= 32'h0;
    else if (ack_tck) dbg_rdata_o <= rdata_q;   // static since before ack
  end

endmodule

`default_nettype wire
