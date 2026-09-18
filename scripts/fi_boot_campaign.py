#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# QSPI boot loader fault injection campaign (finding 22).
#
# The loader is the one FMEDA row carried on an argument rather than a
# measurement (doc/fmeda.md section 5): tb_fi builds the subsystem with
# BootEnable=0, so no campaign ever injected into its 534 flops.  This
# drives verif/fi/tb_fi_boot.sv over every bit of every loader register,
# at several points of the load and once after boot_done, and classifies
# by what the loader DELIVERED -- not by the exit code.
#
# What is hashed is the delivered IMAGE -- a shadow of the memory, last
# write wins -- not the sequence of write beats.  Hashing the beats made a
# RETRY look like a corruption: a flipped CRC bit fails the check, the
# loader re-reads and re-delivers, and the beat count doubles while the
# image is perfect.  That is the mechanism working.
#
# The classes, and why each is what it is:
#   safe        image delivered bit-for-bit, run clean, nothing latched
#   detected    a safety mechanism reported: boot_fault, err_pin, or a
#               safety-controller status bit
#   fail-stop   boot never completed and the core was never released --
#               no mechanism fired because none had to: the part does not
#               run at all, which is the fail-silent behaviour SM13 is for
#   SDC         boot_done raised with a delivery hash different from the
#               fault-free one and NOTHING reported.  This is the class the
#               loader row's argument could not bound, and the only one
#               that matters to SPFM.
#   crashed     wrong image, nothing latched, but the program never
#               reached its exit -- dangerous yet self-evident
import argparse, collections, concurrent.futures, os, random, re, subprocess, sys

RE = re.compile(r"FIBOOT target=(\d+) bit=(\d+) cycle=(\d+) inj=(\d+) done=(\d) "
                r"fault=(\d) errpin=(\d) resetreq=(\d) exit=([0-9a-fx]+) exited=(\d+) "
                r"retires=(\d+) hash=([0-9a-fx]+) nwr=(\d+) status=([0-9a-fx]+) oob=(\d+)")

# id: (name, bits)  -- bits as the bench decodes them
TARGETS = {
    0:  ("state_q (FSM)",                3),
    1:  ("phase_q (SPI phase)",          3),
    2:  ("cur_addr_q (TCM write ptr)",  32),
    3:  ("wr_addr_q (bus address)",     32),
    4:  ("wr_data_q (bus data)",        32),
    5:  ("seg_left_q (segment count)",  24),
    6:  ("bytes_left_q (cmd count)",    24),
    7:  ("crc_q (running CRC32)",       32),
    8:  ("word_q (payload assembly)",   24),
    9:  ("tx_q (shift out)",            32),
    10: ("rx_q (shift in)",              7),
    11: ("hdr_q (28-byte header)",      32),   # sampled across 224 bits
    12: ("retries_q",                    4),
    13: ("wdog_q (progress watchdog)",  32),
    14: ("small counters",               5),
    15: ("single-bit flags",             8),
}

