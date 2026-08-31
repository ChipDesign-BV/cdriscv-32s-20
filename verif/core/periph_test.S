/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Peripheral and interrupt test.
 *
 * Covers what nothing else reaches: the CLINT (machine timer and
 * software interrupt at the standard map, 0x0200_0000), the APB timer
 * re-routed through the interrupt controller as source 16, the
 * interrupt controller, all three interrupt causes, WFI, the watchdog
 * and the memory BIST.  Before this test the core had never taken an
 * interrupt at all -- see the coverage baseline in
 * verification_findings.md.
 *
 * MTIP and MSIP are owned by the CLINT now.  The APB timer at slot 2
 * keeps its registers but its irq is an ordinary peripheral source and
 * must arrive as the external interrupt; the irq_ctrl's own MSIP
 * register (0x0c) no longer reaches the core and is not tested.
 *
 * Each failing check writes its own number to the exit register.
 *
 * Register discipline: interrupts arrive asynchronously, so anything
 * that must survive one lives in an s register.  The handler touches
 * only t3..t6 and s2.
 */

    .equ SAFETY_BASE, 0x20000000
    .equ WDOG_BASE,   0x20000100
    .equ TIMER_BASE,  0x20000200
    .equ MBIST_BASE,  0x20000500
    .equ IRQC_BASE,   0x20000600
    .equ EXIT_REG,    0x20000f00

    /* CLINT, standard layout.  The 64 KB window's offsets are too big
     * for a 12-bit immediate, so each register block gets its own base.
     */
    .equ CLINT_MSIP,  0x02000000
    .equ CLINT_CMP,   0x02004000    /* lo at +0, hi at +4 */
    .equ CLINT_TIME,  0x0200bff8    /* lo at +0, hi at +4 */

    .equ MTIMECMP_LO, 0x08
    .equ MTIMECMP_HI, 0x0c
    .equ TMR_CTRL,    0x10

    .equ IRQC_ENABLE, 0x04
    .equ IRQC_CLAIM,  0x08
    .equ IRQC_MODE,   0x10

    .equ WD_CTRL,     0x00
    .equ WD_PERIOD,   0x04
    .equ WD_SERVICE,  0x0c
    .equ WD_STATUS,   0x10

    .equ MB_D_CTRL,   0x40
    .equ MB_D_STATUS, 0x44

    .equ KEY_A,       0xa5a55a5a
    .equ KEY_B,       0x5a5aa5a5

    .equ MIE_MSIE,    0x008
    .equ MIE_MTIE,    0x080
    .equ MIE_MEIE,    0x800
    .equ MSTATUS_MIE, 0x008

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
    la   t0, trap_handler
    csrw mtvec, t0
    csrw mie, zero
    li   s2, 0                  /* interrupt flags set by the handler */
    li   s0, SAFETY_BASE
    li   s1, TIMER_BASE
    li   s3, IRQC_BASE
    li   s7, CLINT_CMP
    li   s8, CLINT_TIME

    /* ---- 1: machine timer interrupt (CLINT) ------------------------
     * mtime free-runs from reset (prescaler resets to 0 = one tick per
     * cycle), so the deadline is relative to a read of mtime, not to
     * zero.  Write order hi-then-lo: with hi=0 and lo still at reset's
     * all-ones the comparator stays above mtime, so nothing fires
     * between the two halves.
     */
    sw   zero, 4(s7)            /* mtimecmp hi */
    lw   t0, 0(s8)              /* current mtime low */
    addi t0, t0, 200
    sw   t0, 0(s7)              /* mtimecmp lo: deadline armed */

    li   t0, MIE_MTIE
    csrw mie, t0
    li   t0, MSTATUS_MIE
    csrs mstatus, t0

    li   s4, 0
1:  andi t0, s2, 1
    bnez t0, 2f
    addi s4, s4, 1
    li   t1, 20000
    blt  s4, t1, 1b
    li   a0, 1
    j    fail                   /* the timer interrupt never arrived */
2:

    /* ---- 2: WFI wakes on an interrupt ------------------------------ */
    andi s2, s2, ~1             /* clear the timer flag before arming */
    sw   zero, 4(s7)            /* hi=0; lo is all-ones from the handler */
    lw   t0, 0(s8)
    addi t0, t0, 100
    sw   t0, 0(s7)
    wfi
    andi t0, s2, 1
    li   a0, 2
    beqz t0, fail               /* WFI returned without the interrupt */

    /* ---- 3: external interrupt through the interrupt controller ---- */
    li   t0, -1
    sw   t0, 4(s7)              /* silence the CLINT: hi first, so the */
    sw   t0, 0(s7)              /* comparator is never below mtime     */

    li   t0, 1
    sw   t0, IRQC_ENABLE(s3)    /* source 0 = safety controller */
    sw   zero, IRQC_MODE(s3)    /* level sensitive */

    li   t0, MIE_MEIE
    csrw mie, t0

    csrwi 0x7c1, 2              /* software fault -> safety irq */

    li   s4, 0
3:  andi t0, s2, 2
    bnez t0, 4f
    addi s4, s4, 1
    li   t1, 20000
    blt  s4, t1, 3b
    li   a0, 3
    j    fail
4:

    /* ---- 4: APB timer as interrupt controller source 16 ------------
     * The slot-2 timer keeps its registers but no longer drives MTIP;
     * its irq must arrive as the external interrupt instead.  Same
     * hi-then-lo arming as the CLINT: its mtime also free-runs from
     * reset.
     */
    li   t0, 0x10000
    sw   t0, IRQC_ENABLE(s3)    /* source 16 only */
    sw   zero, IRQC_MODE(s3)    /* level sensitive */

    sw   zero, MTIMECMP_HI(s1)
    lw   t0, 0(s1)              /* current mtime low */
    addi t0, t0, 200
    sw   t0, MTIMECMP_LO(s1)
    li   t0, 1
    sw   t0, TMR_CTRL(s1)       /* counter enable (reset default, kept explicit) */

    li   s4, 0
5:  andi t0, s2, 8
    bnez t0, 6f
    addi s4, s4, 1
    li   t1, 20000
    blt  s4, t1, 5b
    li   a0, 4
    j    fail                   /* the re-routed timer irq never arrived */
6:
    sw   zero, IRQC_ENABLE(s3)  /* done with the controller */

    /* ---- 5: software interrupt (CLINT msip) ------------------------ */
    li   t0, MIE_MSIE
    csrw mie, t0
    li   t1, CLINT_MSIP
    li   t0, 1
    sw   t0, 0(t1)              /* msip is CLINT-owned now, not the irq_ctrl's */

    li   s4, 0
7:  andi t0, s2, 4
    bnez t0, 8f
    addi s4, s4, 1
    li   t1, 20000
    blt  s4, t1, 7b
    li   a0, 5
    j    fail
8:
    csrw mie, zero              /* interrupts off for the rest */
    li   t0, MSTATUS_MIE
    csrc mstatus, t0
    li   t0, -1
    sw   t0, 0(s0)              /* clear the safety status */

    /* ---- 6: watchdog services correctly ---------------------------- */
    li   s5, WDOG_BASE
    li   t0, 3000
    sw   t0, WD_PERIOD(s5)
    li   t0, 1                  /* enable, no window, no reset request */
    sw   t0, WD_CTRL(s5)

    li   s4, 0
9:  li   t0, KEY_A              /* service: two step key */
    sw   t0, WD_SERVICE(s5)
    li   t0, KEY_B
    sw   t0, WD_SERVICE(s5)
    addi s4, s4, 1
    li   t1, 8
    blt  s4, t1, 9b

    lw   t0, 0(s0)              /* safety status: the watchdog bit is 6 */
    srli t0, t0, 6
    andi t0, t0, 1
    li   a0, 6
    bnez t0, fail               /* a correctly serviced watchdog must be quiet */

    /* ---- 7: watchdog times out when it is not serviced -------------- */
    li   t0, 200
    sw   t0, WD_PERIOD(s5)      /* short period, restarts the counter */

    li   s4, 0
10: addi s4, s4, 1
    li   t1, 4000
    blt  s4, t1, 10b

    lw   t0, 0(s0)
    srli t0, t0, 6
    andi t0, t0, 1
    li   a0, 7
    beqz t0, fail               /* it should have fired by now */

    sw   zero, WD_CTRL(s5)      /* disable it again */
    li   t0, -1
    sw   t0, 0(s0)

    /* ---- 8: memory BIST over the D-TCM ------------------------------
     * Destructive, and it blocks the D-TCM while it runs -- but this
     * loop only touches peripherals and the I-TCM, so the core keeps
     * running.  Nothing below uses the D-TCM.
     */
    li   s6, MBIST_BASE
    li   t0, 1
    sw   t0, MB_D_CTRL(s6)      /* start */

    li   s4, 0
11: lw   t0, MB_D_STATUS(s6)
    andi t1, t0, 2              /* done */
    bnez t1, 12f
    addi s4, s4, 1
    li   t1, 200000
    blt  s4, t1, 11b
    li   a0, 8
    j    fail                   /* BIST never finished */
12:
    andi t1, t0, 4              /* fail */
    li   a0, 9
    bnez t1, fail               /* a good memory must not report a failure */

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
13: j    13b

fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
14: j    14b

    /* ------------------------------------------------------------------
     * Trap handler.  Interrupts set a bit in s2 and silence their
     * source; exceptions skip the faulting instruction.
     * ------------------------------------------------------------------ */
    .align 2                     /* mtvec BASE is bits [31:2] */
trap_handler:
    csrr t6, mcause
    bltz t6, irq_path           /* mcause[31] set => interrupt */

    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

irq_path:
    andi t5, t6, 0x1f
    li   t4, 7
    beq  t5, t4, irq_timer
    li   t4, 11
    beq  t5, t4, irq_ext
    li   t4, 3
    beq  t5, t4, irq_soft
    mret                        /* unexpected cause: ignore */

irq_timer:
    li   t4, CLINT_CMP
    li   t3, -1
    sw   t3, 4(t4)              /* hi first: never transiently below mtime */
    sw   t3, 0(t4)
    ori  s2, s2, 1
    mret

irq_ext:                        /* one cause, two owners: ask CLAIM which */
    li   t4, IRQC_BASE
    lw   t3, IRQC_CLAIM(t4)
    li   t5, 16
    beq  t3, t5, irq_ext_tmr
    li   t4, SAFETY_BASE
    li   t3, -1
    sw   t3, 0(t4)              /* clear the sticky status, drops the irq */
    ori  s2, s2, 2
    mret
irq_ext_tmr:
    li   t4, TIMER_BASE
    li   t3, -1
    sw   t3, MTIMECMP_LO(t4)
    sw   t3, MTIMECMP_HI(t4)    /* level source: move the compare away */
    ori  s2, s2, 8
    mret

irq_soft:
    li   t4, CLINT_MSIP
    sw   zero, 0(t4)            /* msip lives in the CLINT now */
    ori  s2, s2, 4
    mret

    .section .data
    .align 4
pad:
    .word 0

    .section .bss
    .align 4
_stack_bottom:
    .space 512
_stack_top:
