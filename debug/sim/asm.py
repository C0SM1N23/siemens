#!/usr/bin/env python3
"""Tiny RV32I assembler for the CPU test programs (testbench only).

Usage:  py asm.py program_axi.s program_axi.hex
Supports the subset the tests use: base RV32I, CSR*, MRET/WFI, ECALL/EBREAK/
FENCE, labels (absolute in immediates, PC-relative in branches/JAL), .org and
.word. Prints the symbol table to stdout.
"""
import re
import sys

REGS = {f"x{i}": i for i in range(32)}
CSRS = {"mstatus": 0x300, "mie": 0x304, "mtvec": 0x305, "mscratch": 0x340,
        "mepc": 0x341, "mcause": 0x342, "mip": 0x344,
        "mcycle": 0xB00, "minstret": 0xB02, "mhartid": 0xF14}

R_OPS = {"add": (0, 0), "sub": (0, 0x20), "sll": (1, 0), "slt": (2, 0),
         "sltu": (3, 0), "xor": (4, 0), "srl": (5, 0), "sra": (5, 0x20),
         "or": (6, 0), "and": (7, 0)}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SH_OPS = {"slli": (1, 0), "srli": (5, 0), "srai": (5, 0x20)}
L_OPS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
S_OPS = {"sb": 0, "sh": 1, "sw": 2}
B_OPS = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
CSR_OPS = {"csrrw": 1, "csrrs": 2, "csrrc": 3,
           "csrrwi": 5, "csrrsi": 6, "csrrci": 7}


def parse_val(tok, syms):
    tok = tok.strip()
    m = re.match(r"%(hi|lo)\((\w+)\)$", tok)
    if m:
        v = syms[m.group(2)] if m.group(2) in syms else int(m.group(2), 0)
        if m.group(1) == "hi":
            return ((v + 0x800) >> 12) & 0xFFFFF
        lo = v & 0xFFF
        return lo - 0x1000 if lo >= 0x800 else lo
    if tok in syms:
        return syms[tok]
    return int(tok, 0)


def rng(val, lo, hi, what):
    if not lo <= val <= hi:
        raise ValueError(f"{what} {val} out of range [{lo}, {hi}]")
    return val


def enc_r(f3, f7, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33


def enc_i(op, f3, rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_s(f3, rs1, rs2, imm):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | ((imm & 0x1F) << 7) | 0x23


def enc_b(f3, rs1, rs2, off):
    return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63


def enc_j(rd, off):
    return (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) | \
           (((off >> 11) & 1) << 20) | (((off >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F


def tokenize(line):
    line = line.split("#")[0].strip()
    if not line:
        return None, None
    label = None
    m = re.match(r"^(\w+):\s*(.*)$", line)
    if m:
        label, line = m.group(1), m.group(2).strip()
    return label, line


def assemble(src):
    # pass 1: addresses + symbols
    syms, items, pc = {}, [], 0
    for lineno, raw in enumerate(src.splitlines(), 1):
        label, stmt = tokenize(raw)
        if label:
            syms[label] = pc
        if not stmt:
            continue
        if stmt.startswith(".org"):
            new_pc = int(stmt.split()[1], 0)
            if new_pc < pc:
                sys.exit(f"line {lineno}: .org 0x{new_pc:x} moves backwards "
                         f"(pc already 0x{pc:x}) — sections would overlap")
            pc = new_pc
            items.append((lineno, pc, stmt))
            continue
        items.append((lineno, pc, stmt))
        pc += 4

    # pass 2: encode
    mem = {}
    for lineno, pc, stmt in items:
        if stmt.startswith(".org"):
            continue
        parts = re.split(r"[,\s]+", stmt)
        op, args = parts[0].lower(), parts[1:]
        try:
            word = encode(op, args, pc, syms)
        except Exception as e:
            sys.exit(f"line {lineno}: '{stmt}': {e}")
        if (pc >> 2) in mem:
            sys.exit(f"line {lineno}: address 0x{pc:x} written twice")
        mem[pc >> 2] = word
    return mem, syms


def encode(op, a, pc, syms):
    if op == ".word":
        return parse_val(a[0], syms) & 0xFFFFFFFF
    if op == "fence":
        return 0x0FF0000F
    if op == "ecall":
        return 0x00000073
    if op == "ebreak":
        return 0x00100073
    if op == "mret":
        return 0x30200073
    if op == "wfi":
        return 0x10500073
    if op in R_OPS:
        f3, f7 = R_OPS[op]
        return enc_r(f3, f7, REGS[a[0]], REGS[a[1]], REGS[a[2]])
    if op in I_OPS:
        imm = rng(parse_val(a[2], syms), -2048, 2047, "imm")
        return enc_i(0x13, I_OPS[op], REGS[a[0]], REGS[a[1]], imm)
    if op in SH_OPS:
        f3, f7 = SH_OPS[op]
        sh = rng(parse_val(a[2], syms), 0, 31, "shamt")
        return enc_i(0x13, f3, REGS[a[0]], REGS[a[1]], (f7 << 5) | sh)
    if op in L_OPS:
        m = re.match(r"(-?\w+)\((\w+)\)", a[1])
        imm = rng(parse_val(m.group(1), syms), -2048, 2047, "offset")
        return enc_i(0x03, L_OPS[op], REGS[a[0]], REGS[m.group(2)], imm)
    if op in S_OPS:
        m = re.match(r"(-?\w+)\((\w+)\)", a[1])
        imm = rng(parse_val(m.group(1), syms), -2048, 2047, "offset")
        return enc_s(S_OPS[op], REGS[m.group(2)], REGS[a[0]], imm)
    if op in B_OPS:
        off = rng(parse_val(a[2], syms) - pc, -4096, 4094, "branch offset")
        return enc_b(B_OPS[op], REGS[a[0]], REGS[a[1]], off)
    if op == "jal":
        off = rng(parse_val(a[1], syms) - pc, -(1 << 20), (1 << 20) - 2, "jal offset")
        return enc_j(REGS[a[0]], off)
    if op == "jalr":
        imm = rng(parse_val(a[2], syms), -2048, 2047, "imm")
        return enc_i(0x67, 0, REGS[a[0]], REGS[a[1]], imm)
    if op == "lui":
        imm = rng(parse_val(a[1], syms), 0, 0xFFFFF, "upper imm")
        return (imm << 12) | (REGS[a[0]] << 7) | 0x37
    if op == "auipc":
        imm = rng(parse_val(a[1], syms), 0, 0xFFFFF, "upper imm")
        return (imm << 12) | (REGS[a[0]] << 7) | 0x17
    if op in CSR_OPS:
        f3 = CSR_OPS[op]
        src = rng(parse_val(a[2], syms), 0, 31, "uimm") if f3 > 4 else REGS[a[2]]
        csr = CSRS[a[1]] if a[1] in CSRS else int(a[1], 0)   # numeric = negative tests
        return (csr << 20) | (src << 15) | (f3 << 12) | (REGS[a[0]] << 7) | 0x73
    raise ValueError(f"unknown mnemonic: {op}")


def main():
    src_path, out_path = sys.argv[1], sys.argv[2]
    with open(src_path) as f:
        mem, syms = assemble(f.read())
    top = max(mem) + 1
    with open(out_path, "w") as f:
        for i in range(top):
            f.write(f"{mem.get(i, 0):08x}\n")

    # Emit `<stem>_sym.vh` next to the hex: one `define ADDR_<label> per symbol,
    # so the testbench checks label addresses by name instead of hardcoded hex
    # (a code change that shifts a label can no longer silently break a check).
    sym_path = re.sub(r"\.hex$", "", out_path) + "_sym.vh"
    with open(sym_path, "w") as f:
        f.write("// Generated by asm.py: label addresses for the testbench.\n")
        for name, addr in sorted(syms.items(), key=lambda kv: kv[1]):
            f.write(f"`define ADDR_{name} 32'h{addr:08x}\n")

    for name, addr in sorted(syms.items(), key=lambda kv: kv[1]):
        print(f"{name:16s} 0x{addr:08x}")


if __name__ == "__main__":
    main()
