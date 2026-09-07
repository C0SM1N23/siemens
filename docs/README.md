# docs

Everything that is a document rather than a design. The RTL and its testbenches
stay in [cpu/](../cpu/), [dma/](../dma/), [sram/](../sram/) and [soc/](../soc/).

The Design and Verification Specifications live with the blocks they describe,
in [cpu/docs/](../cpu/docs/), not here.

| Path | What it is |
|---|---|
| [practica/](practica/) | Internship report for the faculty — LaTeX source and the built PDF, plus the completed logbook. |
| [tehnic/](tehnic/) | Engineering documentation: the register/design-decision write-ups and the older Markdown notes. |
| [brief/](brief/) | The Siemens material the work started from. Marked Restricted — not committed. |
| [diagrame/](diagrame/) | drawio sources for the block and FSM drawings, and the presentation notes. |
| [note/](note/) | Working notes and the changelog. |

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

It describes the project as it stands, not how it got there: no "the first
version did X" narrative anywhere.

## A note on what is committed

`.gitignore` keeps PDFs, Office documents and archives out of the repository,
because `brief/` holds Siemens material marked Restricted. The faculty report is
the exception and is committed explicitly — it is the student's own work, and
losing it with a `git clean` would be expensive.
