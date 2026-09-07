# cpu/docs

The Design and Verification Specifications for the blocks implemented in
[../hdl/](../hdl/): the RV32I core and the programmable interrupt controller.
They sit next to the RTL they describe, so a change to a block and the change to
its specification land in the same place.

| Document | Subject |
|---|---|
| `Design_Specification_RV32I_CPU.tex` | The three-stage core: pipeline, interfaces, CSR space, submodules. |
| `Verification_Specification_RV32I_CPU.tex` | The environment that verifies it, and the verification plan. |
| `Design_Specification_PIC.tex` | The interrupt controller: priority banding, nesting, deadline escalation, register map. |
| `Verification_Specification_PIC.tex` | The environment that verifies it, and the verification plan. |
| `preamble_spec.tex` | Shared preamble: page layout, fonts, colours, the identification block. |

All four follow the same table of contents, taken from the template the
department uses for design and verification specifications.

## Building

**LuaLaTeX, not pdfLaTeX** — the preamble loads OpenType fonts through
`fontspec`. Three passes, for the table of contents and the cross-references:

```
cd cpu/docs
lualatex Design_Specification_RV32I_CPU.tex   # three times
```

Each document is self-contained apart from `preamble_spec.tex`, which it pulls
in with `\input`. There are no external figures: every diagram is TikZ in the
document source, so a drawing is corrected in the same file as the text it
belongs to.

The built PDFs are not committed — `.gitignore` keeps PDFs out of the
repository. Rebuild them from the sources here.
