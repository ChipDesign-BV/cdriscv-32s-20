// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- instruction decoder.
//
// Variant 1's decoder plus Zba, Zbb and Zbs.  Everything the base
// RV32IM_Zicsr_Zifencei decoder did is reproduced exactly, and the new
// extensions occupy encodings that variant 1 rejected as illegal.
//
// That is the verification property, and it is what tb_v2_decoder
// checks against the variant-1 decoder instantiated side by side:
//
//   * where variant 1 says legal, variant 2 must produce the identical
//     control word -- every field, not just the ALU operator
//   * where variant 1 says illegal, variant 2 may say legal only if the
//     encoding is one of the 27 new bitmanip ones
//
// Stated that way the extension cannot silently perturb the base ISA,
// which is the risk worth designing against: variant 1 is signed off,
// and a decoder that quietly changed one immediate would be found by
// nothing until a program misbehaved.
//
// Variant 1 is not edited and not imported.  Both packages define
// ALU_ADD and MD_MUL, so they cannot be imported into one scope; the
// shared constants are repeated in cdriscv_32s_20_pkg with identical
// encodings, which is what makes the comparison a comparison rather
// than a translation.
//
// Zbb's CLZ/CTZ/CPOP/SEXT.B/SEXT.H and Zbb's ZEXT.H are unary: they sit
// in OP-IMM (funct7 = 0110000) and OP (funct7 = 0000100) respectively
// and their rs2 field is an opcode extension, not a register.  rs2_used
// is therefore left low for them, which matters for hazard interlocks.
//
// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem.  No signoff gate is met in this
// repository -- see README.md.  NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_32s_20_decoder
  import cdriscv_32s_20_pkg::*;
#(
    parameter bit RV32M = 1'b1,
    parameter bit RV32B = 1'b1      // Zba + Zbb + Zbs
) (
    input  logic [31:0] instr_i,

    output logic [4:0]  rs1_addr_o,
    output logic [4:0]  rs2_addr_o,
    output logic [4:0]  rd_addr_o,
    output logic        rf_we_o,
    output logic        rs1_used_o,
    output logic        rs2_used_o,

    output alu_op_e     alu_op_o,
    output op_a_sel_e   op_a_sel_o,
    output op_b_sel_e   op_b_sel_o,
    output logic [31:0] imm_o,
    output wb_sel_e     wb_sel_o,

    output logic        md_req_o,
    output md_op_e      md_op_o,

    output logic        lsu_req_o,
    output logic        lsu_we_o,
    output logic [1:0]  lsu_size_o,
    output logic        lsu_sign_ext_o,

    output logic        branch_o,
    output logic        jump_o,
    output logic        jalr_o,

    output logic        csr_access_o,
    output csr_op_e     csr_op_o,
    output logic [11:0] csr_addr_o,
    output logic        csr_imm_o,

    output logic        ecall_o,
    output logic        ebreak_o,
    output logic        mret_o,
    output logic        wfi_o,
    output logic        fence_o,
    output logic        fencei_o,

    output logic        illegal_instr_o
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [4:0] rs2f;

  assign opcode = instr_i[6:0];
  assign funct3 = instr_i[14:12];
  assign funct7 = instr_i[31:25];
  assign rs2f   = instr_i[24:20];

  assign rs1_addr_o = instr_i[19:15];
  assign rs2_addr_o = instr_i[24:20];
  assign rd_addr_o  = instr_i[11:7];
  assign csr_addr_o = instr_i[31:20];

  // ------------------------------------------------------------------
  // Immediates
  // ------------------------------------------------------------------
  logic [31:0] imm_i_type, imm_s_type, imm_b_type, imm_u_type, imm_j_type, imm_z_type;

  assign imm_i_type = {{20{instr_i[31]}}, instr_i[31:20]};
  assign imm_s_type = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
  assign imm_b_type = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};
  assign imm_u_type = {instr_i[31:12], 12'b0};
  assign imm_j_type = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};
  assign imm_z_type = {27'b0, instr_i[19:15]};

  // ------------------------------------------------------------------
  // Main decode
  // ------------------------------------------------------------------
  always_comb begin
    rf_we_o        = 1'b0;
    rs1_used_o     = 1'b0;
    rs2_used_o     = 1'b0;
    alu_op_o       = ALU_ADD;
    op_a_sel_o     = OP_A_RS1;
    op_b_sel_o     = OP_B_IMM;
    imm_o          = imm_i_type;
    wb_sel_o       = WB_ALU;
    md_req_o       = 1'b0;
    md_op_o        = MD_MUL;
    lsu_req_o      = 1'b0;
    lsu_we_o       = 1'b0;
    lsu_size_o     = LS_WORD;
    lsu_sign_ext_o = 1'b0;
    branch_o       = 1'b0;
    jump_o         = 1'b0;
    jalr_o         = 1'b0;
    csr_access_o   = 1'b0;
    csr_op_o       = CSR_NONE;
    csr_imm_o      = 1'b0;
    ecall_o        = 1'b0;
    ebreak_o       = 1'b0;
    mret_o         = 1'b0;
    wfi_o          = 1'b0;
    fence_o        = 1'b0;
    fencei_o       = 1'b0;
    illegal_instr_o= 1'b0;

    // Compressed instructions are expanded upstream by
    // cdriscv_32s_20_if_align, so what arrives here is always 32 bits and
    // its low two bits are always 11.
    if (instr_i[1:0] != 2'b11) begin
      illegal_instr_o = 1'b1;
    end else begin
      unique case (opcode)

        OPCODE_LUI: begin
          rf_we_o    = 1'b1;
          op_a_sel_o = OP_A_ZERO;
          op_b_sel_o = OP_B_IMM;
          imm_o      = imm_u_type;
          alu_op_o   = ALU_PASSB;
        end

        OPCODE_AUIPC: begin
          rf_we_o    = 1'b1;
          op_a_sel_o = OP_A_PC;
          op_b_sel_o = OP_B_IMM;
          imm_o      = imm_u_type;
          alu_op_o   = ALU_ADD;
        end

        OPCODE_JAL: begin
          rf_we_o    = 1'b1;
          jump_o     = 1'b1;
          op_a_sel_o = OP_A_PC;
          op_b_sel_o = OP_B_FOUR;
          imm_o      = imm_j_type;
          alu_op_o   = ALU_ADD;
        end

        OPCODE_JALR: begin
          rs1_used_o = 1'b1;
          rf_we_o    = 1'b1;
          jump_o     = 1'b1;
          jalr_o     = 1'b1;
          op_a_sel_o = OP_A_PC;
          op_b_sel_o = OP_B_FOUR;
          imm_o      = imm_i_type;
          alu_op_o   = ALU_ADD;
          if (funct3 != 3'b000) illegal_instr_o = 1'b1;
        end

        OPCODE_BRANCH: begin
          rs1_used_o = 1'b1;
          rs2_used_o = 1'b1;
          branch_o   = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_RS2;
          imm_o      = imm_b_type;
          unique case (funct3)
            3'b000:  alu_op_o = ALU_EQ;
            3'b001:  alu_op_o = ALU_NE;
            3'b100:  alu_op_o = ALU_SLT;
            3'b101:  alu_op_o = ALU_GE;
            3'b110:  alu_op_o = ALU_SLTU;
            3'b111:  alu_op_o = ALU_GEU;
            default: illegal_instr_o = 1'b1;
          endcase
        end

        OPCODE_LOAD: begin
          rs1_used_o     = 1'b1;
          rf_we_o        = 1'b1;
          lsu_req_o      = 1'b1;
          lsu_we_o       = 1'b0;
          wb_sel_o       = WB_LSU;
          op_a_sel_o     = OP_A_RS1;
          op_b_sel_o     = OP_B_IMM;
          imm_o          = imm_i_type;
          alu_op_o       = ALU_ADD;
          lsu_size_o     = funct3[1:0];
          lsu_sign_ext_o = ~funct3[2];
          unique case (funct3)
            3'b000, 3'b001, 3'b010, 3'b100, 3'b101: ;
            default: illegal_instr_o = 1'b1;
          endcase
        end

        OPCODE_STORE: begin
          rs1_used_o = 1'b1;
          rs2_used_o = 1'b1;
          lsu_req_o  = 1'b1;
          lsu_we_o   = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_IMM;
          imm_o      = imm_s_type;
          alu_op_o   = ALU_ADD;
          lsu_size_o = funct3[1:0];
          unique case (funct3)
            3'b000, 3'b001, 3'b010: ;
            default: illegal_instr_o = 1'b1;
          endcase
        end

        // ----------------------------------------------------------
        // OP-IMM: base, plus Zbs immediate forms, Zbb rotate/unary
        // ----------------------------------------------------------
        OPCODE_OPIMM: begin
          rs1_used_o = 1'b1;
          rf_we_o    = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_IMM;
          imm_o      = imm_i_type;
          unique case (funct3)
            3'b000: alu_op_o = ALU_ADD;
            3'b010: alu_op_o = ALU_SLT;
            3'b011: alu_op_o = ALU_SLTU;
            3'b100: alu_op_o = ALU_XOR;
            3'b110: alu_op_o = ALU_OR;
            3'b111: alu_op_o = ALU_AND;

            3'b001: begin
              // SLLI, and the funct7=0110000 unary group, and BSETI /
              // BCLRI / BINVI.  The shift amount is always instr[24:20].
              imm_o = {27'b0, instr_i[24:20]};
              unique case (funct7)
                7'b0000000: alu_op_o = ALU_SLL;              // SLLI
                7'b0010100: begin                            // BSETI  (Zbs)
                  if (RV32B) alu_op_o = ALU_BSET;
                  else       illegal_instr_o = 1'b1;
                end
                7'b0100100: begin                            // BCLRI  (Zbs)
                  if (RV32B) alu_op_o = ALU_BCLR;
                  else       illegal_instr_o = 1'b1;
                end
                7'b0110100: begin                            // BINVI  (Zbs)
                  if (RV32B) alu_op_o = ALU_BINV;
                  else       illegal_instr_o = 1'b1;
                end
                7'b0110000: begin
                  // Unary Zbb: rs2 is an opcode extension, not a
                  // register, so rs2_used stays low.
                  if (!RV32B) illegal_instr_o = 1'b1;
                  else begin
                    unique case (rs2f)
                      5'b00000: alu_op_o = ALU_CLZ;
                      5'b00001: alu_op_o = ALU_CTZ;
                      5'b00010: alu_op_o = ALU_CPOP;
                      5'b00100: alu_op_o = ALU_SEXTB;
                      5'b00101: alu_op_o = ALU_SEXTH;
                      default:  illegal_instr_o = 1'b1;
                    endcase
                  end
                end
                default: illegal_instr_o = 1'b1;
              endcase
            end

            3'b101: begin
              // SRLI / SRAI / BEXTI / RORI / ORC.B / REV8
              imm_o = {27'b0, instr_i[24:20]};
              unique case (funct7)
                7'b0000000: alu_op_o = ALU_SRL;              // SRLI
                7'b0100000: alu_op_o = ALU_SRA;              // SRAI
                7'b0100100: begin                            // BEXTI  (Zbs)
                  if (RV32B) alu_op_o = ALU_BEXT;
                  else       illegal_instr_o = 1'b1;
                end
                7'b0110000: begin                            // RORI   (Zbb)
                  if (RV32B) alu_op_o = ALU_ROR;
                  else       illegal_instr_o = 1'b1;
                end
                7'b0010100: begin                            // ORC.B  (Zbb)
                  if (RV32B && (rs2f == 5'b00111)) alu_op_o = ALU_ORCB;
                  else illegal_instr_o = 1'b1;
                end
                7'b0110100: begin                            // REV8   (Zbb)
                  if (RV32B && (rs2f == 5'b11000)) alu_op_o = ALU_REV8;
                  else illegal_instr_o = 1'b1;
                end
                default: illegal_instr_o = 1'b1;
              endcase
            end

            default: illegal_instr_o = 1'b1;
          endcase
        end

        // ----------------------------------------------------------
        // OP: base, M, and the register-register bitmanip
        // ----------------------------------------------------------
        OPCODE_OP: begin
          rs1_used_o = 1'b1;
          rs2_used_o = 1'b1;
          rf_we_o    = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_RS2;

          if (funct7 == 7'b0000001) begin
            if (RV32M) begin
              md_req_o = 1'b1;
              md_op_o  = md_op_e'(funct3);
              wb_sel_o = WB_MD;
            end else begin
              illegal_instr_o = 1'b1;
            end
          end else begin
            unique case ({funct7, funct3})
              {7'b0000000, 3'b000}: alu_op_o = ALU_ADD;
              {7'b0100000, 3'b000}: alu_op_o = ALU_SUB;
              {7'b0000000, 3'b001}: alu_op_o = ALU_SLL;
              {7'b0000000, 3'b010}: alu_op_o = ALU_SLT;
              {7'b0000000, 3'b011}: alu_op_o = ALU_SLTU;
              {7'b0000000, 3'b100}: alu_op_o = ALU_XOR;
              {7'b0000000, 3'b101}: alu_op_o = ALU_SRL;
              {7'b0100000, 3'b101}: alu_op_o = ALU_SRA;
              {7'b0000000, 3'b110}: alu_op_o = ALU_OR;
              {7'b0000000, 3'b111}: alu_op_o = ALU_AND;

              // ---- Zba
              {7'b0010000, 3'b010}: if (RV32B) alu_op_o = ALU_SH1ADD;
                                    else illegal_instr_o = 1'b1;
              {7'b0010000, 3'b100}: if (RV32B) alu_op_o = ALU_SH2ADD;
                                    else illegal_instr_o = 1'b1;
              {7'b0010000, 3'b110}: if (RV32B) alu_op_o = ALU_SH3ADD;
                                    else illegal_instr_o = 1'b1;

              // ---- Zbb, register-register
              {7'b0100000, 3'b111}: if (RV32B) alu_op_o = ALU_ANDN;
                                    else illegal_instr_o = 1'b1;
              {7'b0100000, 3'b110}: if (RV32B) alu_op_o = ALU_ORN;
                                    else illegal_instr_o = 1'b1;
              {7'b0100000, 3'b100}: if (RV32B) alu_op_o = ALU_XNOR;
                                    else illegal_instr_o = 1'b1;
              {7'b0000101, 3'b110}: if (RV32B) alu_op_o = ALU_MAX;
                                    else illegal_instr_o = 1'b1;
              {7'b0000101, 3'b111}: if (RV32B) alu_op_o = ALU_MAXU;
                                    else illegal_instr_o = 1'b1;
              {7'b0000101, 3'b100}: if (RV32B) alu_op_o = ALU_MIN;
                                    else illegal_instr_o = 1'b1;
              {7'b0000101, 3'b101}: if (RV32B) alu_op_o = ALU_MINU;
                                    else illegal_instr_o = 1'b1;
              {7'b0110000, 3'b001}: if (RV32B) alu_op_o = ALU_ROL;
                                    else illegal_instr_o = 1'b1;
              {7'b0110000, 3'b101}: if (RV32B) alu_op_o = ALU_ROR;
                                    else illegal_instr_o = 1'b1;

              // ZEXT.H is OP with funct7 0000100 and rs2 = 0; the rest
              // of that funct7 is RV64's ADD.UW / packw family.
              {7'b0000100, 3'b100}: begin
                if (RV32B && (rs2f == 5'b00000)) begin
                  alu_op_o   = ALU_ZEXTH;
                  rs2_used_o = 1'b0;
                end else illegal_instr_o = 1'b1;
              end

              // ---- Zbs, register-register
              {7'b0010100, 3'b001}: if (RV32B) alu_op_o = ALU_BSET;
                                    else illegal_instr_o = 1'b1;
              {7'b0100100, 3'b001}: if (RV32B) alu_op_o = ALU_BCLR;
                                    else illegal_instr_o = 1'b1;
              {7'b0110100, 3'b001}: if (RV32B) alu_op_o = ALU_BINV;
                                    else illegal_instr_o = 1'b1;
              {7'b0100100, 3'b101}: if (RV32B) alu_op_o = ALU_BEXT;
                                    else illegal_instr_o = 1'b1;

              default:              illegal_instr_o = 1'b1;
            endcase
          end
        end

        OPCODE_MISCMEM: begin
          unique case (funct3)
            3'b000:  fence_o  = 1'b1;
            3'b001:  fencei_o = 1'b1;
            default: illegal_instr_o = 1'b1;
          endcase
        end

        OPCODE_SYSTEM: begin
          if (funct3 == 3'b000) begin
            unique case (instr_i[31:7])
              25'b0000000_00000_00000_000_00000: ecall_o  = 1'b1;
              25'b0000000_00001_00000_000_00000: ebreak_o = 1'b1;
              25'b0011000_00010_00000_000_00000: mret_o   = 1'b1;
              25'b0001000_00101_00000_000_00000: wfi_o    = 1'b1;
              default: illegal_instr_o = 1'b1;
            endcase
          end else begin
            csr_access_o = 1'b1;
            rf_we_o      = 1'b1;
            wb_sel_o     = WB_CSR;
            csr_imm_o    = funct3[2];
            rs1_used_o   = ~funct3[2];
            imm_o        = imm_z_type;
            unique case (funct3[1:0])
              2'b01:   csr_op_o = CSR_RW;
              2'b10:   csr_op_o = CSR_RS;
              2'b11:   csr_op_o = CSR_RC;
              default: illegal_instr_o = 1'b1;
            endcase
          end
        end

        default: illegal_instr_o = 1'b1;
      endcase
    end

    // An illegal instruction must not have any architectural effect.
    if (illegal_instr_o) begin
      rf_we_o      = 1'b0;
      lsu_req_o    = 1'b0;
      md_req_o     = 1'b0;
      branch_o     = 1'b0;
      jump_o       = 1'b0;
      csr_access_o = 1'b0;
      csr_op_o     = CSR_NONE;
      ecall_o      = 1'b0;
      ebreak_o     = 1'b0;
      mret_o       = 1'b0;
      wfi_o        = 1'b0;
      fence_o      = 1'b0;
      fencei_o     = 1'b0;
    end
  end

endmodule

`default_nettype wire
