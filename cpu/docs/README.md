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

The four authored PDFs are committed alongside their sources. Rebuild them
after editing the specifications. The original Siemens briefs remain excluded.

## Requirements and supporting material

- `brief/`: original Siemens CPU PDF and PIC DOCX; source requirements,
  kept locally because they are marked Restricted.
- `tehnic/`: earlier register notes and engineering write-ups.
- `diagrame/`: earlier drawio drawings and presentation drafts.
- `note/`: working notes and historical change records.

The four specifications above are the current technical documents, revision
1.2, 16 September 2026. Older notes and diagrams are retained for context and may
show earlier interfaces. SoC architecture and verification are under
[../../soc/](../../soc/).

Built page counts: CPU design 27, CPU verification 16, PIC design 24, PIC
verification 18. The audit corrected behaviour and evidence without removing
the detailed interface, register and verification-plan sections.

Revision 1.2 re-issues the set after the SoC fabric ordering work. The two
design specifications were re-checked against the RTL and needed no change;
they carry the new revision because the set is issued together. The two
verification specifications changed: the mutation count is now 16, the SoC
regression figure 533 labelled checks, and two rendering faults are fixed --- a
mangled `\texttt` in the PIC document and a misplaced table rule in the CPU
one.
