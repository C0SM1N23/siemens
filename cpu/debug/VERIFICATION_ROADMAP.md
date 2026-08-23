# Verification roadmap

Work that would raise confidence in this delivery beyond what the current
regression establishes. Nothing here has been done — this is a backlog, not a
record. For what *has* been verified, see `VERIFICATION.md` and Part V of
`docs/main.pdf`.

Each item states what the gap is, why it matters, and roughly what closing it
costs. Ordered by value per unit of effort within each section.

---

## 1. ISA conformance

The current evidence for "the CPU executes RV32I correctly" is a directed,
hand-written program with expected values written by hand. That establishes that
every instruction class, every trap cause and every documented register field
behaves as documented. It is not a conformance claim, and the difference matters
to anyone integrating the core.

### 1.1 riscv-arch-test

**Gap.** The official RISC-V architectural test suite has never been run against
the core.

**Why.** It is the only way to make a defensible conformance statement, and it
covers encodings and corner cases no hand-written program reaches — every
immediate boundary, every shift amount in situ, the full signed/unsigned
comparison matrix, `x0` behaviour under every writing instruction.

**Cost.** Moderate, and mostly plumbing rather than test writing:

- a compliance signature region in the linker map, dumped at end of test;
- an ELF loader for the memory model, or an `objcopy` step into the existing
  `.hex` format — the current `asm.py` flow assembles one file and would need
  replacing with a real toolchain (`riscv64-unknown-elf-gcc -march=rv32i`);
- a per-test harness that resets, loads, runs to `ecall`, dumps the signature
  and diffs it against the reference;
- the `RV32I` and `privilege` test groups are the relevant ones; `Zicsr` covers
  the CSR access rules the CSR bench checks by hand today.

**Note.** Expect the first run to fail on `misa` and on the `mtvec.MODE` WARL
deviation already recorded in the limitations chapter.

### 1.2 Instruction-level reference model

**Gap.** No golden model. Every expected value in the regression is a constant
in a testbench.

**Why.** A reference model turns any program into a test. Once it exists,
randomised streams (§1.3) become nearly free, and a directed test no longer has
to carry its own arithmetic.

**Cost.** Moderate. Options, cheapest first:

- Spike (`riscv-isa-sim`) in step-and-compare, driven from the retire signals
  the SVA layer already exposes — needs a DPI bridge, so Verilator only;
- a small Python RV32I interpreter (a few hundred lines for the base set) run
  offline against the same `.hex`, producing a register trace the bench diffs.
  Cruder, but no toolchain dependency and it fits the existing flow.

The retire-side observability needed for either already exists: `dxwb_valid_q`,
`dxwb_rd_q` and `wb_data` are what `minstret` counts.

### 1.3 Randomised and constrained-random instruction streams

**Gap.** All stimulus is directed. The only randomisation in the environment is
`READY` backpressure on the memory models, with fixed seeds.

**Why.** Directed tests only find what the author thought of. The interactions
worth fuzzing here are specific and known: a branch resolving in the same cycle
as an interrupt arrives; a trap taken while a data transaction is outstanding;
a redirect landing on an AR that has been issued but not accepted; back-to-back
CSR writes to `mstatus` around a trap.

**Cost.** Low *after* §1.2, high before it — without a reference model there is
nothing to check the random program against. A generator biased toward the
interactions above is more useful than a uniform one.

---

## 2. Extending the existing benches

These need no new infrastructure and are the cheapest items on the list.

### 2.1 Reset asserted mid-transaction

**Gap.** Every bench resets the DUT and the models together. Reset asserted in
the middle of an AXI transaction — while a slave owes a response, or while
`ARVALID` is up and unaccepted — is not exercised anywhere.

**Why.** It is the realistic case once the system has a reset controller, and it
is where an orphaned transaction or a stuck handshake flag would show. The
one-outstanding contract makes the state space small enough to enumerate.

**Cost.** Low. Extend `tb_mtimer_regs` and `tb_pic_reset` with a reset asserted
at each phase of a write (after AW, after W, after commit, before `BREADY`) and
of a read (after AR, before `RREADY`), then confirm the block is idle and the
next transaction completes normally.

### 2.2 Parameter sweeps

**Gap.** Every run uses the default parameters. `BP_ENTRIES` and `RAS_DEPTH` are
documented as configurable, and `tb_bp` covers `RAS_DEPTH = 0` and the defaults,
but no other value of either is elaborated anywhere. `HART_ID` is exercised only
as 0 and 42.

**Why.** A parameterised design that has only ever been elaborated at one
setting is parameterised by assertion. `BP_ENTRIES` in particular changes
`IDX_W` and `TAG_W`, so an off-by-one in the index/tag split would only appear
at a non-default size.

**Cost.** Low. `tb_bp` already takes both as localparams — a regression sweep at
`ENTRIES` = 16, 64, 512 and `RAS_DEPTH` = 1, 2, 16 costs a handful of extra
`vsim -G` runs. `RAS_DEPTH = 1` and `2` are the interesting ones: `PW` is forced
to 1 there, so the pointer arithmetic takes a different path.

