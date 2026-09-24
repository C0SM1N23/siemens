"""Cycle model of the PIC, checked against a trace written by pic_tb_random.

The model is written from the register and behaviour tables of the PIC design
specification: pending logic for level, edge and software requests, the
priority key {band urgency, intra-band priority, lowest index}, registered
offers, claim and EOI on a sixteen-deep nesting stack, spurious claims, deadline
counters and both escalation modes, the depth limit, and every register's write
rule (byte strobes, reserved bits, keyed triggers, NEST_MAX clamping, W1C with
hardware priority). It shares no code with the RTL.

Each trace line holds the inputs the controller sampled at one clock edge and
its state before that edge. The model starts from the reset state, compares its
own state with every line, then applies that line's inputs.

    python pic_model.py pic_random.trace [more traces...]
"""

import sys

NSRC, MAXNEST = 16, 16
SW_KEY = 0xA5A5
CFG_MASK, ESC_MASK = 0xFFFF00F7, 0x113
W_BAND, W_NEST_MAX, W_SPUR_LOG, W_ESC, W_INT_EN, W_INT_ST = 48, 50, 52, 53, 54, 55

FIELDS = ["irq_src", "cpu_mask", "ack", "eoi", "reg_wr", "reg_waddr", "reg_wdata", "reg_wstrb",
          "cpu_irq", "cpu_irq_vec", "pending", "depth", "active", "spurious", "spurious_log",
          "int_status", "escalated", "sw_pend", "edge_pend", "int_enable", "band_cfg", "nest_max",
          "esc_cfg", "cpu_irq_vec_d", "eff_band", "ddl_cnt", "irq_src_q"]
INPUTS = FIELDS[:8]


def bit(value, n):
    return (value >> n) & 1


def merge(old, new, strb):
    """Byte-strobe merge of a 32-bit register write."""
    out = old
    for b in range(4):
        if bit(strb, b):
            out = (out & ~(0xFF << 8 * b)) | (new & (0xFF << 8 * b))
    return out & 0xFFFFFFFF


def band_urgency(band, band_cfg):
    return (band_cfg >> (2 * band)) & 3


def band_bump(band, band_cfg):
    """The band with the least urgency that is still more urgent than this one."""
    current, best, result = band_urgency(band, band_cfg), None, band
    for candidate_band in range(4):
        u = band_urgency(candidate_band, band_cfg)
        if u > current and (best is None or u < best):
            best, result = u, candidate_band
    return result


