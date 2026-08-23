# SoC integration log

Every change made to the CPU, DMA and DP-SRAM blocks in order to make them
work together as one SoC, and why each one was needed.

The three blocks were developed independently on the `RISCV`, `DMA` and
`SDRAM` branches. Those branches are untouched by this integration: nothing
was rebased, rewritten or force-pushed. The work happens on `master`, which
now carries all three blocks plus the interconnect that joins them.

Read this document as the answer to "what did you have to change in their
code, and why?".

---

## 1. Repository layout

`master` merges the three block branches into one tree. To make that possible
without path collisions, two of the blocks were relocated on temporary staging
branches (`dma-stage`, `sram-stage`) cut from the branch tips, and those
staging branches were merged. The original branches were never modified.

| Path | Origin | Contents |
|---|---|---|
| `hdl/`, `debug/` | `RISCV` | CPU, PIC, machine timer + their verification |
| `dma/` | `DMA` | multi-channel DMA engine + its verification |
| `sram/` | `SDRAM` | dual-port SRAM + its verification |
| `soc/` | new | interconnect, SoC top level, system verification |

The CPU stayed at the repository root because its build system (`Makefile`,
CI workflow, `debug/sim/rtl.f`, `compile.do`, the `tb_*.f` filelists) refers to
roughly fifty paths that would otherwise all have to be rewritten. Moving the
other two blocks was the smaller and lower-risk change.

### Collisions the relocation resolved

| File | Present in | Resolution |
|---|---|---|
| `README.md`, `.gitignore` | all three | only `RISCV` had modified them; taken from there |
| `debug/sim/sim.do`, `debug/sim/wave.do` | `RISCV` and `DMA` | DMA's copies moved to `dma/debug/sim/` |

Two files, `debug/sim/program_dual.hex` and `debug/sim/program_dual.s`, were
silently dropped by the CPU merge: `master`'s tip commit had deleted every
file in the tree, and Git resolves "deleted on one side, untouched on the
other" as a delete without reporting a conflict. They are the dual-core
regression's test program, so they were restored explicitly.

### Files not carried over

The `DMA` and `SDRAM` branches had simulator output committed: ModelSim `work/`
libraries, `vsim.wlf`, `transcript`, `modelsim.ini`, `.vcd` dumps and a `.bak`
file. These are build artifacts, regenerated on every run, and they are already
covered by `.gitignore`. They were dropped during the relocation.

The `SDRAM` branch also carried a full copy of its sources in the repository
root alongside the copy under `Siemens/`. The two had drifted apart — the last
upload updated only the `Siemens/` copy — so the root copies were stale. Only
`Siemens/` was kept, as `sram/`.

---

## 2. Changes to the DMA block

### 2.1 `active_master_ch` was used before it was declared

**Symptom.** The block did not compile. ModelSim:

```
** Error: mc_dma_top.v(103): (vlog-2730) Undefined variable: 'active_master_ch'.
** Error (suppressible): mc_dma_top.v(117): (vlog-2388) 'active_master_ch'
   already declared in this scope (mc_dma_top) at mc_dma_top.v(103).
```

**Cause.** `mc_dma_top` read `active_master_ch` in four continuous assignments
at line 103, but declared the register at line 117, fourteen lines further
down:

```verilog
    wire fetch_data_valid_ch0 = fetch_data_valid && active_master_ch[0];   // line 103
    ...
    reg [3:0] active_master_ch;                                            // line 117
```

Verilog requires a variable to be declared before it is referenced. The name
is not an implicit net either, because it is later declared as a `reg`, which
is what produces the second, contradictory-looking error.

**Fix.** The declaration and the `always` block that drives it were moved above
the assignments that read them. No logic changed — the same register, the same
reset value, the same update condition.

This bug was present on the branch tip as fetched, not introduced by the
integration.

---

## 3. Changes to the DP-SRAM block

### 3.1 Module `regfile` renamed to `sram_regfile`

**Cause.** Both blocks define a module called `regfile`:

- `hdl/regfile.v` — the CPU's 32 general-purpose registers
- `sram/hdl/regfile.v` — the DP-SRAM's control/status register bank

On their own branches that was fine. In the SoC they compile into the same
library, where the second definition silently overrides the first and the
elaborated design gets the wrong module.

**Fix.** The DP-SRAM's bank was renamed:

| Before | After |
|---|---|
| `sram/hdl/regfile.v` | `sram/hdl/sram_regfile.v` |
| `module regfile #(...)` | `module sram_regfile #(...)` |
| `regfile #(.REG_ADDR_W(3)) u_regfile (...)` in `dp_sram_top.v` | `sram_regfile #(.REG_ADDR_W(3)) u_regfile (...)` |
| `sram/hdl/regfile_test_vectors.txt` | `sram/hdl/sram_regfile_test_vectors.txt` |

The instance name `u_regfile` was left alone: instance names are scoped to
their parent module and cannot collide.

The CPU's `regfile` was not renamed. It is referenced by the CPU's own
testbenches, assertions and documentation, so renaming it would have touched
far more code for no additional benefit.

### 3.2 Port naming (no change needed)

The `SDRAM` branch had already renamed its ports to the `_i`/`_o` convention
the CPU uses (`clk_i`, `rst_n_i`, `a_awaddr_i`, ...) before this integration.
Nothing had to be adapted.

The DMA block still uses unsuffixed `clk` / `rst_n` and `s_axi_*` / `m_axi_*`
port names. These were deliberately **not** renamed: rewriting a block's port
list is a change to that block's interface, and it would invalidate its own
testbenches. The SoC top level connects to the names as they are.

---

## 4. Verification baseline

Before any of the above, the CPU's existing regression was run to establish
that the merge broke nothing:

```
14/14 runs PASSED, 0 FAIL lines, 0 compile errors
```

After the two source fixes, all three blocks compile into a single ModelSim
library with **0 errors and 0 warnings**.

<!-- SECTIONS BELOW ARE APPENDED AS THE INTERCONNECT WORK PROCEEDS -->