### 2.3 Multi-level nesting through the CPU

**Gap.** The PIC's nesting stack is verified standalone to depth 8. Through the
CPU only one level is ever reached, because handlers run with `MIE = 0`.

**Why.** The `ack`/`eoi` balance across genuinely nested handlers is the one PIC
property the system bench cannot demonstrate, and it is the property most likely
to break under integration.

**Cost.** Low, and it is software: a handler in `program_axi.s` that saves
`mepc`/`mcause`/`mstatus`, re-enables `MIE`, and restores them before `MRET` —
the standard RISC-V nesting sequence. Then raise a more urgent source from
inside the handler and check the depth reaches 2 and unwinds.

### 2.4 Coverage under backpressure

**Gap.** Two of the four uncovered bins are the AR-backpressure pair. The
stimulus that would hit them runs in ModelSim runs 3 and 4, but functional
coverage is instrumented only in the Verilator flow, which runs at default
timings — so no run collects both.

**Why.** It is a measurement gap rather than a verification gap, but it means
the reported 88/92 understates what the regression actually exercises.

**Cost.** Low. Either add a backpressure configuration to the Verilator flow
(the memory-model parameters are instance parameters, so this needs a top-level
parameter or a second top module), or accept it and keep the bins marked
optional, as now.

### 2.5 Block benches for the remaining modules

**Gap.** `control.v`, `imm_gen.v`, `decode.v` and `exception_unit.v` have no
block-level bench; they are covered only through the system program.

**Why.** `imm_gen` is the strongest candidate: five encoding formats with
different bit-scrambling and sign extension, and a bench can be exhaustive over
the sign bit and the field boundaries the way `tb_alu` is over shift amounts.
`control.v` is next — the illegal-encoding path matters, and "every other
control line is forced inactive" is asserted in the documentation but only
observed indirectly.

**Cost.** Low each, and they follow the `tb_alu` pattern exactly.

---

## 3. Beyond simulation

### 3.1 Synthesis

**Gap.** The design has never been synthesised. No area, timing or power figure
exists anywhere, and none is quoted.

**Why.** Two claims in the documentation are currently untested by anything:
that the S2 combinational path (decode → ALU → address → alignment check) would
limit clock frequency, and that the absolute reset policy costs about 7.2 kbit
of reset tree. Both are stated as reasoning, not measurement. Synthesis also
finds latch inference and unintended priority encoders that simulation does not.

**Cost.** Moderate. Yosys against a generic library gives area and a gate count
for free; a real STA number needs a vendor flow and a target.

### 3.2 Lint

**Gap.** No lint tool has been run. The compile is clean under ModelSim and
Verilator's default warning set, which is not the same thing.

**Why.** Cheapest quality signal available, and the codebase is already written
to a lint-friendly style: explicit widths, one driver per register, no implicit
extension. Verilator `-Wall` is a five-minute experiment; the filelists are
already levelled so a lint front-end takes them unchanged.

**Cost.** Very low. Worth doing before anything else on this list.

### 3.3 Formal property checking

**Gap.** The SVA layer runs only as simulation assertions.

**Why.** Several of the properties already written are bounded-model-checkable
as they stand, and are the ones where simulation coverage is weakest: the AXI
handshake contract on all four links, `depth <= NEST_MAX` in the PIC, the strict
preemption rule, and `x0 == 0`. Proving them removes the dependency on stimulus
reaching the interesting state.

**Cost.** Moderate. SymbiYosys with the existing `bind` files; the properties
would need Verilog-2005-compatible restating, since the free flow does not take
the full SVA subset.

### 3.4 Clock-domain and reset-tree review

**Gap.** Everything is one clock domain with one asynchronous reset, and release
is not synchronised.

**Why.** Real silicon needs asynchronous assertion with synchronous
de-assertion, and the dual-port SRAM in the wider system uses synchronous reset
while the CPU and DMA use asynchronous. That mismatch has to be resolved at
system level, and the resolution belongs in the deliverable once it is made.

**Cost.** Low as an analysis, and it is a system-level decision rather than a
change to these three blocks.

---

## 4. System-level

### 4.1 Interrupt routing for multiple cores

The PIC serves one CPU. Source-to-core targeting is undefined, and each core
would want its own timer compare register. The dual-core bench exercises two
cores sharing memory through an arbiter; it does not exercise interrupt routing,
because the policy does not exist yet. Verification here waits on a design
decision, not the other way round.

### 4.2 Richer interconnect

The testbench fabric is two cascaded 1-to-2 decoders and covers two slaves. It
does not reorder, does not stall independently per slave, and generates decode
errors only from the memory model. A real fabric — or a model that injects
backpressure per slave and generates its own DECERR — would exercise the
masters' one-outstanding contract harder than anything in the current
environment.

### 4.3 Peripheral address decoding

Both slaves decode only `addr[7:2]`, so inside a window larger than 256 bytes
higher addresses alias onto the first registers instead of erroring. Two clean
fixes exist (exact 256-byte windows in the decoder, or a wider comparison in the
shared slave); the choice belongs with the system memory map. Whichever is
chosen needs an aliasing test that today would fail by design.
