# To modify

Open items measured against `origin/DMA b3d0422` and `origin/SDRAM 28cd380`
on 15 September 2026. DMA/SRAM RTL was not corrected during this audit.

## DMA

| Item | Evidence | Required owner action |
|---|---|---|
| Length below one word underflows the burst length | `mc_dma_channel.v`: `(desc_len[7:2] - 1)` produces ARLEN=255 for 0, 1, 2 and 3 bytes: a 256-beat, 1024-byte request. Confirmed by the port-driven probe on ModelSim and Verilator. | Reject unsupported lengths before issuing a request, or implement partial transfers with correct strobes. |
| Non-word length is truncated | Probe: 5 bytes requests 4; 22 bytes requests 20. Low length bits are discarded. | Define the supported alignment contract and reject or implement the final partial word. |
| Token refill can overflow before saturation | With refill=40000 and maximum=65535, two refill periods produce 40000 then 14464. The 16-bit sum wraps before the maximum comparison. The latest upstream fix does not cover this setting. | Widen the addition before comparison, then saturate to the configured maximum; add overflow-boundary tests. |
| Own block bench uses the old module interface | `dma/debug/hdl/tb_mc_dma.v:117` instantiates `mc_dma_top`; current RTL defines `mc_dma`. Isolated ModelSim elaboration fails with `vsim-3033`. The retained `tb_mc_dma_top.v` also uses the old interface and checks IRQ without first enabling `INT_ENABLE`. | Update the owner's benches to current names/ports and interrupt contract, then run every scenario with a strict verdict. |
| Empty ModelSim entry point | `dma/debug/sim/sim.do` is zero bytes. | Provide a compile/run script for the current DMA bench. |

## Dual-port SRAM

| Item | Evidence | Required owner action |
|---|---|---|
| Undefined register word 7 returns success | The top routes register words 0–7, while the bank defines 0–6. Probe reads word 7 as zero with error=0. The bank's error outputs do not report unmapped offsets. | Define the reserved-offset policy; if invalid, report a slave error for reads and writes on both ports. |
| Default address space exposes 248 data words | Default 10-bit byte address includes 32 bytes of registers; data offsets 0x020–0x3FC address array entries 0–247. The array has 256 entries. Fixed `[9:2]` slices also prevent solving this by changing `ADDR_W` alone. | Reconcile the 256-word requirement with the register window and parameterized address decode; test the top data address on both ports. |

The earlier fixed-width bandwidth-window finding is closed upstream:
`WINDOW_CYCLES=2048` now completes with `BANDWIDTH_A=2048` in the probe.
It is not an open defect.

## Reproduce and lint

From `soc/debug/sim`, run the read-only diagnostic:

```text
vsim -c -do "do probe_upstream.do"
```

Verilator reproduction, from the same directory in Bash/WSL:

```text
verilator --binary --timing --timescale 1ns/1ps -Wno-fatal --unroll-count 64 -j 4 --top-module soc_probe_upstream --Mdir obj_dir/probe -f soc_rtl.f ../hdl/soc_probe_upstream.v
./obj_dir/probe/Vsoc_probe_upstream
```

Both diagnostic runs print the same observations. This probe is excluded from
the passing functional regression. Current lint has 17 upstream diagnostics,
identified exactly in `soc/debug/sim/known_lint.json`; these are not 17 proven
functional bugs. The set includes register-address sizing, the descriptor-length
expression, bandwidth comparison sizing and a vector used as a condition.
After an owner fix, rerun the diagnostic and remove resolved lint entries.

## CPU / PIC interface agreement

The CPU brief specifies eight IRQ inputs, a three-bit ID and an eight-bit
acknowledge; the PIC brief specifies sixteen sources. The implemented common
interface uses sixteen pending/mask bits, a four-bit vector, scalar claim and
EOI. Claim pushes an active level; EOI pops it. The mentor/team must confirm this
contract against the original briefs. This is an interface decision, not a
functional failure of the tested implementation.
