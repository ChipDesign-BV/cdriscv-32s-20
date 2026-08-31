/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * PMP directed test — proves the checker actually denies an access.
 *
 * The rest of the regression proves PMP does not fire: every region
 * resets to OFF, so the inherited tests pass unchanged.  That is
 * evidence of no regression and no evidence at all that the mechanism
 * works.  This test is the other half.
 *
 * The rule being exercised is the one that catches people out: in
 * machine mode a PMP entry is ignored unless its **lock** bit is set.
 * An unlocked entry with no permissions does not deny an M-mode access.
 * So the test checks both directions — programmed-but-unlocked must
 * still permit, locked-with-no-permission must deny — because a checker
 * that denied everything would pass a one-sided test.
 *
 * Region 0 covers `guarded` with NA4 (exactly 4 bytes, granularity is
 * one word).  Nothing else is touched, so code, stack and the exit
 * register stay reachable.
 *
 * Fetch is checked the same way and by the same M-mode rule (checks 14
 * onwards): region 1 covers one word of code, `exec_stub`, with NA4 --
 * programmed-but-unlocked must still execute, locked-with-X=0 must trap
 * cause 1 with mepc and mtval holding the denied instruction's PC.  The
 * stub sits at the end of .text so the region never covers code the
 * test itself needs, and the locked entry carries R=1 so a checker that
 * tests R instead of X is caught.  Region 2 (locked, no permissions)
 * covers a word the prefetcher runs into but execution jumps over: a
 * denied *prefetch* must be discarded by the redirect, not trapped.
 *
 * Each failing check writes its own number to the exit register.
 */

    .equ EXIT_REG,   0x20000f00

    .equ CAUSE_IFAULT,    1
    .equ CAUSE_LFAULT,    5
    .equ CAUSE_SFAULT,    7

    /* pmpcfg byte: L(7) 0 0 A(4:3) X(2) W(1) R(0) */
    .equ CFG_NA4_RW,     0x13     /* A=NA4, R=1, W=1, unlocked        */
    .equ CFG_NA4_NONE_L, 0x90     /* A=NA4, no permissions, LOCKED    */
    .equ CFG_NA4_RW_L,   0x93     /* A=NA4, R=1, W=1, X=0, LOCKED     */

    .section .text.init, "ax"
    .global _start
_start:
    la   sp, _stack_top
    la   t0, trap_handler
    csrw mtvec, t0
    li   s8, 0                    /* mcause from the handler          */
    li   s11, 0                   /* trap counter                     */

    /* ---- 1. baseline: the word is reachable before PMP ------------ */
    la   s0, guarded
    li   t1, 0x5a5a5a5a
    sw   t1, 0(s0)
    lw   t2, 0(s0)
    li   a0, 1
    bne  t2, t1, fail

    /* ---- 2. programmed but UNLOCKED must not bind machine mode ---- */
    srli t0, s0, 2                /* pmpaddr is the address >> 2      */
    csrw pmpaddr0, t0
    li   t0, CFG_NA4_RW
    csrw pmpcfg0, t0              /* full permissions, unlocked       */
    lw   t2, 0(s0)
    li   a0, 2
    bne  t2, t1, fail             /* still readable                   */
    li   a0, 3
    bne  s11, zero, fail          /* and no trap was taken            */

    /* Now remove the permissions but leave it unlocked.  M-mode must
       still be allowed: this is the case a naive checker gets wrong. */
    csrw pmpcfg0, zero
    li   t0, 0x10                 /* A=NA4, no R/W/X, still unlocked  */
    csrw pmpcfg0, t0
    lw   t2, 0(s0)
    li   a0, 4
    bne  t2, t1, fail
    li   a0, 5
    bne  s11, zero, fail

    /* ---- 3. LOCKED with no permission must deny a load ------------ */
    li   t0, CFG_NA4_NONE_L
    csrw pmpcfg0, t0
    la   s7, after_load           /* where the handler returns to     */
    lw   t2, 0(s0)                /* must trap                        */
after_load:
    li   a0, 6
    li   t0, 1
    bne  s11, t0, fail            /* exactly one trap                 */
    li   a0, 7
    li   t0, CAUSE_LFAULT
    bne  s8, t0, fail
    li   a0, 8
    bne  s9, s0, fail             /* mtval is the faulting address    */

    /* ---- 4. ...and a store ---------------------------------------- */
    la   s7, after_store
    sw   t1, 0(s0)                /* must trap                        */
