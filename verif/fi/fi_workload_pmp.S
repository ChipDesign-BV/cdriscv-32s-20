/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Fault injection workload E: PMP protection state under live denials.
 *
 * The PMP configuration arrays (pmpcfg_q / pmpaddr_q in each core's
 * CSR file) are NOT covered by the configuration parity guard -- the
 * CSR file's u_cfg_par folds mtvec only.  This workload exists to
 * measure what that costs.  It keeps a locked deny-all region live by
 * probing it every iteration and expecting the trap:
 *
 *   - an upset that DISARMS the region (clears L, clears A, grants a
 *     permission) makes the probe succeed in the corrupted core while
 *     the checker core still traps -> the cores diverge at the next
 *     bus access and lockstep must catch it;
 *   - an upset that EXTENDS a denial (moves the region over the
 *     scratch area or the code) makes the corrupted core trap where
 *     the checker does not -> same divergence, other direction;
 *   - an upset in a region this workload never exercises changes
 *     nothing in either core's behaviour.  Nothing catches it: PMP
 *     has no parity, so it can only classify as LATENT.  That number
 *     is the finding, not a nuisance.
 *
 * The trap count is folded into the checksum (weighted), so even a
 * missed divergence would surface as SDC rather than silent-ok.
 *
 * Region 0: NA4, locked, no permissions, over `guard` in the D-TCM.
 * In machine mode only a LOCKED entry binds, which is why the lock bit
 * is the single most safety-critical bit in the array.
 */

    .equ EXIT_REG,   0x20000f00
    .equ SCRATCH,    0x10000800
    .equ GUARD,      0x10000f80
    .equ SAFETY,     0x20000000
    .equ SFT_ENABLE, 0x04
    .equ CFG_NA4_NONE_L, 0x90     /* A=NA4, no permissions, LOCKED */
    .equ CAUSE_LFAULT,   5

    .section .text.init, "ax"
    .global _start
_start:
    li  x1,0
    li  x2,0
    li  x3,0
    li  x4,0
    li  x5,0
    li  x6,0
    li  x7,0
    li  x8,0
    li  x9,0
    li  x10,0
    li  x11,0
    li  x12,0
    li  x13,0
    li  x14,0
    li  x15,0
    li  x16,0
    li  x17,0
    li  x18,0
    li  x19,0
    li  x20,0
    li  x21,0
    li  x22,0
    li  x23,0
    li  x24,0
    li  x25,0
    li  x26,0
    li  x27,0
    li  x28,0
    li  x29,0
    li  x30,0
    li  x31,0
    la  sp, _stack_top
    la  t0, trap_handler
    csrw mtvec, t0
    csrw mie, zero

    /* A PMP denial reports through the safety controller's BUS-ERROR
     * event (same EXC_*_FAULT causes -- doc/variant_status.md), so 64
     * deliberate denials would latch STATUS bit 8 on every run and
     * every injection would read "detected".  Mask exactly that source;
     * lockstep, parity, ECC and the rest stay armed, and lockstep is
     * the mechanism this campaign measures. */
    li   t0, SAFETY
    li   t1, 0xfffffeff
    sw   t1, SFT_ENABLE(t0)

    /* region 0: locked, no permissions, over the guard word */
    li   t0, GUARD
    srli t0, t0, 2
    csrw pmpaddr0, t0
    li   t0, CFG_NA4_NONE_L
    csrw pmpcfg0, t0

    li   s0, SCRATCH
    li   s1, 0                  /* checksum */
    li   s2, 64                 /* iterations */
    li   s3, 0x12345            /* running value */
    li   s7, 0                  /* denials taken */

loop:
    /* arithmetic, same texture as workload A */
    addi s3, s3, 7
    slli t0, s3, 3
    xor  t0, t0, s3
    srli t1, t0, 5
    add  s1, s1, t1
    mul  t2, s3, s2
    add  s1, s1, t2
    xor  s1, s1, t2

    /* the probe: must be denied, every iteration.  t6 keeps the load
     * out of the compressed encodings so the handler can step mepc by
     * exactly 4. */
    li   t5, GUARD
    lw   t6, 0(t5)
    /* if the load *succeeded*, a fault has disarmed the region in this
     * core; fold a poison so the checksum cannot survive it even if
     * everything else somehow lines up */
    li   t4, 0x0badf00d
    add  s1, s1, t4

resume:
    /* allowed traffic right next to the guarded word: this is what a
     * region-extending upset denies */
    sw   s1, 0(s0)
    lw   t6, 0(s0)
    add  s1, s1, t6

    addi s2, s2, -1
    bnez s2, loop

    /* weight the denial count so one lost trap cannot cancel */
    slli t0, s7, 11
    add  s1, s1, t0
    add  s1, s1, s7

    li   t0, EXIT_REG
    sw   s1, 0(t0)
3:  j    3b

    .align 2
trap_handler:
    csrr s8, mcause
    li   s9, CAUSE_LFAULT
    bne  s8, s9, bad_trap
    addi s7, s7, 1
    csrr s10, mepc              /* folded: where the denial hit matters */
    add  s1, s1, s10
    la   s10, resume            /* resume past the probe and its poison
                                 * fold -- an absolute target, so this
                                 * does not care how the assembler sized
                                 * the instructions in between */
    csrw mepc, s10
    mret

    /* any other cause: a fault pushed the core somewhere this workload
     * does not go -- report it as the workload's own detection */
bad_trap:
    li   s9, EXIT_REG
    li   s10, 0xdead0000
    or   s10, s10, s8
    sw   s10, 0(s9)
4:  j    4b

    .section .data
    .align 4
pad: .word 0
    .section .bss
    .align 4
_stack_bottom: .space 512
_stack_top:
