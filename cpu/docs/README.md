# Documentație CPU și PIC · revizia 2.0

Documentele descriu RTL-ul din `cpu/hdl`. Cerințele inițiale sunt în `brief/`;
materialele primite de la Siemens rămân locale și excluse din Git.

| Proiect | Prezentare (6 slide-uri / 10 minute) | Design | Verificare |
|---|---|---|---|
| RV32I | [PowerPoint](presentations/output/RV32I_CPU_Bunea_Cosmin-Andrei.pptx) · [PDF](presentations/output/RV32I_CPU_Bunea_Cosmin-Andrei.pdf) | [PDF](Design_Specification_RV32I_CPU.pdf) | [PDF](Verification_Specification_RV32I_CPU.pdf) |
| PIC | [PowerPoint](presentations/output/PIC_Bunea_Cosmin-Andrei.pptx) · [PDF](presentations/output/PIC_Bunea_Cosmin-Andrei.pdf) | [PDF](Design_Specification_PIC.pdf) | [PDF](Verification_Specification_PIC.pdf) |

Prezentările sunt în română, cu diagrame și nume tehnice în engleză.
Notele fiecărui slide conțin traseul explicației și timpul orientativ.
Conținut: titlu, cerințe și registre esențiale, arhitectură, mediu de verificare,
scenariu critic măsurat, concluzii și reset asincron.

| Fișier / director | Rol |
|---|---|
| `tools/specs.py` | Sursa editabilă pentru cele patru specificații; citește și porturile RTL |
| `*.tex`, `preamble_spec.tex` | Surse LaTeX generate și stilul comun |
| `tools/refined_diagrams.py`, `tools/diagrams.py` | Diagrame SVG, PDF și PNG; blocuri funcționale verificate față de RTL |
| `tools/check_diagrams.py` | Detectarea textului peste trasee și a suprapunerilor dintre etichete |
| `tools/waveforms.py` | Ferestre VCD măsurate, fără inventarea tranzițiilor |
| `waves/manifest.json` | Testbench, interval, semnale, marcaje și SHA-256 al VCD pentru fiecare waveform |
| `presentations/src/build.mjs` | Slide-uri editabile construite cu `@oai/artifact-tool`; SVG încorporat |
| `tools/finalize_pptx.py` | Adaugă imaginile PNG de rezervă pentru aplicațiile fără suport SVG |
| `presentations/src/render_office.ps1` | Randare a PPTX-urilor salvate și verificare a încadrării textului în PowerPoint |
| `tools/verify_delivery.py` | Verifică arhivele PPTX, imaginile încorporate, paginile PDF și proveniența waveform-urilor |

| Pas | Director | Comandă / rezultat |
|---|---|---|
| Instalare dependințe documente | rădăcina repository-ului | Python 3 cu `matplotlib`, `pymupdf`, `pillow`; LuaLaTeX pe PATH |
| Recapturare și reconstruire | rădăcină | `./cpu/docs/build.ps1 -Recapture` — cere ModelSim |
| Reconstruire din figuri existente | rădăcină | `./cpu/docs/build.ps1` |
| PowerPoint | `cpu/docs/presentations` | `node src/build.mjs` — runtime `@oai/artifact-tool` necesar |
| Imagini de rezervă | `cpu/docs/presentations` | `python ../tools/finalize_pptx.py` |
| Randare și PDF | `cpu/docs/presentations` | `./src/render_office.ps1` — PowerPoint instalat |
| Verificare finală | rădăcină | `python cpu/docs/tools/verify_delivery.py` |

Pentru instalări Python separate, `build.ps1 -Python <cale-python>` selectează
interpretul. Verificarea geometrică folosește fonturile Arial din Windows.
`node_modules`, randările de control, logurile și VCD-urile sunt artefacte locale.
SVG/PDF/PNG și manifestul livrate permit consultarea fără simulatoare.

Specificațiile curente înlocuiesc descrierile din notele istorice. Diferența dintre
interfața IRQ din brief-ul CPU (8 surse) și cea implementată cu PIC (16 surse)
este explicită; comparația PULP privește profilul AXI4-Lite testat.
