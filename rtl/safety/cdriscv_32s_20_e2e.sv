// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- end-to-end (E2E) bus protection.
//
// The TCMs in variant 1 are ECC-protected *inside* the memory: a word
// is encoded on the way in and checked on the way out, so a fault in
// the array is caught.  What is NOT covered is everything between the
// core and the array -- address decode, bus muxing, the interconnect
// itself.  A fault there delivers the wrong word, correctly ECC'd, and
// nothing notices.
//
// E2E closes that by carrying the check bits with the payload from
// producer to consumer, so the consumer verifies what it received
// rather than trusting that the path was sound.  This module is the
// generator/checker pair; the bus carries e2e_word_t instead of raw
// data.
//
// Address is folded into the check: the same data at the wrong address
// must NOT pass.  That is what makes this end-to-end rather than merely
// a second data ECC -- a decode fault changes the address, which
// changes the expected syndrome, which the consumer sees as an error.
//
// Reuses the (39,32) Hsiao code the TCMs already use, so the same
// generator, the same proof and the same block-level bench apply.
//
// STATUS: block-verified but NOT instantiated by the subsystem.
// What stops it is integration ripple, not the block -- see
// doc/variant_status.md, section 3.  NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_32s_20_e2e_gen (
    input  logic [31:0] data_i,
    input  logic [31:0] addr_i,
    output logic [6:0]  chk_o
);
  logic [6:0] data_chk;
  logic [31:0] cw_unused;
  cdriscv_32s_20_ecc_enc u_enc (.data_i(data_i), .cw_o({data_chk, cw_unused}));

  // Fold the address in: a transfer that arrives at the wrong address
  // carries a syndrome that no longer matches.
  //
  // The obvious fold -- XOR the address in 7-bit slices -- is WRONG, and
  // measurably so.  It maps address bits i and i+7 onto the same check
  // bit, so flipping both cancels exactly; tb_v2_e2e measured 11.1 % of
  // two-bit address faults escaping.  Two stuck address lines, or an MBU
  // in an address register, are precisely that case.
  //
  // The cure is to give every address bit a DISTINCT 7-bit column, so no
  // pair can cancel.  The (39,32) Hsiao matrix already has that property
  // by construction -- its columns are distinct and odd-weight -- and it
  // is already proven, so the address runs through the same encoder
  // rather than through a hand-rolled fold.
  logic [6:0]  addr_chk;
  logic [31:0] addr_cw_unused;
  cdriscv_32s_20_ecc_enc u_addr_enc (.data_i(addr_i), .cw_o({addr_chk, addr_cw_unused}));

  assign chk_o = data_chk ^ addr_chk;
endmodule


module cdriscv_32s_20_e2e_chk (
    input  logic [31:0] data_i,
    input  logic [31:0] addr_i,
    input  logic [6:0]  chk_i,
    output logic        err_o
);
  logic [6:0] expect_chk;
  cdriscv_32s_20_e2e_gen u_gen (.data_i(data_i), .addr_i(addr_i), .chk_o(expect_chk));
  assign err_o = (expect_chk != chk_i);
endmodule