class Pic:
    def __init__(self):
        self.config = [0] * NSRC
        self.sw_pend = self.int_enable = 0
        self.band_cfg, self.nest_max, self.esc_cfg = 0x1B, 8, 0
        self.spurious_log = self.int_status = 0
        self.irq_src_q = self.edge_pend = self.active = self.escalated = self.spurious = 0
        self.eff_band = [0] * NSRC
        self.ddl_cnt = [0] * NSRC
        self.stack_id = [0] * MAXNEST
        self.stack_key = [0] * MAXNEST
        self.depth = 0
        self.cpu_irq = self.cpu_irq_vec = self.cpu_irq_vec_d = 0

    # combinational view of the current state under the current inputs
    def request(self, src):
        req = 0
        for s in range(NSRC):
            hw = bit(self.edge_pend, s) if bit(self.config[s], 0) else bit(src, s)
            if (hw or bit(self.sw_pend, s)) and bit(self.int_enable, s):
                req |= 1 << s
        return req

    def key(self, s):
        intra = (self.config[s] >> 4) & 0xF
        return (band_urgency(self.eff_band[s], self.band_cfg) << 8) | (intra << 4) | (15 - s)

    def observed(self, src):
        return {
            "cpu_irq": self.cpu_irq, "cpu_irq_vec": self.cpu_irq_vec,
            "pending": self.request(src) & ~self.active & 0xFFFF, "depth": self.depth,
            "active": self.active, "spurious": self.spurious, "spurious_log": self.spurious_log,
            "int_status": self.int_status, "escalated": self.escalated, "sw_pend": self.sw_pend,
            "edge_pend": self.edge_pend, "int_enable": self.int_enable, "band_cfg": self.band_cfg,
            "nest_max": self.nest_max, "esc_cfg": self.esc_cfg, "cpu_irq_vec_d": self.cpu_irq_vec_d,
            "eff_band": sum(self.eff_band[s] << 2 * s for s in range(NSRC)),
            "ddl_cnt": sum(self.ddl_cnt[s] << 16 * s for s in range(NSRC)),
            "irq_src_q": self.irq_src_q,
        }

    def step(self, i):
        src, mask = i["irq_src"], i["cpu_mask"]
        req = self.request(src)
        keys = [self.key(s) for s in range(NSRC)]
        has_active = self.depth != 0
        top = (self.depth - 1) & 0xF
        top_key = self.stack_key[top]
        eligible = [bit(req, s) and bit(mask, s) and not bit(self.active, s)
                    and (not has_active or keys[s] > top_key) for s in range(NSRC)]
        winner = 0
        for s in range(NSRC):  # the lowest index wins a tie: the key's last field
            if eligible[s] and (not eligible[winner] or keys[s] > keys[winner]):
                winner = s
        offered = any(eligible)
        offer = offered and self.depth < self.nest_max
        depth_block = offered and self.depth >= self.nest_max

        claimed = self.cpu_irq_vec_d
        claim = bool(i["ack"]) and self.depth < self.nest_max
        spurious_claim = claim and not bit(req, claimed)
        eoi = bool(i["eoi"]) and has_active

        esc_target, esc_bump, esc_multi = self.esc_cfg & 3, bit(self.esc_cfg, 4), bit(self.esc_cfg, 8)
        escalate = 0
        nxt_edge, nxt_esc = self.edge_pend, self.escalated
        nxt_band, nxt_ddl = list(self.eff_band), list(self.ddl_cnt)
        for s in range(NSRC):
            cfg = self.config[s]
            deadline, cfg_band, edge_mode = cfg >> 16, (cfg >> 1) & 3, bit(cfg, 0)
            waiting = bit(req, s) and not bit(self.active, s)
            counting = waiting and deadline != 0
            hit = counting and ((self.ddl_cnt[s] + 1) & 0xFFFF) >= deadline
            esc = hit and (not bit(self.escalated, s) or esc_multi)
            escalate |= esc << s
            new_edge = edge_mode and bit(src, s) and not bit(self.irq_src_q, s)
            if new_edge:
                nxt_edge |= 1 << s
            elif claim and claimed == s:
                nxt_edge &= ~(1 << s)
            if not counting or esc:
                nxt_ddl[s] = 0
            elif not hit:
                nxt_ddl[s] = (self.ddl_cnt[s] + 1) & 0xFFFF
            if not waiting:
                nxt_esc &= ~(1 << s)
            elif esc:
                nxt_esc |= 1 << s
            if not waiting:
                nxt_band[s] = cfg_band
            elif esc:
                nxt_band[s] = band_bump(self.eff_band[s], self.band_cfg) if esc_bump else esc_target
            elif not bit(self.escalated, s):
                nxt_band[s] = cfg_band

        # nesting stack, active and spurious flags
        nxt_depth, nxt_active, nxt_spur = self.depth, self.active, self.spurious
        nxt_ids, nxt_keys = list(self.stack_id), list(self.stack_key)
        if claim:
            nxt_depth = self.depth + 1
            nxt_ids[self.depth & 0xF] = claimed
            nxt_keys[self.depth & 0xF] = keys[claimed]
            nxt_active |= 1 << claimed
            if spurious_claim:
                nxt_spur |= 1 << claimed
        elif eoi:
            nxt_depth = self.depth - 1
        if eoi:  # the clear lands after the set, as a later write to the same flag
            nxt_active &= ~(1 << self.stack_id[top])
            nxt_spur &= ~(1 << self.stack_id[top])

        # register writes
        wr, addr, data, strb = i["reg_wr"], i["reg_waddr"], i["reg_wdata"], i["reg_wstrb"]
        nxt_config, nxt_sw = list(self.config), self.sw_pend
        nxt_bandcfg, nxt_nest, nxt_esccfg, nxt_ie = self.band_cfg, self.nest_max, self.esc_cfg, self.int_enable
        if claim:
            nxt_sw &= ~(1 << claimed)
        w1c_log, w1c_status = 0, 0
        if wr:
            if addr < 16:
                nxt_config[addr] = merge(self.config[addr], data, strb) & CFG_MASK
            elif addr < 32:
                keyed = (data >> 16) == SW_KEY and (strb & 0xC) == 0xC
                if bit(strb, 0) and bit(data, 0) and keyed:
                    nxt_sw |= 1 << (addr - 16)
                elif bit(strb, 0) and not bit(data, 0):
                    nxt_sw &= ~(1 << (addr - 16))
            elif addr == W_BAND:
                nxt_bandcfg = merge(self.band_cfg, data, strb) & 0xFF
            elif addr == W_NEST_MAX and bit(strb, 0):
                value = data & 0x1F
                nxt_nest = 1 if value == 0 else min(value, MAXNEST)
            elif addr == W_ESC:
                nxt_esccfg = merge(self.esc_cfg, data, strb) & ESC_MASK
            elif addr == W_INT_EN:
                nxt_ie = merge(self.int_enable, data, strb) & 0xFFFF
            elif addr == W_SPUR_LOG:
                w1c_log = (data & 0xFF00 if bit(strb, 1) else 0) | (data & 0xFF if bit(strb, 0) else 0)
            elif addr == W_INT_ST and bit(strb, 0):
                w1c_status = data & 7
        spur_set = (1 << claimed) if spurious_claim else 0
        status_set = (depth_block << 2) | ((escalate != 0) << 1) | int(spurious_claim)

        self.cpu_irq_vec_d = self.cpu_irq_vec
        self.cpu_irq = int(offer)
        if offer:
            self.cpu_irq_vec = winner
        self.irq_src_q = src
        self.edge_pend, self.escalated, self.eff_band, self.ddl_cnt = nxt_edge, nxt_esc, nxt_band, nxt_ddl
        self.depth, self.active, self.spurious = nxt_depth, nxt_active, nxt_spur
        self.stack_id, self.stack_key = nxt_ids, nxt_keys
        self.config, self.sw_pend = nxt_config, nxt_sw
        self.band_cfg, self.nest_max, self.esc_cfg, self.int_enable = nxt_bandcfg, nxt_nest, nxt_esccfg, nxt_ie
        self.spurious_log = (self.spurious_log & ~w1c_log) | spur_set
        self.int_status = (self.int_status & ~w1c_status) | status_set
        return {"claim": claim, "spurious": spurious_claim, "eoi": eoi, "escalate": escalate != 0,
                "blocked": depth_block}


def check(path):
    model, mismatches = Pic(), 0
    events = {"claim": 0, "spurious": 0, "eoi": 0, "escalate": 0, "blocked": 0}
    lines = [line.split() for line in open(path) if line.strip() and not line.startswith("#")]
    for cycle, tokens in enumerate(lines):
        values = dict(zip(FIELDS, (int(t, 16) for t in tokens)))
        expected = model.observed(values["irq_src"])
        for name, value in expected.items():
            if values[name] != value:
                mismatches += 1
                if mismatches <= 20:
                    print(f"MISMATCH {path} cycle {cycle}: {name} rtl=0x{values[name]:x} model=0x{value:x}")
        for name, happened in model.step({k: values[k] for k in INPUTS}).items():
            events[name] += int(happened)
    summary = ", ".join(f"{v} {k}" for k, v in events.items())
    print(f"{'PASS' if mismatches == 0 else 'FAIL'}: {path}: {len(lines)} cycles, {summary}")
    return mismatches == 0


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    results = [check(path) for path in sys.argv[1:]]
    if not all(results):
        sys.exit("PIC MODEL: MISMATCH")
    print(f"PIC MODEL PASS: {len(results)} trace(s), every cycle identical")


if __name__ == "__main__":
    main()
