# Documentație CPU și PIC

Specificațiile și prezentările pentru RTL-ul din [../hdl/](../hdl/): nucleul
RV32I, controlerul de întreruperi (PIC), timerul și interfața de registre
AXI4-Lite. Arhitectura și verificarea SoC sunt în [../../soc/](../../soc/).

## Documente

| Proiect | Specificație de design | Specificație de verificare | Prezentare (7 slide-uri) | Prezentare v2 (8 slide-uri) | Prezentare v3 (7 slide-uri) |
|---|---|---|---|---|---|
| RV32I | [PDF](Design_Specification_RV32I_CPU.pdf) | [PDF](Verification_Specification_RV32I_CPU.pdf) | [PowerPoint](presentations/output/RV32I_CPU_Bunea_Cosmin-Andrei.pptx) · [PDF](presentations/output/RV32I_CPU_Bunea_Cosmin-Andrei.pdf) | [PowerPoint](presentations/output/RV32I_CPU_Bunea_Cosmin-Andrei_v2.pptx) · [PDF](presentations/output/RV32I_CPU_Bunea_Cosmin-Andrei_v2.pdf) | [PowerPoint](presentations/output/RV32I_CPU_Bunea_Cosmin-Andrei_v3.pptx) · [PDF](presentations/output/RV32I_CPU_Bunea_Cosmin-Andrei_v3.pdf) |
| PIC | [PDF](Design_Specification_PIC.pdf) | [PDF](Verification_Specification_PIC.pdf) | [PowerPoint](presentations/output/PIC_Bunea_Cosmin-Andrei.pptx) · [PDF](presentations/output/PIC_Bunea_Cosmin-Andrei.pdf) | [PowerPoint](presentations/output/PIC_Bunea_Cosmin-Andrei_v2.pptx) · [PDF](presentations/output/PIC_Bunea_Cosmin-Andrei_v2.pdf) | [PowerPoint](presentations/output/PIC_Bunea_Cosmin-Andrei_v3.pptx) · [PDF](presentations/output/PIC_Bunea_Cosmin-Andrei_v3.pdf) |

Specificațiile sunt la revizia 2.2, din 23 septembrie 2026. Prezentările sunt
în engleză, gândite pentru aproximativ 10 minute, cu note de prezentator pe
fiecare slide. Varianta v2 adaugă contextul SoC pe slide-ul de titlu și un
slide cu deciziile de proiectare. Varianta v3 pune deciziile pe slide-ul de
arhitectură și verificarea pe două slide-uri: blocul singur, apoi blocul în sistem.

## Conținutul directorului

| Cale | Conținut |
|---|---|
| `*.tex`, `preamble_spec.tex` | Sursele LaTeX ale celor patru specificații, generate de `tools/specs.py`, și stilul comun |
| `figures/` | Arhitectura, mediul de verificare și interfața software pentru CPU și PIC, în SVG, PDF și PNG |
| `waves/` | 13 ferestre de waveform din simulare, în SVG, PDF și PNG |
| `waves/manifest.json` | Pentru fiecare fereastră: testbench-ul, intervalul, semnalele și SHA-256 al VCD-ului sursă |
| `presentations/src/` | Scripturile care construiesc și verifică prezentările |
| `presentations/assets/` | Figurile folosite în v2 și v3 |
| `presentations/output/` | Prezentările PPTX și exportul lor PDF |
| `tools/` | Generatoarele de figuri, waveform-uri și specificații și verificările lor |
| `build.ps1` | Reconstruiește figurile, waveform-urile și cele patru PDF-uri |

## Scripturi

| Script | Rol |
|---|---|
| `tools/refined_diagrams.py` | Desenează diagramele din `figures/`, folosind `diagrams.py` și `software_diagrams.py` |
| `tools/check_diagrams.py` | Oprește build-ul dacă un text se suprapune cu un traseu sau cu altă etichetă |
| `tools/waveforms.py` | Desenează ferestrele din `waves/raw/*.vcd` și scrie `waves/manifest.json` |
| `tools/audit_timing.py` | Compară fiecare tranziție desenată cu VCD-ul sursă și o încadrează ca front de ceas, front + 1 ns sau reset |
| `tools/specs.py`, `tools/spec_content.py` | Conținutul specificațiilor; porturile sunt preluate din `../hdl/` |
| `tools/deck_v2_figures.py` | Figurile v2 din `presentations/assets/` |
| `tools/deck_v3_figures.py` | Figurile v3 din `presentations/assets/`, desenate din VCD-urile de simulare și din `program_isa.hex` |
| `presentations/src/build.mjs` | Prezentările de 7 slide-uri; codul lor este în `build_v2.mjs` |
| `presentations/src/build_deck_v2.mjs` | Prezentările v2, de 8 slide-uri |
| `presentations/src/build_deck_v3.mjs` | Prezentările v3, de 7 slide-uri |
| `tools/finalize_pptx.py` | Adaugă în fiecare PPTX imaginile PNG de rezervă pentru aplicațiile fără suport SVG |
| `presentations/src/render_office.ps1` | Exportă PDF-urile din PowerPoint și semnalează textul sau obiectele ieșite din casete ori din slide |
| `presentations/src/render_saved.mjs` | Aceeași verificare de geometrie, fără PowerPoint |
| `tools/verify_delivery.py` | Verifică PPTX-urile, imaginile încorporate, numărul de pagini din PDF-uri și fișierele celor 13 waveform-uri |

## Construire

Cerințe:

- Python 3 cu `matplotlib`, `pymupdf` și `pillow`; LuaLaTeX pe `PATH`;
  fonturile Arial din Windows, folosite de `check_diagrams.py`.
- ModelSim, doar pentru `build.ps1 -Recapture`.
- Pentru prezentări: Node.js și pachetul `@oai/artifact-tool` 2.7.3 în
  `presentations/node_modules/`. Pachetul nu este publicat pe npm, iar
  `package.json` doar activează modulele ES. Exportul PDF cere PowerPoint.

Specificațiile, din rădăcina repository-ului:

```powershell
./cpu/docs/build.ps1              # figuri + LaTeX
./cpu/docs/build.ps1 -Recapture   # rulează întâi cpu/debug/sim/waves.do (8 bench-uri)
```

Fără VCD-uri în `waves/raw/`, build-ul păstrează waveform-urile din
repository. `-Python <cale>` alege alt interpretor Python.

Prezentările, din `cpu/docs/presentations`:

```powershell
python ../tools/deck_v2_figures.py
python ../tools/deck_v3_figures.py
node src/build.mjs
node src/build_deck_v2.mjs
node src/build_deck_v3.mjs
python ../tools/finalize_pptx.py
./src/render_office.ps1
python ../tools/verify_delivery.py
```

Brief-urile Siemens (`brief/`) și notele de lucru (`note/`, `tehnic/`,
`diagrame/`) sunt păstrate local și nu intră în Git, la fel ca VCD-urile din
`waves/raw/`, `presentations/node_modules/`, randările din
`presentations/scratch/` și fișierele intermediare LaTeX.
