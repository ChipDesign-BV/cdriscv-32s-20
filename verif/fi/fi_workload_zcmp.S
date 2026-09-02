/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Fault injection workload F: Zcmp sequences, as dense as they come.
 *
 * The Zcmp sequencer is new state inside the core: a step counter
 * (seq_idx_q), a beat-pending flag, and the held 16-bit encoding the
 * step table decodes (the fetch buffer word, held for the whole
 * sequence).  A mid-sequence upset in any of these changes which
 * registers are stored or loaded, or where -- and because the bench
 * injects into ONE core only (u_core_main), the checker core walks the
 * intact sequence and every corrupted beat is a compare mismatch on
 * the delayed output vector.  Lockstep is the mechanism under test
 * here; this workload's job is to keep the core inside ST_SEQ for as
 * many cycles as possible so the injection window mostly lands
 * mid-sequence.
 *
 * Every iteration: load 13 registers with values derived from the
 * running state, cm.push {ra, s0-s11} (13 stores + sp add), scramble,
 * cm.pop the frame back, fold everything into the checksum, plus both
 * register-pair moves.  A popret pair exercises the return arm.
 */

    .equ EXIT_REG,   0x20000f00
    .equ SCRATCH,    0x10000800

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

    li   t3, 0                  /* checksum accumulates in t3 across the
                                 * cm.* frames, since s-registers are
                                 * clobbered by design here */
    li   t4, 40                 /* iterations */
    li   t5, 0x12345            /* running value */

loop:
    /* populate the whole saved set from the running value */
    addi t5, t5, 7
    mv   ra, t5
    slli s0, t5, 1
    slli s1, t5, 2
    xor  s2, t5, s0
    add  s3, t5, s1
    sub  s4, s0, s1
    or   s5, s2, s3
    and  s6, s4, t5
    addi s7, t5, 17
    slli s8, s7, 3
    xor  s9, s8, s2
    add  s10, s9, s0
    sub  s11, s10, s1

    /* the widest push: 13 memory beats plus the sp adjust */
    cm.push {ra, s0-s11}, -64

    /* scramble the live copies so the pop is observable */
    li   s0, -1
    li   s5, -1
    li   s11, -1
    mv   ra, zero

    /* both register-pair moves, mid-frame */
    cm.mva01s s2, s7
    add  t3, t3, a0
    add  t3, t3, a1
    addi a0, a0, 5
    addi a1, a1, 9
    cm.mvsa01 s4, s6

    /* the widest pop */
    cm.pop {ra, s0-s11}, 64

    /* fold the restored registers: any beat that loaded the wrong
     * value, or from the wrong slot, lands in the checksum */
    add  t3, t3, ra
    add  t3, t3, s0
    xor  t3, t3, s1
    add  t3, t3, s2
    xor  t3, t3, s3
    add  t3, t3, s4
    add  t3, t3, s5
    xor  t3, t3, s6
    add  t3, t3, s7
    add  t3, t3, s8
    xor  t3, t3, s9
    add  t3, t3, s10
    add  t3, t3, s11

    /* a call whose return path is a cm.popret */
    jal  ra, leaf

    addi t4, t4, -1
    bnez t4, loop

    li   t0, EXIT_REG
    sw   t3, 0(t0)
3:  j    3b

    /* popret: pop the frame and return through the restored ra */
leaf:
    cm.push {ra, s0-s2}, -16
    addi s0, t5, 3
    add  t3, t3, s0
    cm.popret {ra, s0-s2}, 16

    .align 2
trap_handler:
    /* this workload takes no traps; any trap is a fault detection by
     * the workload itself */
    li   t0, EXIT_REG
    li   t1, 0xdead0000
    csrr t2, mcause
    or   t1, t1, t2
    sw   t1, 0(t0)
4:  j    4b

    .section .data
    .align 4
pad: .word 0
    .section .bss
    .align 4
_stack_bottom: .space 512
_stack_top:
