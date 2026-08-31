// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-20 -- shared types, encodings and constants.
//
// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem.  No signoff gate is met in this
// repository -- see README.md.  NOT qualified for safety-critical use.

package cdriscv_32s_20_pkg;

  // ------------------------------------------------------------------
  // Machine parameters
  // ------------------------------------------------------------------
  localparam int unsigned XLEN = 32;

  // ------------------------------------------------------------------
  // RISC-V major opcodes (instr[6:0])
  // ------------------------------------------------------------------
  localparam logic [6:0] OPCODE_LOAD    = 7'h03;
  localparam logic [6:0] OPCODE_MISCMEM = 7'h0f;
  localparam logic [6:0] OPCODE_OPIMM   = 7'h13;
  localparam logic [6:0] OPCODE_AUIPC   = 7'h17;
  localparam logic [6:0] OPCODE_STORE   = 7'h23;
  localparam logic [6:0] OPCODE_OP      = 7'h33;
  localparam logic [6:0] OPCODE_LUI     = 7'h37;
  localparam logic [6:0] OPCODE_BRANCH  = 7'h63;
  localparam logic [6:0] OPCODE_JALR    = 7'h67;
  localparam logic [6:0] OPCODE_JAL     = 7'h6f;
  localparam logic [6:0] OPCODE_SYSTEM  = 7'h73;

  // ------------------------------------------------------------------
  // ALU operations
  // ------------------------------------------------------------------
  // The base subsystem used a 4-bit operator with 15 encodings.  Zba,
  // Zbb and Zbs add 27 more, so the field is 6 bits wide here.  The base
  // encodings keep their original values, which is what lets the decoder
  // be compared field for field against the frozen reference in
  // verif/ref/ (see verif/block/tb_decoder_equiv.sv).
  typedef enum logic [5:0] {
    ALU_ADD   = 6'd0,  ALU_SUB   = 6'd1,  ALU_SLL  = 6'd2,
    ALU_SLT   = 6'd3,  ALU_SLTU  = 6'd4,  ALU_XOR  = 6'd5,
    ALU_SRL   = 6'd6,  ALU_SRA   = 6'd7,  ALU_OR   = 6'd8,
    ALU_AND   = 6'd9,  ALU_EQ    = 6'd10, ALU_NE   = 6'd11,
    ALU_GE    = 6'd12, ALU_GEU   = 6'd13, ALU_PASSB= 6'd14,

    // ---- Zba: address generation
    ALU_SH1ADD = 6'd16, ALU_SH2ADD = 6'd17, ALU_SH3ADD = 6'd18,

    // ---- Zbb: basic bit manipulation
    ALU_ANDN  = 6'd20, ALU_ORN   = 6'd21, ALU_XNOR  = 6'd22,
    ALU_CLZ   = 6'd23, ALU_CTZ   = 6'd24, ALU_CPOP  = 6'd25,
    ALU_MAX   = 6'd26, ALU_MAXU  = 6'd27, ALU_MIN   = 6'd28,
    ALU_MINU  = 6'd29, ALU_SEXTB = 6'd30, ALU_SEXTH = 6'd31,
    ALU_ZEXTH = 6'd32, ALU_ROL   = 6'd33, ALU_ROR   = 6'd34,
    ALU_ORCB  = 6'd35, ALU_REV8  = 6'd36,

    // ---- Zbs: single-bit
    ALU_BCLR  = 6'd40, ALU_BEXT  = 6'd41, ALU_BINV  = 6'd42,
    ALU_BSET  = 6'd43
  } alu_op_e;

  // ------------------------------------------------------------------
  // Operand selects
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    OP_A_RS1  = 2'd0,
    OP_A_PC   = 2'd1,
    OP_A_ZERO = 2'd2
  } op_a_sel_e;

  typedef enum logic [1:0] {
    OP_B_RS2  = 2'd0,
    OP_B_IMM  = 2'd1,
    OP_B_FOUR = 2'd2    // PC + 4 for JAL/JALR link
  } op_b_sel_e;

  typedef enum logic [1:0] {
    WB_ALU  = 2'd0,
    WB_LSU  = 2'd1,
    WB_CSR  = 2'd2,
    WB_MD   = 2'd3      // multiplier / divider
  } wb_sel_e;

  // ------------------------------------------------------------------
  // M-extension operations (funct3 of OP with funct7 == 0000001)
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {
    MD_MUL    = 3'b000,
    MD_MULH   = 3'b001,
    MD_MULHSU = 3'b010,
    MD_MULHU  = 3'b011,
    MD_DIV    = 3'b100,
    MD_DIVU   = 3'b101,
    MD_REM    = 3'b110,
    MD_REMU   = 3'b111
  } md_op_e;

  // ------------------------------------------------------------------
  // CSR access
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    CSR_NONE = 2'b00,
    CSR_RW   = 2'b01,
    CSR_RS   = 2'b10,
    CSR_RC   = 2'b11
  } csr_op_e;

  // Machine information / trap setup / trap handling
  localparam logic [11:0] CSR_MSTATUS    = 12'h300;
  localparam logic [11:0] CSR_MISA       = 12'h301;
  localparam logic [11:0] CSR_MIE        = 12'h304;
  localparam logic [11:0] CSR_MTVEC      = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH   = 12'h340;
  localparam logic [11:0] CSR_MEPC       = 12'h341;
  localparam logic [11:0] CSR_MCAUSE     = 12'h342;
  localparam logic [11:0] CSR_MTVAL      = 12'h343;
  localparam logic [11:0] CSR_MIP        = 12'h344;
  localparam logic [11:0] CSR_MCYCLE     = 12'hb00;
  localparam logic [11:0] CSR_MINSTRET   = 12'hb02;
  localparam logic [11:0] CSR_MCYCLEH    = 12'hb80;
  localparam logic [11:0] CSR_MINSTRETH  = 12'hb82;
  localparam logic [11:0] CSR_CYCLE      = 12'hc00;
  localparam logic [11:0] CSR_INSTRET    = 12'hc02;
  localparam logic [11:0] CSR_CYCLEH     = 12'hc80;
  localparam logic [11:0] CSR_INSTRETH   = 12'hc82;
  localparam logic [11:0] CSR_MVENDORID  = 12'hf11;
  localparam logic [11:0] CSR_MARCHID    = 12'hf12;
  localparam logic [11:0] CSR_MIMPID     = 12'hf13;
  localparam logic [11:0] CSR_MHARTID    = 12'hf14;

  // Custom (machine-mode, read/write) safety CSRs
  localparam logic [11:0] CSR_MSAFESTAT  = 12'h7c0;  // sticky core-local fault status
  localparam logic [11:0] CSR_MSAFECTRL  = 12'h7c1;  // core-local safety control

  // ------------------------------------------------------------------
  // Exception causes (mcause, interrupt bit cleared)
  // ------------------------------------------------------------------
  localparam logic [4:0] EXC_INSTR_MISALIGN = 5'd0;
  localparam logic [4:0] EXC_INSTR_FAULT    = 5'd1;
  localparam logic [4:0] EXC_ILLEGAL_INSTR  = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT     = 5'd3;
  localparam logic [4:0] EXC_LOAD_MISALIGN  = 5'd4;
  localparam logic [4:0] EXC_LOAD_FAULT     = 5'd5;
  localparam logic [4:0] EXC_STORE_MISALIGN = 5'd6;
  localparam logic [4:0] EXC_STORE_FAULT    = 5'd7;
  localparam logic [4:0] EXC_ECALL_M        = 5'd11;

  // Interrupt causes (mcause, interrupt bit set)
  localparam logic [4:0] IRQ_M_SOFT = 5'd3;
  localparam logic [4:0] IRQ_M_TIMER= 5'd7;
  localparam logic [4:0] IRQ_M_EXT  = 5'd11;

  // ------------------------------------------------------------------
  // Load/store size encoding (funct3[1:0])
  // ------------------------------------------------------------------
  localparam logic [1:0] LS_BYTE = 2'b00;
  localparam logic [1:0] LS_HALF = 2'b01;
  localparam logic [1:0] LS_WORD = 2'b10;

  // ------------------------------------------------------------------
  // Safety fault identifiers.
  //
  // Each fault source owns one bit in the safety controller status
  // register.  Bits [15:0] are IP-internal sources, bits [31:16] are
  // brought in from the SoC through fault_ext_i.
  // ------------------------------------------------------------------
  localparam int unsigned NUM_INT_FAULTS = 16;
  localparam int unsigned NUM_EXT_FAULTS = 16;
  localparam int unsigned NUM_FAULTS     = NUM_INT_FAULTS + NUM_EXT_FAULTS;

  localparam int unsigned FLT_LOCKSTEP     = 0;   // core comparator mismatch
  localparam int unsigned FLT_ITCM_ECC_COR = 1;   // corrected single-bit error, I-TCM
  localparam int unsigned FLT_ITCM_ECC_UNC = 2;   // uncorrectable error, I-TCM
  localparam int unsigned FLT_DTCM_ECC_COR = 3;   // corrected single-bit error, D-TCM
  localparam int unsigned FLT_DTCM_ECC_UNC = 4;   // uncorrectable error, D-TCM
  localparam int unsigned FLT_REGFILE_PAR  = 5;   // register file parity error
  localparam int unsigned FLT_WDOG         = 6;   // watchdog time-out / bad service
  localparam int unsigned FLT_CLKMON       = 7;   // clock loss / out-of-range
  localparam int unsigned FLT_BUS_ERR      = 8;   // decode error / access fault
  localparam int unsigned FLT_MBIST        = 9;   // start-up memory BIST failure
  localparam int unsigned FLT_AMS          = 10;  // analog supervisor flag
  localparam int unsigned FLT_SW           = 11;  // software-signalled fault
  localparam int unsigned FLT_CORE_TRAP    = 12;  // unexpected core exception
  localparam int unsigned FLT_CFG_PAR     = 13;  // configuration register parity
                                                 // error -- latched UNGATED, see
                                                 // cdriscv_32s_20_safety_ctrl
  localparam int unsigned FLT_E2E          = 14;  // end-to-end bus protection:
                                                 // payload/address mismatch on a
                                                 // TCM link (was the spare bit --
                                                 // taking it appends nothing and
                                                 // moves nothing)
  localparam int unsigned FLT_SELFTEST     = 15;  // fault-injection self test

  // ------------------------------------------------------------------
  // SECDED code parameters (Hsiao (39,32))
  // ------------------------------------------------------------------
  localparam int unsigned ECC_DATA_W = 32;
  localparam int unsigned ECC_PAR_W  = 7;
  localparam int unsigned ECC_CW_W   = ECC_DATA_W + ECC_PAR_W;

  // ------------------------------------------------------------------
  // PMP -- machine-mode physical memory protection
  // ------------------------------------------------------------------
  localparam int unsigned PMP_REGIONS = 8;

  localparam logic [11:0] CSR_PMPCFG0    = 12'h3a0;
  localparam logic [11:0] CSR_PMPCFG1    = 12'h3a1;
  localparam logic [11:0] CSR_PMPCFG2    = 12'h3a2;
  localparam logic [11:0] CSR_PMPCFG3    = 12'h3a3;
  localparam logic [11:0] CSR_PMPADDR0   = 12'h3b0;

  typedef enum logic [1:0] {
    PMP_OFF   = 2'b00,
    PMP_TOR   = 2'b01,
    PMP_NA4   = 2'b10,
    PMP_NAPOT = 2'b11
  } pmp_mode_e;

  typedef struct packed {
    logic       l;        // locked
    logic [1:0] rsv;
    pmp_mode_e  a;        // address matching mode
    logic       x, w, r;
  } pmp_cfg_t;

  typedef enum logic [1:0] {
    PMP_ACC_READ  = 2'd0,
    PMP_ACC_WRITE = 2'd1,
    PMP_ACC_EXEC  = 2'd2
  } pmp_access_e;

  // ------------------------------------------------------------------
  // End-to-end bus protection: a payload carried with its own check
  // bits, so a fault between producer and consumer is detected at the
  // consumer rather than trusted because the wires looked fine.
  // ------------------------------------------------------------------
  typedef struct packed {
    logic [31:0] data;
    logic [6:0]  chk;     // (39,32) Hsiao SEC-DED, as the TCMs use
  } e2e_word_t;

endpackage
