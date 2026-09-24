"""Generate RV32I programs and architectural traces without asm.py or RTL constants.

Without options it writes the directed program (program_isa*). --random-set also
writes one constrained-random program per seed in RANDOM_SEEDS
(program_isa_r<seed>*): every integer operation, all load/store widths through
two base registers, forward branches, counted loops, indirect jumps that change
target on the same PC, and call chains deeper than the return-address stack.
Each program comes with its retirement trace, final data memory and step count.
"""

from collections import Counter
from pathlib import Path
import argparse
import random

MASK = 0xFFFFFFFF
DATA_BYTES = 1024
RANDOM_SEEDS = list(range(1, 11))
RANDOM_WORDS = 1500       # program size; loops and the outer repeat multiply it
MAX_STEPS = 16384         # rv32i_tb_isa sizes its expected-trace array to this


def signed(value, bits=32):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def imm(op, rd, rs1, value, funct3=0):
    return ((value & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | op


def reg(rd, rs1, rs2, funct3, funct7=0):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33


def store(rs2, offset, funct3, base=31):
    return (((offset >> 5) & 0x7F) << 25) | (rs2 << 20) | (base << 15) | (funct3 << 12) | ((offset & 31) << 7) | 0x23


def branch(rs1, rs2, funct3, offset):
    value = offset & 0x1FFF
    return ((value >> 12) << 31) | (((value >> 5) & 63) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (((value >> 1) & 15) << 8) | (((value >> 11) & 1) << 7) | 0x63


def jump(rd, offset):
    value = offset & 0x1FFFFF
    return ((value >> 20) << 31) | (((value >> 1) & 1023) << 21) | (((value >> 11) & 1) << 20) | (((value >> 12) & 255) << 12) | (rd << 7) | 0x6F


def upper(op, rd, value):
    return ((value & 0xFFFFF) << 12) | (rd << 7) | op


def load_constant(rd, value):
    high = ((value + 0x800) >> 12) & 0xFFFFF
    return [upper(0x37, rd, high), imm(0x13, rd, rd, value)]


def program(seed):
    rng = random.Random(seed)
    code = [0x00002FB7]  # lui x31, 2: data memory at 0x2000
    for rd, value in enumerate([0, 1, -1, 0x7FFFFFFF, 0x80000000, 0x55555555, 0xAAAAAAAA], 1):
        upper_bits = ((value + 0x800) >> 12) & 0xFFFFF
        code += [(upper_bits << 12) | (rd << 7) | 0x37, imm(0x13, rd, rd, value)]

    # Every integer operation, all shift amounts, dependent destinations.
    for shift in range(32):
        code.append(imm(0x13, 8, 0, shift))
        for funct3 in range(8):
            code.append(reg(9, 5, 8, funct3))
        code += [reg(10, 9, 8, 0, 32), reg(11, 5, 8, 5, 32)]
        for funct3 in [0, 2, 3, 4, 6, 7]:
            code.append(imm(0x13, 12, 11, rng.choice([-2048, -1, 0, 1, 2047]), funct3))
        for funct3, value in [(1, shift), (5, shift), (5, 0x400 | shift)]:
            code.append(imm(0x13, 13, 5, value, funct3))

    # Byte-addressed memory oracle; test lane selection and signed loads.
    for offset in range(0, 64, 4):
        code.append(store(5, offset, 2))
        for lane in range(4):
            code += [store(3, offset + lane, 0), imm(3, 14, 31, offset + lane, 0), imm(3, 15, 31, offset + lane, 4), imm(3, 18, 31, offset, 2)]
        for lane in [0, 2]:
            code += [store(6, offset + lane, 1), imm(3, 16, 31, offset + lane, 1), imm(3, 17, 31, offset + lane, 5), imm(3, 18, 31, offset, 2)]
        code.append(imm(3, 18, 31, offset, 2))

    # Branches in both directions, taken and not taken; skipped writes must vanish.
    for funct3 in [0, 1, 4, 5, 6, 7]:
        for rs1, rs2 in [(1, 1), (3, 2), (2, 3)]:
            code += [branch(rs1, rs2, funct3, 8), imm(0x13, 19, 19, 1)]
    code += [imm(0x13, 20, 0, 4), imm(0x13, 20, 20, -1), branch(20, 0, 1, -4)]
    code += [jump(1, 8), imm(0x13, 19, 19, 99)]
    target = (len(code) + 3) * 4
    code += [imm(0x13, 21, 0, 0)]  # replaced below by LUI + ADDI
    code[-1:] = [(((target + 0x800) >> 12) << 12) | (21 << 7) | 0x37,
                 imm(0x13, 21, 21, target + 4)]
    code += [imm(0x67, 5, 21, 1), imm(0x13, 19, 19, 99)]  # JALR clears bit 0
    code += [0x12345B17, 0x0000000F]  # auipc x22, 0x12345; fence

    for _ in range(160):
        code.append(reg(rng.randrange(31), rng.randrange(31), rng.randrange(31), rng.randrange(8)))

    # Exact minstret ordering, including an explicit zero-mask register write.
    code += [imm(0x13, 1, 0, 16), imm(0x13, 2, 0, 0)]
    for funct3, rs1 in [(1, 1), (2, 0), (2, 1), (2, 0), (3, 1), (2, 0), (2, 2), (2, 0), (5, 7), (6, 1), (7, 2), (2, 0)]:
        code.append(imm(0x73, 23, rs1, 0xB02, funct3))
    return code


# Constrained-random programs. Registers: x1..x23 carry random data; x24 counts
# the outer repeat; x25..x29 belong to the loop, jump and chain constructs; x30
# points into the middle of data memory and x31 at its start.

class Builder:
    """Instruction list with labels resolved once the layout is known."""

    def __init__(self):
        self.items, self.labels = [], {}

    def emit(self, *words):
        self.items.extend(words)

    def label(self, name):
        self.labels[name] = len(self.items) * 4

    def here(self):
        return len(self.items)

    def resolve(self):
        code = []
        for pc, item in enumerate(self.items):
            if isinstance(item, int):
                code.append(item)
            elif item[0] == "jal":
                code.append(jump(item[1], self.labels[item[2]] - pc * 4))
            else:
                _, rs1, rs2, funct3, name = item
                code.append(branch(rs1, rs2, funct3, self.labels[name] - pc * 4))
        return code


def simple(rng, avoid=()):
    """One instruction without control flow: ALU, LUI/AUIPC, load or store."""
    rd = rng.choice([r for r in range(1, 24) if r not in avoid])
    rs1, rs2 = rng.randrange(32), rng.randrange(32)
    kind = rng.random()
    if kind < 0.40:
        funct3 = rng.randrange(8)
        return reg(rd, rs1, rs2, funct3, 0x20 if funct3 in (0, 5) and rng.random() < 0.5 else 0)
    if kind < 0.72:
        funct3 = rng.choice([0, 1, 2, 3, 4, 5, 6, 7])
        if funct3 == 1:
            return imm(0x13, rd, rs1, rng.randrange(32), 1)
        if funct3 == 5:
            return imm(0x13, rd, rs1, rng.randrange(32) | (0x400 if rng.random() < 0.5 else 0), 5)
        value = rng.choice([rng.randint(-2048, 2047), -2048, -1, 0, 1, 2047])
        return imm(0x13, rd, rs1, value, funct3)
    if kind < 0.77:
        return upper(0x37, rd, rng.getrandbits(20))
    if kind < 0.80:
        return upper(0x17, rd, rng.getrandbits(20))
    size = rng.choice([1, 2, 4])
    if rng.random() < 0.5:  # x31 = start of the window, non-negative offsets
        base, offset = 31, rng.randrange(0, DATA_BYTES - size + 1, size)
    else:                   # x30 = middle of the window, both signs
        base, offset = 30, rng.randrange(-DATA_BYTES // 2, DATA_BYTES // 2 - size + 1, size)
    if kind < 0.90:
        funct3 = {1: rng.choice([0, 4]), 2: rng.choice([1, 5]), 4: 2}[size]
        return imm(0x03, rd, base, offset, funct3)
    return store(rng.randrange(32), offset, {1: 0, 2: 1, 4: 2}[size], base)


def random_program(seed, words=RANDOM_WORDS, repeats=2):
    rng = random.Random(seed)
    b = Builder()
    b.emit(upper(0x37, 31, 2), upper(0x37, 30, 2), imm(0x13, 30, 30, DATA_BYTES // 2))
    for rd in range(1, 24):
        b.emit(*load_constant(rd, rng.getrandbits(32)))
    b.emit(imm(0x13, 24, 0, repeats))
    b.label("outer")
    serial = 0
    while b.here() < words:
        serial += 1
        kind = rng.random()
        if kind < 0.62:
            b.emit(simple(rng))
        elif kind < 0.72:  # forward branch over 1..4 instructions, either outcome
            skip = rng.randint(1, 4)
            b.emit(branch(rng.randrange(32), rng.randrange(32), rng.choice([0, 1, 4, 5, 6, 7]), (skip + 1) * 4))
            b.emit(*[simple(rng) for _ in range(skip)])
        elif kind < 0.80:  # counted loop, taken back-edges and one fall-through
            body = [simple(rng) for _ in range(rng.randint(1, 6))]
            b.emit(imm(0x13, 29, 0, rng.randint(2, 6)))
            b.label(f"loop{serial}")
            b.emit(*body)
            b.emit(imm(0x13, 29, 29, -1), ("br", 29, 0, 1, f"loop{serial}"))
        elif kind < 0.86:  # one JALR, alternating targets: the BTB is right, then wrong
            b.emit(imm(0x13, 28, 0, rng.randint(3, 5)))
            b.label(f"ij{serial}")
            b.emit(imm(0x13, 26, 28, 1, 7), imm(0x13, 26, 26, 3, 1), upper(0x17, 27, 0),
                   reg(27, 27, 26, 0), imm(0x67, rng.choice([0, 1]), 27, 12, 0))
            b.emit(imm(0x13, 25, 25, 1), ("jal", 0, f"ij_join{serial}"))
            b.emit(imm(0x13, 25, 25, 3), ("jal", 0, f"ij_join{serial}"))
            b.label(f"ij_join{serial}")
            b.emit(imm(0x13, 28, 28, -1), ("br", 28, 0, 1, f"ij{serial}"))
        elif kind < 0.93:  # call chain, sometimes deeper than the eight RAS entries
            depth = rng.randint(1, 11)
            saved = list(range(10, 20))
            b.emit(("jal", 1, f"f{serial}_1"), ("jal", 0, f"f{serial}_end"))
            for level in range(1, depth + 1):
                b.label(f"f{serial}_{level}")
                if level < depth:
                    keep = saved[level - 1]
                    b.emit(imm(0x13, keep, 1, 0), ("jal", 1, f"f{serial}_{level + 1}"),
                           simple(rng, avoid=[1] + saved), imm(0x13, 1, keep, 0))
                else:
                    b.emit(simple(rng, avoid=[1] + saved))
                b.emit(imm(0x67, 0, 1, 0))
            b.label(f"f{serial}_end")
        elif kind < 0.97:  # CSR: mscratch in every form, minstret read
            funct3 = rng.choice([1, 2, 3, 5, 6, 7])
            b.emit(imm(0x73, rng.randint(1, 23), rng.randrange(32), 0x340, funct3))
            if rng.random() < 0.3:
                b.emit(imm(0x73, rng.randint(1, 23), 0, 0xB02, 2))
        else:
            b.emit(0x0000000F)
    # The outer repeat runs the body again with the registers it left behind.
    b.emit(imm(0x13, 24, 24, -1), ("br", 24, 0, 0, "outer_done"), ("jal", 0, "outer"))
    b.label("outer_done")
    b.emit(imm(0x13, 0, 0, 0))
    return b.resolve()


def execute(code):
    registers = [0] * 32
    memory = bytearray(DATA_BYTES)
    trace, counts = [], Counter()
    pc, retired, mscratch = 0, 0, 0
    while pc < len(code) * 4:
        if len(trace) > MAX_STEPS:
            raise ValueError("reference program did not terminate")
        word = code[pc // 4]
        op, rd, f3 = word & 127, (word >> 7) & 31, (word >> 12) & 7
        a, b = registers[(word >> 15) & 31], registers[(word >> 20) & 31]
        immediate = signed(word >> 20, 12)
        next_pc, value, write = pc + 4, 0, True
        counter_write = False
        if op == 0x37:
            value = word & 0xFFFFF000
            name = "lui"
        elif op == 0x17:
            value = pc + (word & 0xFFFFF000)
            name = "auipc"
        elif op in (0x13, 0x33):
            rhs = immediate & MASK if op == 0x13 else b
            if f3 == 0:
                subtract = op == 0x33 and word >> 25 == 32
                value = a - rhs if subtract else a + rhs
                name = "sub" if subtract else "add"
            elif f3 == 1:
                value, name = a << (rhs & 31), "sll"
            elif f3 == 2:
                value, name = int(signed(a) < signed(rhs)), "slt"
            elif f3 == 3:
                value, name = int(a < rhs), "sltu"
            elif f3 == 4:
                value, name = a ^ rhs, "xor"
            elif f3 == 5:
                arithmetic = bool(word & (1 << 30))
                value = (signed(a) if arithmetic else a) >> (rhs & 31)
                name = "sra" if arithmetic else "srl"
            elif f3 == 6:
                value, name = a | rhs, "or"
            else:
                value, name = a & rhs, "and"
            if op == 0x13:
                name += "i"
        elif op in (3, 0x23):
            offset = immediate if op == 3 else signed(((word >> 25) << 5) | ((word >> 7) & 31), 12)
            address, size = ((a + offset) & MASK) - 0x2000, 1 << (f3 & 3)
            assert 0 <= address <= len(memory) - size and address % size == 0
            if op == 3:
                value = int.from_bytes(memory[address:address + size], "little", signed=f3 < 4)
                name = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}[f3]
            else:
                memory[address:address + size] = (b & ((1 << (size * 8)) - 1)).to_bytes(size, "little")
                write, name = False, {0: "sb", 1: "sh", 2: "sw"}[f3]
        elif op == 0x63:
            offset = signed(((word >> 31) << 12) | (((word >> 7) & 1) << 11) | (((word >> 25) & 63) << 5) | (((word >> 8) & 15) << 1), 13)
            taken = {0: a == b, 1: a != b, 4: signed(a) < signed(b), 5: signed(a) >= signed(b), 6: a < b, 7: a >= b}[f3]
            next_pc = pc + offset if taken else pc + 4
            write, name = False, f"branch{f3}_{int(taken)}"
        elif op == 0x6F:
            offset = signed(((word >> 31) << 20) | (((word >> 12) & 255) << 12) | (((word >> 20) & 1) << 11) | (((word >> 21) & 1023) << 1), 21)
            value, next_pc, name = pc + 4, pc + offset, "jal"
        elif op == 0x67:
            value, next_pc, name = pc + 4, (a + immediate) & ~1 & MASK, "jalr"
        elif op == 0x0F:
            write, name = False, "fence"
        elif op == 0x73 and word >> 20 == 0xB02:
            source_field = (word >> 15) & 31
            source = source_field if f3 >= 5 else a
            value, name = retired & MASK, f"csr{f3}"
            counter_write = (f3 & 3) == 1 or source_field != 0
            if counter_write:
                low = {1: source, 2: value | source, 3: value & ~source}[f3 & 3]
                retired = (retired & ~MASK) | (low & MASK)
        elif op == 0x73 and word >> 20 == 0x340:
            source_field = (word >> 15) & 31
            source = source_field if f3 >= 5 else a
            value, name = mscratch, f"mscratch{f3}"
            if (f3 & 3) == 1 or source_field != 0:
                mscratch = {1: source, 2: mscratch | source, 3: mscratch & ~source}[f3 & 3] & MASK
        else:
            raise ValueError(f"unsupported instruction {word:08x}")
        dest = rd if write and rd else 0
        value = value & MASK if dest else 0
        registers[dest] = value
        trace.append((pc, dest, value))
        counts[name] += 1
        if not counter_write:
            retired += 1
        pc = next_pc
    return trace, memory, counts


def write_outputs(prefix, code, trace, memory):
    root = Path(__file__).resolve().parent
    if len(code) + 1 > 2048:
        raise ValueError(f"{prefix}: {len(code) + 1} words exceed the 8 KiB instruction memory")
    if len(trace) > MAX_STEPS:
        raise ValueError(f"{prefix}: {len(trace)} steps exceed the bench limit {MAX_STEPS}")
    outputs = {
        f"{prefix}.hex": [f"{w:08x}" for w in code + [jump(0, 0)]],
        f"{prefix}_trace.hex": [f"{pc:08x}{rd:08x}{value:08x}" for pc, rd, value in trace],
        f"{prefix}_mem.hex": [f"{int.from_bytes(memory[i:i+4], 'little'):08x}" for i in range(0, DATA_BYTES, 4)],
        f"{prefix}_count.hex": [f"{len(trace):08x}"],
    }
    for name, lines in outputs.items():
        # LF on every host, so Windows and WSL runs produce identical files
        with open(root / name, "w", newline="\n") as handle:
            handle.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=104729, help="seed of the directed program")
    parser.add_argument("--random-set", action="store_true", help="also write the random programs")
    args = parser.parse_args()
    # Encoding anchors from instruction listings, independent of the decoder.
    assert imm(0x13, 1, 0, 1) == 0x00100093
    assert reg(3, 1, 2, 0, 32) == 0x402081B3
    assert jump(0, 0) == 0x0000006F
    assert store(2, 8, 2, 30) == 0x002F2423  # sw x2, 8(x30)
    code = program(args.seed)
    trace, memory, counts = execute(code)
    assert all(counts[f"branch{f3}_{taken}"] for f3 in [0, 1, 4, 5, 6, 7] for taken in [0, 1])
    assert len(counts) == 50, counts
    write_outputs("program_isa", code, trace, memory)
    print(f"ISA reference: seed={args.seed}, steps={len(trace)}, bins={len(counts)}")
    if args.random_set:
        for seed in RANDOM_SEEDS:
            code = random_program(seed)
            trace, memory, counts = execute(code)
            write_outputs(f"program_isa_r{seed}", code, trace, memory)
            print(f"ISA random: seed={seed}, words={len(code) + 1}, steps={len(trace)}, bins={len(counts)}")


if __name__ == "__main__":
    main()
