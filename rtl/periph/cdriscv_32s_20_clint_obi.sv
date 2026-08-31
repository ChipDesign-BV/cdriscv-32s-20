// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- CLINT bus adapter.
//
// cdriscv_32s_20_clint is a combinational slave: present an offset, get
// data in the same cycle.  cdriscv_32s_20_bus speaks the OBI-like
// req/gnt/rvalid protocol the TCMs use.  This is the join.
//
// It is a separate module rather than four lines inside the subsystem
// because the CLINT's own block bench drives the combinational
// interface, and widening that interface would invalidate it.  The
// adapter is what gets verified against the bus protocol instead.
//
// Always ready (gnt = req), response one cycle later.  The CLINT has no
// internal wait states -- mtime is a counter, not a memory -- so a
// deeper handshake would add latency for nothing.
//
// addr_i is 16 bits, not 32, on purpose.  Which 64 KB window this block
// answers in is the bus's decode to make, and it makes it; taking a full
// address here and ignoring the top half would leave two places that
// believe they own the base address and no check that they agree.
//
// Sub-word accesses are rejected, not widened.  The bus carries byte
// enables but a 64-bit counter has no defined behaviour for a byte
// write: performing it as a word write would corrupt the other three
// bytes, and dropping it silently would lose the write.  Both are worse
// than an error the core can trap on.
//
// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem.  No signoff gate is met in this
// repository -- see README.md.  NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_32s_20_clint_obi (
    input  wire         clk_i,
    input  wire         rst_ni,

    // bus side
    input  wire         req_i,
    output logic        gnt_o,
    output logic        rvalid_o,
    input  wire         we_i,
    input  wire  [3:0]  be_i,
    input  wire  [15:0] addr_i,      // offset within the window, not a full address
    input  wire  [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        err_o,

    // CLINT side
    output logic        clint_req_o,
    output logic        clint_we_o,
    output logic [15:0] clint_addr_o,
    output logic [31:0] clint_wdata_o,
    input  wire  [31:0] clint_rdata_i,
    input  wire         clint_err_i
);

  logic subword;
  assign subword = (be_i != 4'b1111);

  // A rejected access must not reach the CLINT at all: a byte write that
  // got through would be performed as a full word.
  assign clint_req_o   = req_i && !subword;
  assign clint_we_o    = we_i;
  assign clint_addr_o  = addr_i;
  assign clint_wdata_o = wdata_i;

  assign gnt_o = req_i;

  logic        rvalid_q, err_q;
  logic [31:0] rdata_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= 32'h0;
      err_q    <= 1'b0;
    end else begin
      rvalid_q <= req_i;
      if (req_i) begin
        rdata_q <= subword ? 32'h0 : clint_rdata_i;
        err_q   <= subword || clint_err_i;
      end
    end
  end

  assign rvalid_o = rvalid_q;
  assign rdata_o  = rdata_q;
  assign err_o    = err_q;

endmodule

`default_nettype wire
