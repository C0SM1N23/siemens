# docs

Shared project material and the faculty internship report. The RTL and its testbenches
stay in [cpu/](../cpu/), [dma/](../dma/), [sram/](../sram/) and [soc/](../soc/).

The Design and Verification Specifications live with the blocks they describe,
in [cpu/docs/](../cpu/docs/), not here.

| Path | What it is |
|---|---|
| [practica/](practica/) | Internship report for the faculty — LaTeX source and the built PDF, plus the completed logbook. |
| [../cpu/docs/tehnic/](../cpu/docs/tehnic/) | Engineering documentation: the register/design-decision write-ups and the older Markdown notes. |
| [brief/](brief/) | Shared/DMA/SRAM Siemens material. CPU/PIC briefs are in [cpu/docs/brief](../cpu/docs/brief/). Restricted material is not committed. |
| [../cpu/docs/diagrame/](../cpu/docs/diagrame/) | drawio sources for the block and FSM drawings, and the presentation notes. |
| [../cpu/docs/note/](../cpu/docs/note/) | Working notes and the changelog. |

## practica/

`Raport_practica_Bunea_Cosmin-Andrei.tex` is a single self-contained file: no
`\input`, no separate preamble. The only external files it needs are the two
university logos in `assets/`.

**It must be built with LuaLaTeX, not pdfLaTeX.** Romanian `ș` and `ț` carry a
comma below, not a cedilla, and only the OpenType font has real glyphs for them;
under pdfLaTeX with T1 they get composed from a base letter plus an accent and
look wrong.

```
cd docs/practica
lualatex Raport_practica_Bunea_Cosmin-Andrei.tex   # three times, for the ToC
```

42 pages. Covers the internship context and the split of work between the three
interns, the RV32I CPU, the interrupt controller and the machine timer, the SoC
integration, and the verification — with the regression numbers read from the
log of a real run rather than quoted from memory.

The faculty report is retained as submitted. Current CPU/SoC technical results
are maintained in the block specifications and verification documents.

## A note on what is committed

`.gitignore` keeps PDFs, Office documents and archives out of the repository,
because `brief/` holds Siemens material marked Restricted. The faculty report
and four authored CPU/PIC specifications are explicit exceptions, committed
with their sources.