def classify(m, gold_hash, gold_nwr):
    inj, done, fault, errpin = m[3], m[4], m[5], m[6]
    exited, exit_v, h, nwr, status = m[9], m[8], m[11], m[12], m[13]
    if inj == "0":                                   return "not-injected"
    reported = (fault == "1" or errpin == "1" or int(status, 16) != 0)
    if reported:                                     return "detected"
    if done == "0":                                  return "fail-stop"
    if int(m[14]) != 0:                              return "SDC"   # wrote outside both TCMs
    if h == gold_hash and nwr == gold_nwr:
        if exited == "1" and int(exit_v, 16) == 0:   return "safe"
        return "crashed"                             # image fine, run not
    return "SDC" if (exited == "1" and int(exit_v, 16) == 0) else "crashed"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vvp", default="build/tb_fi_boot.vvp")
    ap.add_argument("--flash", default="build/boot_flash_quad.hex")
    ap.add_argument("--max-cycles", type=int, default=60000)
    ap.add_argument("--load-cycles", type=int, default=3427,
                    help="cycle at which the fault-free boot completes")
    ap.add_argument("--during", type=int, default=4,
                    help="injection points inside the load, per bit")
    ap.add_argument("--after", type=int, default=2,
                    help="injection points after boot_done, per bit")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--jobs", type=int, default=(os.cpu_count() or 4))
    ap.add_argument("--out", default="build/fi_campaign_boot.txt")
    a = ap.parse_args()
    rng = random.Random(a.seed)

    def run(args):
        t, b, c = args
        try:
            r = subprocess.run(["vvp", a.vvp, "+FLASH_HEX=" + a.flash,
                                "+MAX_CYCLES=%d" % a.max_cycles,
                                "+TARGET=%d" % t, "+BIT=%d" % b, "+CYCLE=%d" % c],
                               capture_output=True, text=True, timeout=900)
        except subprocess.TimeoutExpired:
            return (t, b, c, None)
        m = None
        for line in r.stdout.splitlines():
            m = RE.search(line) or m
        return (t, b, c, m.groups() if m else None)

    # the fault-free reference, from the same binary and image
    _, _, _, gold = run((99, 0, 10 ** 9))
    if not gold:
        sys.exit("fault-free reference produced no verdict line")
    gold_hash, gold_nwr = gold[11], gold[12]

    faults = []
    for t, (_, nb) in TARGETS.items():
        for b in range(nb):
            for _ in range(a.during):
                faults.append((t, b, rng.randrange(30, a.load_cycles)))
            for _ in range(a.after):
                # the mission window is short by construction: the smoke
                # program retires 127 instructions and exits, so an
                # injection scheduled far past boot_done would never land
                # and would quietly count as "not injected"
                faults.append((t, b, rng.randrange(a.load_cycles + 5,
                                                   a.load_cycles + 110)))
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as pool:
        res = list(pool.map(run, faults))

    cls = collections.Counter()
    by_t = collections.defaultdict(collections.Counter)
    phase = collections.defaultdict(collections.Counter)
    sdc = []
    for t, b, c, m in res:
        if m is None:
            cls["sim-timeout"] += 1; by_t[t]["sim-timeout"] += 1; continue
        k = classify(m, gold_hash, gold_nwr)
        cls[k] += 1; by_t[t][k] += 1
        phase["during" if c < a.load_cycles else "after"][k] += 1
        if k == "SDC":
            sdc.append((t, b, c, m[11], m[12]))

    out = []
    P = out.append
    P("QSPI boot loader fault injection: %d single event upsets" % sum(cls.values()))
    P("Bench: %s on %s; fault-free delivery hash %s over %s write beats"
      % (a.vvp, a.flash, gold_hash, gold_nwr))
    P("Injection points: %d inside the load (cycles 30..%d) and %d after boot_done, per bit\n"
      % (a.during, a.load_cycles, a.after))
    tot = sum(v for k, v in cls.items() if k != "not-injected")
    if cls["not-injected"]:
        P("  WARNING: %d of %d runs never injected -- excluded from the rates\n"
          % (cls["not-injected"], sum(cls.values())))
    for k in ("safe", "detected", "fail-stop", "crashed", "SDC", "sim-timeout",
              "not-injected"):
        if cls[k]:
            P("  %-12s %5d  %5.1f %%" % (k, cls[k], 100.0 * cls[k] / tot))
    P("\nBy register:")
    P("  %-30s %6s %9s %10s %8s %6s" % ("register", "safe", "detected", "fail-stop",
                                        "crashed", "SDC"))
    for t in sorted(by_t):
        n = TARGETS.get(t, ("?", 0))[0]
        c = by_t[t]
        P("  %-30s %6d %9d %10d %8d %6d"
          % (n, c["safe"], c["detected"], c["fail-stop"], c["crashed"], c["SDC"]))
    P("\nBy injection window:")
    for w in ("during", "after"):
        c = phase[w]
        s = sum(v for k, v in c.items() if k != "not-injected")
        if s:
            P("  %-8s %d upsets: %s" % (w, s, ", ".join(
                "%s %d (%.1f %%)" % (k, v, 100.0 * v / s)
                for k, v in sorted(c.items()) if k != "not-injected")))
    if sdc:
        P("\nSILENT DATA CORRUPTION -- boot_done with a wrong image and nothing reported:")
        for t, b, c, h, nw in sdc[:40]:
            P("  target %2d %-28s bit %3d at cycle %5d: hash %s (%s beats)"
              % (t, TARGETS.get(t, ("?",))[0], b, c, h, nw))
    txt = "\n".join(out) + "\n"
    open(a.out, "w").write(txt)
    print(txt)

if __name__ == "__main__":
    main()