after_store:
    li   a0, 9
    li   t0, 2
    bne  s11, t0, fail
    li   a0, 10
    li   t0, CAUSE_SFAULT
    bne  s8, t0, fail

    /* ---- 5. the lock survives a write attempt --------------------- */
    csrw pmpcfg0, zero            /* ignored: the entry is locked     */
    csrr t0, pmpcfg0
    andi t0, t0, 0xff
    li   a0, 11
    li   t1, CFG_NA4_NONE_L
    bne  t0, t1, fail

    /* ---- 6. a neighbouring word is unaffected --------------------- */
    la   s1, neighbour
    li   t1, 0x0badf00d
    la   s7, unreachable
    sw   t1, 0(s1)
    lw   t2, 0(s1)
    li   a0, 12
    bne  t2, t1, fail
    li   a0, 13
    li   t0, 2
    bne  s11, t0, fail            /* still exactly two traps          */

    /* ================= instruction fetch ========================= */

    /* ---- 7. programmed but UNLOCKED X=0 must not deny execution --- */
    /* The direction a deny-everything bug passes: same M-mode rule as
       check 2, now on the fetch side.  Region 1, NA4 over the first
       word of exec_stub, R/W but no X, unlocked. */
    la   s0, exec_stub
    srli t0, s0, 2
    csrw pmpaddr1, t0
    li   t0, (CFG_NA4_RW << 8)
    csrw pmpcfg0, t0              /* byte 0 locked: write ignored     */
    li   s2, 0
    jalr ra, s0, 0                /* must execute */
    li   a0, 14
    li   t0, 1
    bne  s2, t0, fail             /* the stub ran                     */
    li   a0, 15
    li   t0, 2
    bne  s11, t0, fail            /* and no trap was taken            */

    /* ---- 8. LOCKED X=0 must deny execution ------------------------ */
    /* R stays 1 so a fetch checker that tests R instead of X is
       caught: only X may deny here. */
    li   t0, (CFG_NA4_RW_L << 8)
    csrw pmpcfg0, t0
    la   s7, after_exec           /* where the handler returns to     */
    li   s2, 0
    jalr ra, s0, 0                /* must trap on the stub's first word */
after_exec:
    li   a0, 16
    li   t0, 3
    bne  s11, t0, fail            /* exactly one more trap            */
    li   a0, 17
    li   t0, CAUSE_IFAULT
    bne  s8, t0, fail             /* cause 1: instruction access fault */
    li   a0, 18
    bne  s9, s0, fail             /* mtval = PC of the denied instr   */
    li   a0, 19
    bne  s10, s0, fail            /* mepc  = PC of the denied instr   */
    li   a0, 20
    bne  s2, zero, fail           /* the stub did not execute         */

    /* ...and the same word still LOADS fine: X and R are independent */
    lw   t2, 0(s0)
    li   a0, 21
    li   t0, 3
    bne  s11, t0, fail            /* no trap on the read              */

    /* ---- 9. a denied PREFETCH never executed must not trap -------- */
    /* Region 2, locked, no permissions, over a word placed straight
       after a taken branch: the prefetcher runs into it (two-entry
       run-ahead over an always-granting TCM), execution never does.
       The injected fetch fault must die in the redirect flush.

       The fence.i matters: without it the prefetcher has fetched
       dead_word BEFORE the csrw locking region 2 retires, no fetch is
       ever denied, and this check tests nothing (found by a surviving
       mutant).  The flush forces a refetch under the new rules, and
       the fetcher is then inside dead_word while `j` drains through
       the aligner. */
    la   s1, dead_word
    srli t0, s1, 2
    csrw pmpaddr2, t0
    li   t0, (CFG_NA4_NONE_L << 16)
    csrw pmpcfg0, t0              /* bytes 0,1 locked: writes ignored */
    .option push
    .option norvc
    .balign 4                     /* word-align the block so dead_word
                                     directly abuts the taken branch  */
    fence.i                       /* refetch everything after this    */
    j    prefetch_skip            /* taken; the fetcher is already in
                                     dead_word when this redirects    */
    .balign 4
dead_word:
    .word 0x00000013              /* nop, never executed              */
prefetch_skip:
    .option pop
    li   a0, 22
    li   t0, 3
    bne  s11, t0, fail            /* still exactly three traps        */

    /* ---- 10. the locked entries survived it all ------------------- */
    csrr t0, pmpcfg0
    li   t1, (CFG_NA4_NONE_L << 16) | (CFG_NA4_RW_L << 8) | CFG_NA4_NONE_L
    li   a0, 23
    bne  t0, t1, fail

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
1:  j    1b

unreachable:
fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
2:  j    2b

    /* The stub one word of which region 1 covers.  norvc so the first
       instruction fills the guarded word exactly; the `ret` lives in
       the next, always-executable word. */
    .balign 4
    .option push
    .option norvc
exec_stub:
    li   s2, 1
    ret
    .option pop

    .align 2                     /* mtvec BASE is bits [31:2] */
trap_handler:
    csrr s8, mcause
    csrr s9, mtval
    csrr s10, mepc               /* before it is overwritten below    */
    addi s11, s11, 1
    csrw mepc, s7
    mret

    .section .data
    .align 4
guarded:
    .word 0
neighbour:
    .word 0

    .section .bss
    .align 4
_stack_bottom:
    .space 512
_stack_top:
