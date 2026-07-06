# Changelog

## The PIC is now a real module (was: a testbench stub)

Every peripheral brief routes its interrupt line to a "system interrupt
controller", and the CPU brief fixes a complete CPU↔PIC handshake — but no
brief specifies the PIC or assigns building it to anyone. Since the system
cannot deliver a single interrupt without it, it is now implemented here.

### New RTL

- `hdl/pic.v` — the interrupt controller (design decisions D19–D22, indexed
  in the README). One line of intent: `pending = irq_src & enable &
  ~in_service`. Level-sensitive sources, fixed priority (channel 0 highest),
  in-service suppression driven by `cpu_irq_ack`/`cpu_in_trap` exactly as the
  CPU brief describes, and an AXI4-Lite slave port with four word registers
  (IRQ_ENABLE R/W; IRQ_PENDING / IRQ_RAW / IRQ_ACTIVE RO; anything else
  answers SLVERR). Same coding conventions as the rest of the RTL: one
  always block per signal, resets only on control bits, payload registers
  (latched address/data, read response) reset-free because their consumers
  are gated by resettable valid bits. `cpu_irq` and `cpu_irq_id` are
  registered from the same pending vector so the pair the CPU samples is
  always consistent.

### Testbench

- `debug/hdl/axi_lite_dec2.v` — 1-master/2-slave AXI4-Lite address decoder
  (the write-path select is latched at the AW handshake so W/B route
  correctly even if the channels complete in different orders). The dbus now
  goes CPU → decoder → {dmem, PIC@0x3000_0000}.
- `tb_cpu_axi.v` — the PIC stub choreography is gone; the TB now drives the
  PIC's `irq_src` lines the way peripherals would (raise on event, hold until
  "the handler clears the status"). A third protocol monitor watches the PIC
  slave port. New checks: priority (ch2+ch3 raised in the same cycle → served
  lowest-first, timestamped), in-service suppression (source held high
  through its handler must vanish from `cpu_irq`), per-cycle consistency
  invariant (`cpu_irq_id` = lowest set bit of `cpu_irq`), PIC register
  readbacks (ENABLE/RAW/PENDING from the program, ACTIVE from inside the
  irq handler), and SLVERR negatives (unmapped register read, read-only
  register write → precise access faults; sync trap count is now exactly 15).
- One real bug found by the random-backpressure runs and fixed: the decoder
  originally selected by comparing the raw dbus address, which is undefined
  between transactions (payload registers carry no reset), so X leaked into
  the READY muxes. The compare is now qualified by the address VALID.

### Verification

Full regression after the change: all five configurations green (default
latencies with the CPI check — still 33 cycles / 33 instructions — high
fixed latencies, two random-backpressure seeds, dual-core), zero protocol
violations on ibus, dbus and the PIC port.

## Refactor: one always block per signal + efficiency pass

RTL restructuring and hardware-efficiency changes. No architectural behavior
changed: the full regression (5 configurations, AXI protocol monitors on,
dual-core included) passes identically and measured CPI is still 1.00.

### Code structure — one always per signal

Rule applied everywhere: a register gets its own `always` block; registers
that are written together under the same condition (one `if`, one `case` arm)
stay in one block, registers with different update conditions get separate
blocks. Sequential logic is now:

- `fetch_unit.v` — 7 blocks: `ar_pending_q`, `inflight_q`, `issued_pc_q`,
  `discard_q`, `hold_valid_q`, holding payload (instr/pc/fault written
  together), `npc_q`.
- `lsu.v` — 6 blocks: FSM `state_q`, one tracker per AXI channel
  (`ar_sent_q` / `aw_sent_q` / `w_sent_q`), command latch (addr/wdata/wstrb
  latched together at start).
- `csr_file.v` — 8 blocks: one per CSR. `mstatus.MIE/MPIE` stay paired
  (they swap as a unit on trap entry and on MRET); `mcycle` and `minstret`
  split (different update conditions).
- `branch_predictor.v` — 2 blocks: valid bits, entry payload (tag/state/
  target written together).
- `cpu_top.v` — 6 blocks: IF/DX valid, IF/DX payload, DX/WB valid, DX/WB
  payload, `cpu_irq_ack`, `cpu_in_trap`.

### Efficiency changes (power / area; behavior identical)

- **Reset only where it means something.** Payload registers that are never
  believed without their valid bit no longer carry a reset: IF/DX payload,
  DX/WB payload (~130 flops), the fetch holding register, the LSU command
  latch, and the predictor's tag/state/target arrays (~7k bits). Control
  bits, architectural CSRs and addresses keep their reset. Smaller reset
  tree, same observable behavior — every consumer of these registers is
  already gated by a valid/state bit that *is* reset.
- **Bubbles don't toggle the DX/WB payload.** Capture is gated by
  "a real instruction is leaving S2", so stall and flush cycles leave those
  flops (and the forwarding/writeback nets behind them) quiet instead of
  latching garbage every cycle. Cuts useless switching on ~130 flops plus
  downstream logic.
- **One shared PC+4 adder in S2.** The mispredict fall-through address and
  the JAL/JALR link value are the same number; it is now computed once
  (`s2_pc4`) instead of twice.
- **One shifter in the LSU load path.** Byte and halfword extraction both
  come from the same right-shifter; the separate 16-bit halfword mux is
  gone. Safe because a misaligned halfword traps before reaching the bus,
  so `addr[0]=0` is guaranteed and the shifted word carries the wanted half
  in bits [15:0].

### What was deliberately *not* changed

- CPI is already at the ceiling the requirements allow: load/store must
  stall the full AXI round-trip (REQ5), the predictor is fixed at 1 bit
  (REQ8), and both ports are capped at one outstanding transaction (D6,
  D12). Straight-line code runs at CPI 1.00, measured by the testbench.
- No timing "cleverness" that would restructure verified control logic for
  unmeasurable gain in behavioral simulation.

### Verification after the change

`vsim -c -do "do regress.do; quit -f"` — all five configurations pass:
default latencies (CPI check active, 33/33 cycles), high fixed AXI
latencies, two seeded random-backpressure runs, and the dual-core
shared-memory handshake. The AXI protocol monitors report zero violations
in every run, and the ISA/trap/interrupt checks (every instruction group,
every mcause, exact trap counts) are unchanged and green.
