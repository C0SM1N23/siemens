"""Generate RV32I programs and architectural traces without asm.py or RTL constants."""

from collections import Counter
from pathlib import Path
import argparse
import random

MASK = 0xFFFFFFFF


def signed(value, bits=32):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def imm(op, rd, rs1, value, funct3=0):
    return ((value & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | op


def reg(rd, rs1, rs2, funct3, funct7=0):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33


def store(rs2, offset, funct3):
    return ((offset >> 5) << 25) | (rs2 << 20) | (31 << 15) | (funct3 << 12) | ((offset & 31) << 7) | 0x23


def branch(rs1, rs2, funct3, offset):
    value = offset & 0x1FFF
    return ((value >> 12) << 31) | (((value >> 5) & 63) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (((value >> 1) & 15) << 8) | (((value >> 11) & 1) << 7) | 0x63


def jump(rd, offset):
    value = offset & 0x1FFFFF
    return ((value >> 20) << 31) | (((value >> 1) & 1023) << 21) | (((value >> 11) & 1) << 20) | (((value >> 12) & 255) << 12) | (rd << 7) | 0x6F


def program(seed):
    rng = random.Random(seed)
    code = [0x00002FB7]  # lui x31, 2: data memory at 0x2000
    for rd, value in enumerate([0, 1, -1, 0x7FFFFFFF, 0x80000000, 0x55555555, 0xAAAAAAAA], 1):
        upper = ((value + 0x800) >> 12) & 0xFFFFF
        code += [(upper << 12) | (rd << 7) | 0x37, imm(0x13, rd, rd, value)]

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


def execute(code):
    registers = [0] * 32
    memory = bytearray(1024)
    trace, counts = [], Counter()
    pc, retired = 0, 0
    while pc < len(code) * 4:
        if len(trace) > 10000:
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
            address, size = a + offset - 0x2000, 1 << (f3 & 3)
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
            value, next_pc, name = pc + 4, (a + immediate) & ~1, "jalr"
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
    assert all(counts[f"branch{f3}_{taken}"] for f3 in [0, 1, 4, 5, 6, 7] for taken in [0, 1])
    assert len(counts) == 50, counts
    return trace, memory, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=104729)
    args = parser.parse_args()
    # Encoding anchors from instruction listings, independent of the decoder.
    assert imm(0x13, 1, 0, 1) == 0x00100093
    assert reg(3, 1, 2, 0, 32) == 0x402081B3
    assert jump(0, 0) == 0x0000006F
    code = program(args.seed)
    trace, memory, counts = execute(code)
    root = Path(__file__).resolve().parent
    (root / "program_isa.hex").write_text("\n".join(f"{w:08x}" for w in code + [jump(0, 0)]) + "\n")
    (root / "program_isa_trace.hex").write_text("\n".join(f"{pc:08x}{rd:08x}{value:08x}" for pc, rd, value in trace) + "\n")
    (root / "program_isa_mem.hex").write_text("\n".join(f"{int.from_bytes(memory[i:i+4], 'little'):08x}" for i in range(0, 1024, 4)) + "\n")
    (root / "program_isa_count.vh").write_text(f"localparam ISA_STEPS = {len(trace)};\n")
    print(f"ISA reference: seed={args.seed}, steps={len(trace)}, bins={len(counts)}")


if __name__ == "__main__":
    main()
