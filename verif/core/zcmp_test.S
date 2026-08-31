/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Zcmp directed test.
 *
 * The co-simulation proves every cm.* sequence against Spike; this test
 * proves the pieces Spike cannot see from a clean run:
 *
 *   - the push/pop round trip and the exact memory image of a frame
 *   - cm.popret / cm.popretz through real (and nested) call frames
 *   - both register-move forms
 *   - ONE retirement per sequence (minstret arithmetic)
 *   - a cm.push storing into a PMP-denied word traps with mcause 7,
 *     mtval = the denied address, mepc = the cm instruction's PC,
 *     sp UNCHANGED (the sp write is the sequence's last step) and the
 *     protected word untouched (the denied beat never reached the bus)
 *   - a cm.push with a misaligned sp traps with mcause 6, same mepc
 *     and sp rules
 *   - an interrupt raised while a sequence is running is taken only at
 *     an instruction boundary: a CLINT timer deadline is swept across
 *     a cm.pop cycle by cycle, and whenever the handler sees
 *     mepc = the cm PC the sequence must NOT have started (the first
 *     destination register still holds its poison) -- mepc = the cm PC
 *     with a partially executed sequence is exactly the fault a
 *     mid-sequence interrupt would produce.
 *
 * Register budget: the sequences own ra, sp, a0, a1, s0-s11, so this
 * test keeps its own state in t-registers, gp (handler redirect
 * target), and tp (trap record base in the D-TCM).  The handler
 * clobbers only t5/t6.
 *
 * Each failing check writes its own number to the exit register.
 */

    .equ EXIT_REG,   0x20000f00
    .equ CLINT_CMP,  0x02004000
    .equ CLINT_TIME, 0x0200bff8

    .equ CAUSE_SMISALIGN, 6
    .equ CAUSE_SFAULT,    7

    /* pmpcfg byte: L(7) 0 0 A(4:3) X(2) W(1) R(0) */
    .equ CFG_NA4_R_L, 0x91        /* A=NA4, R=1 W=0 X=0, LOCKED: a store
                                     is denied, the checking load is not */

    .section .text.init, "ax"
    .global _start
_start:
    li  x1, 0
    li  x2, 0
    li  x3, 0
    li  x4, 0
    li  x5, 0
    li  x6, 0
    li  x7, 0
    li  x8, 0
    li  x9, 0
    li  x10, 0
    li  x11, 0
    li  x12, 0
    li  x13, 0
    li  x14, 0
    li  x15, 0
    li  x16, 0
    li  x17, 0
    li  x18, 0
    li  x19, 0
    li  x20, 0
    li  x21, 0
    li  x22, 0
    li  x23, 0
    li  x24, 0
    li  x25, 0
    li  x26, 0
    li  x27, 0
    li  x28, 0
    li  x29, 0
    li  x30, 0
    li  x31, 0

    la   sp, _stack_top
    la   tp, trap_rec
    li   gp, 0
    la   t0, trap_handler
    csrw mtvec, t0
    csrw mie, zero

/* --- 1..3: full-list round trip, sp arithmetic --------------------- */
    mv   t3, sp                  /* sp0 */
    li   ra, 0x11110001
    li   s0, 0x22220002
    li   s1, 0x33330003
    li   s2, 0x44440004
    li   s3, 0x55550005
    li   s4, 0x66660006
    li   s5, 0x77770007
    li   s6, 0x88880008
    li   s7, 0x99990009
    li   s8, 0xaaaa000a
    li   s9, 0xbbbb000b
    li   s10, 0xcccc000c
    li   s11, 0xdddd000d

    cm.push {ra, s0-s11}, -64
    li   a0, 1
    addi t4, t3, -64
    bne  sp, t4, fail            /* sp moved by exactly the adjustment */

    li   ra, 0
    li   s0, 0
    li   s5, 0
    li   s11, 0
    cm.pop {ra, s0-s11}, 64
    li   a0, 2
    bne  sp, t3, fail            /* sp restored */

    li   a0, 3
    li   t0, 0x11110001
    bne  ra, t0, fail
    li   t0, 0x22220002
    bne  s0, t0, fail
    li   t0, 0x77770007
    bne  s5, t0, fail
    li   t0, 0xdddd000d
    bne  s11, t0, fail

/* --- 4: the frame's exact memory image ----------------------------- */
    /* {ra, s0-s2}, adj 32 (spimm 1): s2 at sp0-4, s1 at sp0-8,
       s0 at sp0-12, ra at sp0-16, [sp0-32, sp0-16) untouched */
    li   t0, 0xa5a5a5a5          /* canary below the register block */
    sw   t0, -20(sp)
    sw   t0, -32(sp)
    cm.push {ra, s0-s2}, -32
    li   a0, 4
    lw   t1, 28(sp)              /* sp0-4 = sp+32-4 */
    li   t0, 0x44440004
    bne  t1, t0, fail
    lw   t1, 24(sp)
    li   t0, 0x33330003
    bne  t1, t0, fail
    lw   t1, 20(sp)
    li   t0, 0x22220002
    bne  t1, t0, fail
    lw   t1, 16(sp)
    li   t0, 0x11110001
    bne  t1, t0, fail
    li   a0, 5
    lw   t1, 12(sp)              /* the extra adjustment is not stored to */
    li   t0, 0xa5a5a5a5
    bne  t1, t0, fail
    lw   t1, 0(sp)
    bne  t1, t0, fail
    cm.pop {ra, s0-s2}, 32

/* --- 6: one retirement for the whole sequence ---------------------- */
    /* two identical instruction pairs bracket minstret; the pair with
       the cm.push between them must count exactly ONE more.  A core
       that retired per micro-step would count 14 more. */
    csrr t0, minstret
    csrr t1, minstret
    sub  t2, t1, t0              /* the pair's own cost */
    csrr t0, minstret
    cm.push {ra, s0-s11}, -112
    csrr t1, minstret
    sub  t1, t1, t0
    sub  t1, t1, t2              /* minus the pair cost = the cm alone */
    li   a0, 6
    li   t0, 1
    bne  t1, t0, fail
    cm.pop {ra, s0-s11}, 112

/* --- 7: popret / popretz through call frames, nested --------------- */
    li   a0, 7
    li   s0, 0x22220002          /* will be clobbered and restored */
    jal  ra, f_outer
    li   a0, 7
    li   t0, 0x600dc0de
    bne  t1, t0, fail            /* inner function really ran */
    li   t0, 0x22220002
    bne  s0, t0, fail            /* nested frames restored */
    li   a0, 8
    li   t0, 0x0f00d001
    bne  t2, t0, fail            /* outer body after the call ran */

    li   a0, 0x12345678
    jal  ra, f_zero
    mv   t5, a0                  /* a0 must have been zeroed by the  */
    li   a0, 9                   /* cm.popretz before it returned    */
    bnez t5, fail

/* --- 10..11: the moves --------------------------------------------- */
    li   s3, 0x0000f00d
    li   s4, 0x0000beef
    cm.mva01s s3, s4
    li   t0, 0x0000f00d
    bne  a0, t0, 1f
    li   t0, 0x0000beef
    bne  a1, t0, 1f
    j    2f
1:  li   a0, 10
    j    fail
2:
    li   a0, 0x000cafe0
    li   a1, 0x000d00d0
    cm.mvsa01 s5, s6
    li   t0, 0x000cafe0
    bne  s5, t0, 1f
    li   t0, 0x000d00d0
    bne  s6, t0, 1f
    j    2f
1:  li   a0, 11
    j    fail
2:
    li   s0, 0x31313131          /* equal fields: legal for mva01s */
    cm.mva01s s0, s0
    li   t0, 0x31313131
    bne  a0, t0, 1f
    bne  a1, t0, 1f
    j    2f
1:  li   a0, 12
    j    fail
2:

/* --- 13: interrupt lands only at a sequence boundary ---------------
   A frame of known values is kept on the stack; each iteration arms
   the CLINT timer K cycles ahead, poisons s11 (the FIRST register the
   pop loads), runs cm.pop, and rebuilds the frame.  The handler
   records mepc and s11-at-trap.  If mepc is the cm PC the sequence
   must not have started: s11 still poison.  A core that trapped
   mid-sequence would present mepc = cm PC with s11 already loaded. */
    li   ra, 0x11110001          /* the frame the sweep replays */
    li   s0, 0x22220002
    li   s11, 0xdddd000d
    cm.push {ra, s0-s11}, -64

    li   t0, 2                   /* K */
    li   t1, 42                  /* K limit */
irq_sweep:
    sw   zero, 8(tp)             /* clear recorded mepc              */
    li   t2, CLINT_CMP
    li   t4, -1
    sw   t4, 4(t2)               /* comparator far away: hi all-ones */
    li   t4, CLINT_TIME
    lw   t4, 0(t4)               /* mtime lo                         */
    add  t4, t4, t0
    sw   t4, 0(t2)               /* cmp lo = mtime + K               */
    sw   zero, 4(t2)             /* cmp hi = 0: deadline armed       */
    li   t2, 0x80                /* MTIE */
    csrw mie, t2
    csrsi mstatus, 8             /* MIE on */
    li   s11, 0                  /* poison the first-loaded register */
Lz: cm.pop {ra, s0-s11}, 64
    csrci mstatus, 8
    csrw mie, zero

    li   a0, 13
    li   t2, 0xdddd000d
    bne  s11, t2, fail           /* the pop always completes by here */

    lw   t2, 8(tp)               /* recorded mepc (0 if no trap)     */
    la   t4, Lz
    bne  t2, t4, 1f
    /* trapped with mepc = the cm PC: legal only BEFORE the first
       step -- s11 at the trap must still be poison */
    lw   t4, 16(tp)
    li   a0, 14
    bnez t4, fail
1:
    cm.push {ra, s0-s11}, -64    /* rebuild the frame, sp back down  */
    addi t0, t0, 1
    ble  t0, t1, irq_sweep

    addi sp, sp, 64              /* drop the sweep frame             */
    li   a0, 15
    lw   t2, 20(tp)              /* the timer must actually have hit */
    li   t3, 5
    blt  t2, t3, fail

/* --- 16..19: PMP-denied store inside a cm.push --------------------- */
    sw   zero, 20(tp)            /* reuse the counter for exceptions */
    la   t3, guard
    li   t0, 0x0defaced
    sw   t0, 0(t3)               /* seed BEFORE the lock             */
    srli t0, t3, 2
    csrw pmpaddr0, t0
    li   t0, CFG_NA4_R_L         /* locked, readable, NOT writable   */
    csrw pmpcfg0, t0

    mv   t4, sp                  /* keep the real stack pointer      */
    addi sp, t3, 8               /* 2nd store of the push hits guard */
    li   ra, 0x11110001
    li   s0, 0x22220002
    li   s1, 0x33330003
    li   s2, 0x44440004
    la   gp, r16                 /* handler redirect                 */
    mv   t2, sp                  /* sp expected at the trap          */
Lpmp: cm.push {ra, s0-s2}, -16
    li   a0, 16                  /* must not fall through untrapped  */
    j    fail
r16:
    li   gp, 0
    li   a0, 17
    lw   t0, 0(tp)               /* mcause = store access fault      */
    li   t1, CAUSE_SFAULT
    bne  t0, t1, fail
    lw   t0, 4(tp)               /* mtval = the denied word          */
    bne  t0, t3, fail
    li   a0, 18
    lw   t0, 8(tp)               /* mepc = the cm instruction's PC   */
    la   t1, Lpmp
    bne  t0, t1, fail
    bne  sp, t2, fail            /* sp untouched: write-sp-last      */
    lw   t0, 12(tp)              /* ...already at the trap itself    */
    bne  t0, t2, fail
    li   a0, 19
    lw   t0, 0(t3)               /* denied beat never reached memory */
    li   t1, 0x0defaced
    bne  t0, t1, fail
    mv   sp, t4

/* --- 20: misaligned sp inside a cm.push ---------------------------- */
    mv   t4, sp
    addi sp, sp, -2              /* halfword-misaligned stack        */
    la   gp, r20
    mv   t2, sp
Lmis: cm.push {ra}, -16
    li   a0, 20
    j    fail
r20:
    li   gp, 0
    li   a0, 21
    lw   t0, 0(tp)               /* mcause = store misaligned        */
    li   t1, CAUSE_SMISALIGN
    bne  t0, t1, fail
    lw   t0, 4(tp)               /* mtval = the misaligned address   */
    addi t1, t2, -4
    bne  t0, t1, fail
    li   a0, 22
    lw   t0, 8(tp)               /* mepc = the cm PC                 */
    la   t1, Lmis
    bne  t0, t1, fail
    bne  sp, t2, fail            /* sp untouched                     */
    mv   sp, t4

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
1:  j    1b

fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
2:  j    2b

/* Outer frame saves {ra, s0-s3}; inner saves {ra, s0-s1}.  Both
   deliberately clobber what they saved. */
f_outer:
    cm.push {ra, s0-s3}, -32
    li   s0, 0x0bad0000
    li   s1, 0x0bad0001
    jal  ra, f_inner
    li   t2, 0x0f00d001
    cm.popret {ra, s0-s3}, 32

f_inner:
    cm.push {ra, s0-s1}, -16
    li   s0, 0x0bad0002
    li   t1, 0x600dc0de
    cm.popret {ra, s0-s1}, 16

f_zero:
    cm.push {ra}, -16
    cm.popretz {ra}, 16

    .align 2
trap_handler:
    csrr t5, mcause
    sw   t5, 0(tp)
    csrr t6, mtval
    sw   t6, 4(tp)
    csrr t6, mepc
    sw   t6, 8(tp)
    sw   sp, 12(tp)
    sw   s11, 16(tp)
    lw   t6, 20(tp)
    addi t6, t6, 1
    sw   t6, 20(tp)
    bgez t5, 1f
    /* interrupt: push the comparator far away (hi = all ones) so the
       level MTIP drops and the mret does not re-trap */
    li   t5, CLINT_CMP
    li   t6, -1
    sw   t6, 4(t5)
    j    2f
1:  beqz gp, 2f                  /* exception: redirect if armed     */
    csrw mepc, gp
2:  mret

    .section .data
    .align 4
trap_rec:
    .word 0, 0, 0, 0, 0, 0       /* mcause mtval mepc sp s11 count  */
    .align 4
guard_below:
    .word 0
guard:
    .word 0
guard_above:
    .word 0, 0, 0, 0

    .section .bss
    .align 4
_stack_bottom:
    .space 512
_stack_top:
