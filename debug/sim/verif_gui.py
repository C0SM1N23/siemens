#!/usr/bin/env python3
# verif_gui.py — Tkinter front-end for the verification flows in debug/sim.
#
# One source of truth: every button maps to exactly the command you would type
# by hand (sim.do / regress.do / run_verilator.sh / asm.py). The GUI only adds
# streaming output, a verdict, and progress — it never invents its own flow.
#
# Design points (the "chichite" list from the plan):
# - ModelSim's exit code lies (quit -f returns 0 on test failures), so verdicts
#   are computed by PARSING: exact banner counts + zero "FAIL:" lines.
# - Infra errors (vsim missing, vlog failed, stale lock) are a third state
#   (orange), never confused with a red test failure.
# - stdin=DEVNULL everywhere: nothing can hang waiting for input.
# - Process TREE kill on Stop (taskkill /T /F) — vsim spawns children.
# - Stale work/_lock is auto-removed before a run if no vsim process exists.
# - Output is read on a worker thread, queued, and drained in batches on the
#   Tk main thread; ANSI stripped; encoding errors replaced, never crash.
# - The "ModelSim TB" button opens the real ModelSim GUI (compile + wave.do +
#   run) so the waveforms are visible; its output is tailed from the
#   transcript file so the verdict still lands in this window.
# - Auto-assemble: if a .s is newer than its .hex, asm.py runs first.

import os
import re
import sys
import time
import glob
import queue
import shutil
import threading
import subprocess
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from pathlib import Path
from datetime import datetime

SIM_DIR = Path(__file__).resolve().parent
IS_WIN = os.name == "nt"

# vsim resolution order: PATH, then this env var (set it on your own machine
# instead of editing the script), then a best-effort guess at the usual
# ModelSim/Questa - Intel FPGA (Starter) Edition install roots. None of this
# is machine-specific, so the script works unedited on any teammate's PC.
VSIM_ENV_VAR = "VSIM_EXE"
VSIM_GLOBS = [
    r"C:\intelFPGA*\*\modelsim_ase\win32aloem\vsim.exe",
    r"C:\intelFPGA_lite\*\modelsim_ase\win32aloem\vsim.exe",
    r"C:\altera*\*\modelsim_ase\win32aloem\vsim.exe",
    r"D:\intelFPGA*\*\modelsim_ase\win32aloem\vsim.exe",
    r"D:\altera*\*\modelsim_ase\win32aloem\vsim.exe",
]
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# TB defaults — only values CHANGED from these are emitted as -G overrides
PARAM_DEFAULTS = {
    "imem_RL": 0, "imem_SP": 0, "imem_SEED": 11,
    "dmem_RL": 1, "dmem_WL": 1, "dmem_SP": 0, "dmem_SEED": 23,
    "ENTRIES": 128, "RAS_DEPTH": 8,
}
PARAM_GPATH = {
    "imem_RL":   "/tb_cpu_axi/imem_inst/READ_LAT",
    "imem_SP":   "/tb_cpu_axi/imem_inst/STALL_PROB",
    "imem_SEED": "/tb_cpu_axi/imem_inst/SEED",
    "dmem_RL":   "/tb_cpu_axi/dmem_inst/READ_LAT",
    "dmem_WL":   "/tb_cpu_axi/dmem_inst/WRITE_LAT",
    "dmem_SP":   "/tb_cpu_axi/dmem_inst/STALL_PROB",
    "dmem_SEED": "/tb_cpu_axi/dmem_inst/SEED",
    "ENTRIES":   "/tb_cpu_axi/uut/branch_predictor_inst/ENTRIES",
    "RAS_DEPTH": "/tb_cpu_axi/uut/branch_predictor_inst/RAS_DEPTH",
}

INFRA_TOKENS = (
    "vlog failed", "vsim failed", "Giving up waiting on lock",
    "Error loading design", "not recognized as an internal",
    "cannot open", "No such file or directory", "command not found",
    "no installed distributions",
)

STATUS_COLOR = {"PASS": "#2e9e4f", "FAIL": "#d23131",
                "INFRA": "#e08a00", "RUN": "#888888", "IDLE": "#666666"}

# ------------------------------------------------------------ info tab text
INFO_PAGES = [
    ("ModelSim TB + waveforms", """\
Ce face: deschide ModelSim (GUI), compileaza RTL + testbench, incarca
tb_cpu_axi cu semnalele AXI in fereastra Wave (wave.do) si ruleaza programul
de test pana la capat. Verdictul apare aici (transcriptul e urmarit live),
iar tu ramai in ModelSim sa analizezi waveform-urile.

Ce verifica (90 de check-uri, program self-checking):
  - toate clasele de instructiuni RV32I + forwarding S3->S2 (lanturi
    dependente, CPI masurat: 33 cicluri / 33 instructiuni)
  - load/store pe toate latimile: WSTRB pe byte-lane (SB/SH/SW), extractie
    cu sign/zero-extend (LB/LBU/LH/LHU)
  - TOATE cauzele de trap sincron (0..7, 11), cu numarare EXACTA:
    17 intrari in handlerul direct, 26 in total (contorul hardware mhpm6)
  - instructiune ilegala fara efecte secundare (store ilegal nu atinge
    memoria), acces misaligned fara tranzactie AXI emisa
  - erori de bus (SLVERR/DECERR) -> access fault precis, si de la
    periferice reale (PIC/mtimer), nu doar de la modelul de memorie
  - CSR-uri: forme immediate, negative (CSR inexistent, scriere in
    read-only), mtval cu adresa fault-ului, misa/mvendorid/marchid/mimpid
  - intreruperi prin PIC-ul real: prioritate, mascare independenta
    (PIC enable vs mie), suppression in-service, irq in timpul unui
    stall AXI (ack tinut pana la granita de instructiune)
  - mtvec vectored (irq -> BASE+4*cauza, exceptii -> BASE)
  - WFI: adoarme fetch-ul (ibus tace, masurat), mepc = wfi+4 la trezire,
    fall-through cand MIE=0; mtimer cap-coada (armare fara false fire)
  - predictor: bucle invatate, aliasing BTB (3 branch-uri pe acelasi
    index), RAS cu 3 call-site-uri + lant imbricat
  - monitoare de protocol AXI pe toate bus-urile, in fiecare ciclu

Waveform-urile arata AXI la ambele capete: IBUS (CPU<->imem), DBUS la
masterul CPU, apoi ce vede fiecare slave (dmem / PIC / mtimer), plus
liniile de intrerupere. Transferul = ciclul cu VALID si READY sus simultan."""),

    ("Regression 5-cfg", """\
Ce face: ruleaza IN CONSOLA (fara GUI) aceeasi suita de 90 de check-uri in
5 configuratii diferite, apoi testul dual-core. Progresul apare ca
"faza X/5" in bara de status.

Cele 5 rulari:
  1. latente default (aici e activ si check-ul de CPI: 33/33 cicluri)
  2. latente AXI mari fixe (imem RL=2, dmem RL=3/WL=2) - stall-uri lungi
  3. backpressure aleator pe READY, seed set A (imem 25%, dmem 35%)
  4. backpressure aleator pe READY, seed set B (imem 40%, dmem 20%)
  5. dual-core: 2 CPU-uri + memorie partajata prin arbitru

De ce conteaza: aceleasi teste sub timing diferit exerseaza alte cai
(holding register, discard pe redirect, colectare AW/W in orice ordine).
Fiecare rulare isi afiseaza parametrii CITITI din designul elaborat, ca o
suprascriere ignorata sa nu poata trece drept verde.

Verdict: 4x "ALL TESTS PASSED" + 1x "DUAL-CORE TEST PASSED" + zero FAIL."""),

    ("Dual-core", """\
Ce face: ruleaza doar testul dual-core (tb_dual_core), in consola.

Scenariul: doua instante cpu_top (HART_ID 0 si 1), fiecare cu memoria ei
de instructiuni, partajand o memorie de date printr-un arbitru AXI
round-robin. Cele doua nuclee isi fac handshake prin flag-uri in memoria
partajata (fara LR/SC - merge pentru ca fiecare core e in-order cu
tranzactii blocante, deci secvential consistent).

Ce dovedeste: core-ul e instantiabil de N ori fara stare partajata,
mhartid diferentiaza software-ul, si doua mastere AXI blocante
progreseaza printr-un slave arbitrat fara deadlock si fara coruperi.

Verdict: "DUAL-CORE TEST PASSED" + monitorul de bus partajat curat."""),

    ("Verilator SVA + coverage", """\
Ce face: ruleaza acelasi tb_cpu_axi prin Verilator (in WSL), cu doua
straturi pe care ModelSim ASE nu le poate compila:

1. SVA (SystemVerilog Assertions) - contractele scrise ca proprietati
   temporale, legate cu `bind` peste RTL (RTL-ul nu e modificat):
   - protocol AXI pe toate 4 porturile: VALID/payload stabile sub READY
     intarziat, raspuns doar dupa adresa, max 1 tranzactie outstanding,
     fara EXOKAY, VALID interzis in reset
   - promisiuni de pipeline: claim (ack) si eoi = puls de exact 1 ciclu,
     intreruperi doar la granite de instructiune, instructiunea care da
     trap nu comite, x0 citeste 0, WSTRB doar in forme legale SB/SH/SW
   - contractul PIC: cpu_irq/cpu_irq_vec = oferta inregistrata a sursei
     celei mai prioritare, preemptare stricta peste varful stivei de
     nesting, adancime marginita de NEST_MAX
   Diferenta fata de teste: testul verifica UN scenariu; asertiunea
   verifica invariantul in TOATE scenariile, in fiecare ciclu.

2. Functional coverage - masoara ce situatii chiar s-au intamplat:
   92 de bins (fiecare cauza de trap, fiecare canal de irq, erori pe
   fiecare canal AXI, forwarding, backpressure...). Tinta: 88/92 (95%);
   cele 4 lipsa sunt deliberate (negativele ch5 + backpressure acoperit
   de configuratiile din regresie). Regresia are gate: sub prag = FAIL.

Verdict: exit code 0 + "COVERAGE GATE PASSED" (aici exit code-ul e fiabil,
scriptul are set -e). Daca simularea nici n-a pornit (build intrerupt cu
Stop, WSL cazut, compilare g++ omorata), verdictul e MEDIU (portocaliu),
nu FAIL — zero linii PASS:/FAIL: inseamna ca nu s-a testat nimic.

Nota: prima rulare dupa un Assemble care chiar schimba programul
recompileaza tot modelul Verilator (cateva minute in WSL). asm.py nu mai
atinge *_sym.vh cand continutul e neschimbat, deci un RUN ALL fara
modificari de .s pastreaza build-ul incremental."""),

    ("Assemble", """\
Ce face: asambleaza programele de test din sursa in imaginile pe care le
incarca simularea:

  program_axi.s  -> program_axi.hex  + program_axi_sym.vh
  program_dual.s -> program_dual.hex + program_dual_sym.vh

Fisierul *_sym.vh contine adresele etichetelor din program - testbench-ul
le foloseste in check-uri, deci o modificare de cod care muta o eticheta
isi actualizeaza singura verificarile.

Cand trebuie rulat: DOAR dupa ce editezi un .s. Checkbox-ul
"auto-assemble" face asta automat cand .s e mai nou decat .hex, deci in
mod normal nu apesi butonul manual."""),

    ("RUN ALL", """\
Ce face: lantul complet, secvential:

  1. Assemble (regenereaza hex + sym)
  2. Regression 5-cfg (ModelSim: 5 configuratii + dual-core)
  3. Verilator SVA + coverage (WSL)

Asta e verificarea "totul deodata" - echivalentul lui make asm +
make modelsim + make test, cu verdict per pas in tabelul de rezultate.

Daca un pas da eroare de MEDIU (portocaliu: vsim lipsa, vlog failed,
lock), lantul se opreste - nu are sens sa continue pe un mediu stricat.
Un FAIL de test (rosu) nu opreste lantul: celelalte fluxuri tot ruleaza,
ca sa vezi tabloul complet."""),

    ("Clean / Stop / verdicte", """\
Clean: sterge artefactele de build (work/, obj_dir/, cov_annotated/,
coverage.dat, transcript, *.log). Sursele si hex-urile raman. Util cand
vrei o recompilare de la zero sau dupa un crash ciudat.

Stop: omoara TOT arborele de procese al rularii curente (vsim isi
porneste copii - taskkill /T). Dupa stop, lock-ul work/_lock ramas orfan
e sters automat, ca urmatoarea rulare (de aici sau din terminal) sa nu
se blocheze.

Cum se decide verdictul (important: exit code-ul ModelSim MINTE - quit -f
intoarce 0 si cand testele pica):
  - PASS (verde)     banner-ele asteptate numarate exact
                     ("ALL TESTS PASSED" x4 + dual la regresie) si zero
                     linii "FAIL:"
  - FAIL (rosu)      exista "FAIL:" sau lipsesc bannere - un test a picat
  - INFRA (portocaliu) mediul e stricat: vsim negasit, eroare de
                     compilare, lock blocat. NU inseamna ca RTL-ul e
                     gresit - repara mediul si ruleaza din nou.

Parametrii (-G) din panou se aplica DOAR rularii "ModelSim TB":
latente/backpressure pe modelele de memorie si ENTRIES/RAS_DEPTH pe
predictor. Valorile default sunt exact cele din testbench; doar ce
schimbi e trimis ca override."""),
]


def find_vsim():
    p = shutil.which("vsim")
    if p:
        return p
    env = os.environ.get(VSIM_ENV_VAR)
    if env and Path(env).is_file():
        return env
    for pattern in VSIM_GLOBS:
        hits = sorted(glob.glob(pattern))
        if hits:
            return hits[-1]     # highest version string sorts last
    return None


def win_to_wsl(path: Path) -> str:
    # N:\siemens\debug\sim -> /mnt/n/siemens/debug/sim
    s = str(path)
    drive, rest = s[0].lower(), s[2:].replace("\\", "/")
    return f"/mnt/{drive}{rest}"


def popen_kwargs():
    kw = dict(cwd=str(SIM_DIR), stdin=subprocess.DEVNULL,
              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
              text=True, encoding="utf-8", errors="replace", bufsize=1)
    if IS_WIN:
        kw["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    return kw


def kill_tree(proc):
    if proc is None or proc.poll() is not None:
        return
    if IS_WIN:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                       capture_output=True)
    else:
        proc.terminate()


def vsim_running() -> bool:
    if not IS_WIN:
        return False
    out = subprocess.run(["tasklist"], capture_output=True, text=True).stdout
    return ("vsim" in out) or ("vish" in out)


# ---------------------------------------------------------------- verdicts
# ModelSim: exit code is meaningless -> parse. PASS needs exact banner counts
# AND zero FAIL: AND no infra token. Infra tokens win (orange).

def _classify(lines, need_all, need_dual, extra_ok=None):
    txt = "\n".join(lines)
    for tok in INFRA_TOKENS:
        if tok in txt:
            return "INFRA", f"eroare de mediu: '{tok}'"
    n_all = txt.count("ALL TESTS PASSED")
    n_dual = txt.count("DUAL-CORE TEST PASSED")
    n_fail = sum(1 for l in lines if "FAIL:" in l)
    n_pass = sum(1 for l in lines if "PASS:" in l)
    if n_fail == 0 and n_all >= need_all and n_dual >= need_dual \
            and (extra_ok is None or extra_ok(txt)):
        return "PASS", f"{n_pass} checks, {n_all + n_dual} banner(e)"
    return "FAIL", f"{n_fail} FAIL, bannere {n_all}+{n_dual} " \
                   f"(necesar {need_all}+{need_dual})"


def verdict_sim(lines, rc):
    return _classify(lines, 1, 0)


def verdict_regress(lines, rc):
    st, sm = _classify(lines, 4, 1,
                       extra_ok=lambda t: "regression done" in t)
    if st == "PASS":
        sm = "5/5 configuratii, " + sm
    return st, sm


def verdict_dual(lines, rc):
    return _classify(lines, 0, 1)


def verdict_verilator(lines, rc):
    txt = "\n".join(lines)
    for tok in INFRA_TOKENS:
        if tok in txt:
            return "INFRA", f"eroare de mediu: '{tok}'"
    m = re.search(r"\[FCOV\] ---- (\d+)/(\d+) bins hit \((\d+)%\)", txt)
    fcov = f", FCOV {m.group(1)}/{m.group(2)} ({m.group(3)}%)" if m else ""
    if rc == 0 and "COVERAGE GATE PASSED" in txt and "ALL TESTS PASSED" in txt:
        return "PASS", "SVA curat" + fcov
    if rc != 0 and "%Error" in txt:
        return "FAIL", "asertiune picata / test FAIL" + fcov
    # exit != 0 without a single PASS:/FAIL: line means the simulation never
    # started (build intrerupt, WSL cazut, Stop in timpul compilarii g++) —
    # asta e mediu, nu un test picat
    sim_ran = any(l.startswith(("PASS:", "FAIL:")) for l in lines)
    if rc != 0 and not sim_ran:
        return "INFRA", "build intrerupt — simularea n-a pornit " \
                        "(exit != 0, zero linii de sim)"
    return ("FAIL", "gate/teste picate" + fcov) if rc else \
           ("FAIL", "banner lipsa" + fcov)


def verdict_asm(lines, rc):
    return ("PASS", "hex + sym regenerate") if rc == 0 else \
           ("INFRA", "asamblare esuata (vezi log)")


# ------------------------------------------------------------------- app
class App(tk.Tk):
    POLL_MS = 60
    MAX_SHOWN_LINES = 8000

    def __init__(self):
        super().__init__()
        self.title("RV32I — Verification Runner")
        self.geometry("1060x720")
        self.minsize(880, 560)

        self.vsim = find_vsim()
        self.wsl = shutil.which("wsl")

        self.q = queue.Queue()
        self.proc = None
        self.busy = False
        self.chain = []            # remaining jobs of a RUN ALL chain
        self.abort_chain = False
        self.t_start = None
        self.full_log = []         # complete log (Save writes this)
        self.results = {}          # key -> treeview iid
        self._busy_label = ""
        self._status_base = ""

        self._style()
        self._build_ui()
        self._startup_checks()
        self.after(self.POLL_MS, self._poll)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    # ---------------------------------------------------------- style
    def _style(self):
        st = ttk.Style(self)
        try:
            st.theme_use("clam")
        except tk.TclError:
            pass
        bg = "#f2f3f5"
        accent = "#3d6fb4"
        self.configure(background=bg)
        st.configure(".", background=bg, font=("Segoe UI", 9))
        st.configure("TNotebook", background=bg, borderwidth=0)
        st.configure("TNotebook.Tab", padding=(14, 6),
                     font=("Segoe UI", 10))
        st.configure("Head.TLabel", font=("Segoe UI Semibold", 14),
                     background=bg)
        st.configure("Hint.TLabel", foreground="#778", background=bg,
                     font=("Segoe UI", 8))
        # ONE button style for every action; RUN ALL differs only by color
        st.configure("Run.TButton", font=("Segoe UI", 10), padding=(12, 7))
        st.configure("Accent.TButton", font=("Segoe UI Semibold", 10),
                     padding=(12, 7), background=accent, foreground="white")
        st.map("Accent.TButton",
               background=[("active", "#2f588f"), ("disabled", "#a9bdd8")],
               foreground=[("disabled", "#eef")])
        st.configure("Util.TButton", font=("Segoe UI", 9), padding=(9, 4))
        st.configure("Status.TFrame", background="#e6e8eb")
        st.configure("Status.TLabel", background="#e6e8eb",
                     font=("Segoe UI", 9))
        st.configure("Treeview", rowheight=22, font=("Segoe UI", 9),
                     fieldbackground="#fbfbfc", background="#fbfbfc")
        st.configure("Treeview.Heading", font=("Segoe UI Semibold", 9))

    # ------------------------------------------------------------ UI
    def _build_ui(self):
        # header
        head = ttk.Frame(self)
        head.pack(fill="x", padx=12, pady=(10, 2))
        ttk.Label(head, text="RV32I — Verification Runner",
                  style="Head.TLabel").pack(side="left")

        # notebook: Rulare | Despre verificari
        self.nb = ttk.Notebook(self)
        self.nb.pack(fill="both", expand=True, padx=10, pady=(6, 0))
        self.tab_run = ttk.Frame(self.nb)
        self.tab_info = ttk.Frame(self.nb)
        self.nb.add(self.tab_run, text="  Rulare  ")
        self.nb.add(self.tab_info, text="  Despre verificari  ")
        self._build_run_tab(self.tab_run)
        self._build_info_tab(self.tab_info)

        # status bar (bottom, always visible)
        sb = ttk.Frame(self, style="Status.TFrame")
        sb.pack(fill="x", side="bottom")
        self.status_dot = tk.Label(sb, text="●", fg=STATUS_COLOR["IDLE"],
                                   bg="#e6e8eb", font=("Segoe UI", 11))
        self.status_dot.pack(side="left", padx=(10, 2), pady=2)
        self.status_lbl = ttk.Label(sb, text="inactiv — alege o rulare",
                                    style="Status.TLabel")
        self.status_lbl.pack(side="left")
        self.elapsed_lbl = ttk.Label(sb, text="", style="Status.TLabel")
        self.elapsed_lbl.pack(side="right", padx=10)
        self.pbar = ttk.Progressbar(sb, length=180, mode="determinate")
        self.pbar.pack(side="right", padx=6, pady=3)

    def _build_run_tab(self, root):
        pad = dict(padx=8, pady=4)

        # -- actions: one uniform row, equal widths; RUN ALL differs only
        #    by its accent color
        bf = ttk.LabelFrame(root, text=" Simulari ")
        bf.pack(fill="x", **pad)
        self.buttons = {}

        row = ttk.Frame(bf)
        row.pack(fill="x", padx=4, pady=(8, 4))
        actions = [
            ("msgui",   "ModelSim TB + waveforms", ["msgui"],
             "Run.TButton"),
            ("regress", "Regression 5-cfg",        ["regress"],
             "Run.TButton"),
            ("dual",    "Dual-core",               ["dual"],
             "Run.TButton"),
            ("vlt",     "Verilator SVA + cov",     ["vlt"],
             "Run.TButton"),
            ("all",     "▶ RUN ALL",               ["asm", "regress", "vlt"],
             "Accent.TButton"),
        ]
        for col, (key, text, keys, style_) in enumerate(actions):
            b = ttk.Button(row, text=text, style=style_,
                           command=lambda k=keys: self._start(k))
            b.grid(row=0, column=col, padx=4, sticky="ew")
            row.columnconfigure(col, weight=1, uniform="act")
            self.buttons[key] = b

        uf = ttk.Frame(bf)
        uf.pack(fill="x", padx=4, pady=(2, 8))
        b = ttk.Button(uf, text="Assemble", style="Util.TButton",
                       command=lambda: self._start(["asm"]))
        b.pack(side="left", padx=4)
        self.buttons["asm"] = b
        b = ttk.Button(uf, text="Clean", style="Util.TButton",
                       command=self._clean)
        b.pack(side="left", padx=4)
        self.buttons["clean"] = b
        self.stop_btn = ttk.Button(uf, text="■ Stop", state="disabled",
                                   style="Util.TButton", command=self._stop)
        self.stop_btn.pack(side="left", padx=16)
        self.auto_asm = tk.BooleanVar(value=True)
        ttk.Checkbutton(uf, text="auto-assemble cand .s e mai nou ca .hex",
                        variable=self.auto_asm).pack(side="left", padx=12)

        # -- parameters (apply to the ModelSim TB run)
        pf = ttk.LabelFrame(root, text=" Parametri — se aplica rularii "
                                       "„ModelSim TB + waveforms” ")
        pf.pack(fill="x", **pad)
        self.pvars = {}
        groups = [("imem", ["imem_RL", "imem_SP", "imem_SEED"]),
                  ("dmem", ["dmem_RL", "dmem_WL", "dmem_SP", "dmem_SEED"]),
                  ("predictor", ["ENTRIES", "RAS_DEPTH"])]
        col = 0
        for gname, keys in groups:
            ttk.Label(pf, text=gname + ":",
                      font=("Segoe UI Semibold", 9)).grid(
                row=0, column=col, padx=(10, 2), pady=(8, 2), sticky="e")
            col += 1
            for k in keys:
                short = k.split("_", 1)[-1] if "_" in k else k
                ttk.Label(pf, text=short).grid(row=0, column=col,
                                               padx=(6, 1), pady=(8, 2),
                                               sticky="e")
                v = tk.StringVar(value=str(PARAM_DEFAULTS[k]))
                self.pvars[k] = v
                ttk.Entry(pf, textvariable=v, width=5).grid(
                    row=0, column=col + 1, pady=(8, 2))
                col += 2
        ttk.Label(pf, style="Hint.TLabel",
                  text="RL/WL = latenta de raspuns a memoriei (cicluri) · "
                       "SP = probabilitate de stall READY, % (backpressure) · "
                       "SEED = samanta stall-urilor aleatoare · "
                       "ENTRIES/RAS_DEPTH = dimensiunea predictorului. "
                       "Se trimit ca -G doar valorile diferite de default; "
                       "RTL-ul nu se modifica.").grid(
            row=1, column=0, columnspan=col, sticky="w", padx=10, pady=(0, 6))

        # -- results
        rf = ttk.LabelFrame(root, text=" Rezultate ")
        rf.pack(fill="x", **pad)
        cols = ("actiune", "status", "detalii", "ora")
        self.tree = ttk.Treeview(rf, columns=cols, show="headings", height=5)
        for c, w, t in zip(cols, (190, 80, 560, 80),
                           ("Actiune", "Status", "Detalii", "Ora")):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor="w")
        for st_, c_ in STATUS_COLOR.items():
            self.tree.tag_configure(st_, foreground=c_)
        self.tree.pack(fill="x", padx=4, pady=4)

        # -- log
        lf = ttk.LabelFrame(root, text=" Log (live) ")
        lf.pack(fill="both", expand=True, **pad)
        top = ttk.Frame(lf)
        top.pack(fill="x", padx=4, pady=(4, 0))
        ttk.Label(top, text="Cauta:").pack(side="left")
        self.find_var = tk.StringVar()
        fe = ttk.Entry(top, textvariable=self.find_var, width=28)
        fe.pack(side="left", padx=4)
        fe.bind("<Return>", lambda e: self._find())
        ttk.Button(top, text="Next", style="Run.TButton",
                   command=self._find).pack(side="left")
        ttk.Button(top, text="Save log", style="Run.TButton",
                   command=self._save).pack(side="right", padx=2)
        ttk.Button(top, text="Clear", style="Run.TButton",
                   command=self._clear).pack(side="right", padx=2)

        wrap = ttk.Frame(lf)
        wrap.pack(fill="both", expand=True, padx=4, pady=4)
        self.text = tk.Text(wrap, wrap="none", state="disabled",
                            font=("Consolas", 9), background="#14161a",
                            foreground="#d6d8dd", insertbackground="#d6d8dd",
                            relief="flat")
        ys = ttk.Scrollbar(wrap, orient="vertical", command=self.text.yview)
        self.text.configure(yscrollcommand=ys.set)
        ys.pack(side="right", fill="y")
        self.text.pack(fill="both", expand=True)
        self.text.tag_configure("hit", background="#5a5220")

    def _build_info_tab(self, root):
        pane = ttk.Frame(root)
        pane.pack(fill="both", expand=True, padx=10, pady=10)

        # left: flat menu of pages, same accent as the rest of the app
        left = ttk.Frame(pane)
        left.pack(side="left", fill="y")
        ttk.Label(left, text="VERIFICARI",
                  font=("Segoe UI Semibold", 8),
                  foreground="#889").pack(anchor="w", padx=2, pady=(2, 6))
        self.info_list = tk.Listbox(left, width=27, height=18,
                                    font=("Segoe UI", 10), relief="flat",
                                    borderwidth=0, highlightthickness=0,
                                    background="#f2f3f5",
                                    selectbackground="#3d6fb4",
                                    selectforeground="white",
                                    activestyle="none", exportselection=False)
        self.info_list.pack(fill="y", expand=True)
        for title, _ in INFO_PAGES:
            self.info_list.insert("end", "  " + title)
        self.info_list.bind("<<ListboxSelect>>", self._show_info)

        # right: a white "card" with the page content
        card = tk.Frame(pane, background="#fbfbfc",
                        highlightbackground="#d8dade", highlightthickness=1)
        card.pack(side="left", fill="both", expand=True, padx=(12, 0))
        self.info_title = tk.Label(card, text="", background="#fbfbfc",
                                   font=("Segoe UI Semibold", 13),
                                   anchor="w")
        self.info_title.pack(fill="x", padx=16, pady=(12, 0))
        tk.Frame(card, background="#3d6fb4", height=2).pack(
            fill="x", padx=16, pady=(4, 0))
        wrap = ttk.Frame(card)
        wrap.pack(fill="both", expand=True, padx=2, pady=(4, 2))
        self.info_text = tk.Text(wrap, wrap="word", state="disabled",
                                 font=("Segoe UI", 10), relief="flat",
                                 background="#fbfbfc", padx=14, pady=8)
        ys = ttk.Scrollbar(wrap, orient="vertical",
                           command=self.info_text.yview)
        self.info_text.configure(yscrollcommand=ys.set)
        ys.pack(side="right", fill="y")
        self.info_text.pack(fill="both", expand=True)
        self.info_list.selection_set(0)
        self._show_info()

    def _show_info(self, _ev=None):
        sel = self.info_list.curselection()
        if not sel:
            return
        title, body = INFO_PAGES[sel[0]]
        self.info_title.config(text=title)
        self.info_text.configure(state="normal")
        self.info_text.delete("1.0", "end")
        self.info_text.insert("1.0", body)
        self.info_text.configure(state="disabled")

    def _startup_checks(self):
        if not self.vsim:
            for k in ("msgui", "regress", "dual"):
                self.buttons[k].config(state="disabled")
            self._log_line("[gui] vsim negasit (nici in PATH, nici in "
                           f"${VSIM_ENV_VAR}, nici in locatiile uzuale de "
                           "instalare) — seteaza variabila de mediu "
                           f"{VSIM_ENV_VAR}=<cale catre vsim.exe> sau adauga "
                           "vsim in PATH — butoanele ModelSim sunt oprite")
        if not self.wsl:
            self.buttons["vlt"].config(state="disabled")
            self._log_line("[gui] wsl negasit — butonul Verilator e oprit")
        self._clear_stale_lock(startup=True)

    # ----------------------------------------------------------- jobs
    def _gflags(self):
        out = []
        for k, dv in PARAM_DEFAULTS.items():
            try:
                v = int(self.pvars[k].get())
            except ValueError:
                continue
            if v != dv:
                out.append(f"-G{PARAM_GPATH[k]}={v}")
        return " ".join(out)

    def _job(self, key):
        """Job spec: exactly the command you'd type by hand."""
        if key == "asm":
            return dict(key=key, label="Assemble", mode="stream",
                        argv=[sys.executable, "asm.py", "program_axi.s",
                              "program_axi.hex"],
                        argv2=[sys.executable, "asm.py", "program_dual.s",
                               "program_dual.hex"],
                        verdict=verdict_asm)
        if key == "msgui":
            g = self._gflags()
            # mirrors sim.do, with optional -G overrides on the inner vsim
            do = ("do compile.do; "
                  f"vsim -voptargs=+acc {g} work.tb_cpu_axi; "
                  "do wave.do; run -all; wave zoom full")
            return dict(key=key, label="ModelSim TB (GUI)", mode="gui_tail",
                        argv=[self.vsim, "-do", do], verdict=verdict_sim)
        if key == "regress":
            return dict(key=key, label="Regression 5-cfg", mode="stream",
                        argv=[self.vsim, "-c", "-do",
                              "do regress.do; quit -f"],
                        verdict=verdict_regress,
                        progress=re.compile(r"=== run (\d)/5: (.*?) ==="))
        if key == "dual":
            return dict(key=key, label="Dual-core", mode="stream",
                        argv=[self.vsim, "-c", "-do",
                              "do compile.do; "
                              "vsim -onfinish stop work.tb_dual_core; "
                              "run -all; quit -f"],
                        verdict=verdict_dual)
        if key == "vlt":
            wd = win_to_wsl(SIM_DIR)
            return dict(key=key, label="Verilator SVA+cov", mode="stream",
                        argv=["wsl", "-e", "bash", "-lc",
                              f"cd {wd} && stdbuf -oL -eL bash "
                              "run_verilator.sh"],
                        verdict=verdict_verilator)
        raise KeyError(key)

    def _needs_asm(self):
        for s, h in (("program_axi.s", "program_axi.hex"),
                     ("program_dual.s", "program_dual.hex")):
            sp, hp = SIM_DIR / s, SIM_DIR / h
            if sp.exists() and (not hp.exists()
                                or sp.stat().st_mtime > hp.stat().st_mtime):
                return True
        return False

    def _start(self, keys):
        if self.busy:
            return
        # auto-assemble in front of any sim job, if sources are newer
        if self.auto_asm.get() and "asm" not in keys and self._needs_asm() \
                and any(k in ("msgui", "regress", "dual", "vlt") for k in keys):
            keys = ["asm"] + keys
            self._log_line("[gui] .s mai nou decat .hex -> rulez Assemble intai")
        self.chain = list(keys)
        self.abort_chain = False
        self._next_in_chain()

    def _next_in_chain(self):
        if not self.chain or self.abort_chain:
            self._set_busy(False)
            return
        key = self.chain.pop(0)
        job = self._job(key)
        self._set_busy(True, job["label"])
        self._result_row(job, "RUN", "ruleaza...")
        if key in ("msgui", "regress", "dual"):
            self._clear_stale_lock()
        threading.Thread(target=self._worker, args=(job,),
                         daemon=True).start()

    # --------------------------------------------------------- worker
    def _worker(self, job):
        lines = []

        def emit(s):
            s = ANSI_RE.sub("", s.rstrip("\n")).replace("\x00", "")
            lines.append(s)
            self.q.put(("line", s))
            pr = job.get("progress")
            if pr:
                m = pr.search(s)
                if m:
                    self.q.put(("phase", f"faza {m.group(1)}/5: {m.group(2)}",
                                int(m.group(1)) * 20))

        try:
            proc = subprocess.Popen(job["argv"], **popen_kwargs())
        except OSError as e:
            self.q.put(("done", job, "INFRA", f"nu pot porni: {e}"))
            return
        self.proc = proc

        if job["mode"] == "gui_tail":
            self._tail_transcript(job, proc, emit, lines)
            return

        for line in proc.stdout:          # streamed live
            emit(line)
        rc = proc.wait()

        # asm has a second program to build
        if job.get("argv2") and rc == 0:
            try:
                p2 = subprocess.Popen(job["argv2"], **popen_kwargs())
                self.proc = p2
                for line in p2.stdout:
                    emit(line)
                rc = p2.wait()
            except OSError as e:
                self.q.put(("done", job, "INFRA", f"nu pot porni: {e}"))
                return

        st, sm = job["verdict"](lines, rc)
        self.q.put(("done", job, st, sm))

    def _tail_transcript(self, job, proc, emit, lines):
        """ModelSim GUI mode: output goes to ./transcript — tail it live so
        the verdict lands here while the user looks at the waveforms."""
        tpath = SIM_DIR / "transcript"
        off = tpath.stat().st_size if tpath.exists() else 0
        verdict_sent = False
        self.q.put(("line", "[gui] ModelSim deschis — transcriptul e urmarit "
                            "aici; inchide fereastra ModelSim ca sa "
                            "eliberezi runner-ul"))
        while proc.poll() is None or off < (tpath.stat().st_size
                                            if tpath.exists() else 0):
            try:
                if tpath.exists():
                    size = tpath.stat().st_size
                    if size < off:          # new session truncated the file
                        off = 0
                    if size > off:
                        with open(tpath, "r", encoding="utf-8",
                                  errors="replace") as f:
                            f.seek(off)
                            chunk = f.read()
                            off = f.tell()
                        for l in chunk.splitlines():
                            emit(l)
                        if not verdict_sent and \
                                "ALL TESTS PASSED" in chunk:
                            verdict_sent = True
                            self.q.put(("done_keep", job, "PASS",
                                        "banner vazut — GUI ramane deschis"))
                        if not verdict_sent and any("FAIL:" in l
                                                    for l in chunk.splitlines()):
                            verdict_sent = True
                            self.q.put(("done_keep", job, "FAIL",
                                        "FAIL in transcript (GUI deschis)"))
            except OSError:
                pass
            if proc.poll() is not None:
                break
            time.sleep(0.3)
        if not verdict_sent:
            st, sm = job["verdict"](lines, proc.returncode or 0)
            self.q.put(("done", job, st, sm))
        else:
            st, sm = job["verdict"](lines, 0)
            self.q.put(("done", job, st, sm + " (fereastra inchisa)"))

    # ----------------------------------------------------------- queue
    def _poll(self):
        batch = []
        try:
            while True:
                batch.append(self.q.get_nowait())
        except queue.Empty:
            pass

        text_lines = [m[1] for m in batch if m[0] == "line"]
        if text_lines:
            self._log_batch(text_lines)

        for m in batch:
            if m[0] == "phase":
                self._status("RUN", f"{self._busy_label} — {m[1]}")
                self.pbar["value"] = m[2]
            elif m[0] == "done_keep":
                _, job, st, sm = m
                self._result_row(job, st, sm)
                self._status(st, f"{job['label']}: {st} — ModelSim inca "
                                 "deschis (inchide-l ca sa rulezi altceva)")
            elif m[0] == "done":
                _, job, st, sm = m
                self._result_row(job, st, sm)
                self.proc = None
                if st == "INFRA":
                    self.abort_chain = True   # broken env: stop the chain
                self._next_in_chain()

        if self.busy and self.t_start:
            el = int(time.time() - self.t_start)
            self.elapsed_lbl.config(text=f"{el // 60:02d}:{el % 60:02d}")
        self.after(self.POLL_MS, self._poll)

    # -------------------------------------------------------- helpers
    def _status(self, kind, text):
        self.status_dot.config(fg=STATUS_COLOR.get(kind, "#666"))
        self.status_lbl.config(text=text)

    def _set_busy(self, b, label=""):
        self.busy = b
        self._busy_label = label
        self.t_start = time.time() if b else None
        state = "disabled" if b else "normal"
        for k, btn in self.buttons.items():
            btn.config(state=state)
        if not b:
            self._startup_checks_buttons()
            self.elapsed_lbl.config(text="")
            # keep the last verdict visible in the status bar; only reset
            # the dot to idle when nothing has run yet
            if not self.results:
                self._status("IDLE", "inactiv — alege o rulare")
        else:
            self._status("RUN", f"{label} — ruleaza...")
        self.stop_btn.config(state="normal" if b else "disabled")
        self.pbar["value"] = 0

    def _startup_checks_buttons(self):
        if not self.vsim:
            for k in ("msgui", "regress", "dual"):
                self.buttons[k].config(state="disabled")
        if not self.wsl:
            self.buttons["vlt"].config(state="disabled")

    def _result_row(self, job, st, sm):
        now = datetime.now().strftime("%H:%M:%S")
        dot = {"PASS": "● PASS", "FAIL": "● FAIL",
               "INFRA": "● MEDIU", "RUN": "◐ ..."}.get(st, st)
        vals = (job["label"], dot, sm, now)
        tag = st if st in STATUS_COLOR else "RUN"
        if job["key"] in self.results:
            iid = self.results[job["key"]]
            self.tree.item(iid, values=vals, tags=(tag,))
        else:
            self.results[job["key"]] = self.tree.insert(
                "", "end", values=vals, tags=(tag,))
        if st in ("PASS", "FAIL", "INFRA"):
            self._status(st, f"{job['label']}: {st} — {sm}")

    def _log_line(self, s):
        self._log_batch([s])

    def _log_batch(self, lines_):
        self.full_log.extend(lines_)
        at_bottom = self.text.yview()[1] > 0.999
        self.text.configure(state="normal")
        self.text.insert("end", "\n".join(lines_) + "\n")
        n = int(self.text.index("end-1c").split(".")[0])
        if n > self.MAX_SHOWN_LINES:
            self.text.delete("1.0", f"{n - self.MAX_SHOWN_LINES}.0")
        self.text.configure(state="disabled")
        if at_bottom:
            self.text.see("end")

    def _clear_stale_lock(self, startup=False):
        lock = SIM_DIR / "work" / "_lock"
        if lock.exists() and not vsim_running():
            try:
                lock.unlink()
                self._log_line("[gui] lock orfan work/_lock sters"
                               + (" (la pornire)" if startup else ""))
            except OSError as e:
                self._log_line(f"[gui] nu pot sterge lock-ul: {e}")

    # -------------------------------------------------------- actions
    def _stop(self):
        self.abort_chain = True
        self.chain = []
        if self.proc:
            self._log_line("[gui] STOP — omor arborele de procese")
            kill_tree(self.proc)
        # the killed vsim leaves its lock behind — clean it
        self.after(500, self._clear_stale_lock)

    def _clean(self):
        if self.busy:
            return
        if not messagebox.askyesno("Clean",
                                   "Sterg work/, obj_dir/, cov_annotated/, "
                                   "coverage.dat, transcript, *.log ?"):
            return
        for d in ("work", "obj_dir", "cov_annotated"):
            shutil.rmtree(SIM_DIR / d, ignore_errors=True)
        for f in ("coverage.dat", "transcript", "modelsim.ini"):
            (SIM_DIR / f).unlink(missing_ok=True)
        for f in SIM_DIR.glob("*.log"):
            f.unlink(missing_ok=True)
        self._log_line("[gui] clean gata")

    def _save(self):
        p = filedialog.asksaveasfilename(
            initialdir=str(SIM_DIR), defaultextension=".log",
            initialfile=f"verif_{datetime.now():%Y%m%d_%H%M%S}.log")
        if p:
            Path(p).write_text("\n".join(self.full_log), encoding="utf-8")
            self._log_line(f"[gui] log complet salvat in {p}")

    def _clear(self):
        self.text.configure(state="normal")
        self.text.delete("1.0", "end")
        self.text.configure(state="disabled")

    def _find(self):
        pat = self.find_var.get()
        if not pat:
            return
        self.text.tag_remove("hit", "1.0", "end")
        start = self.text.index("insert")
        pos = self.text.search(pat, f"{start}+1c", nocase=True)
        if not pos:
            pos = self.text.search(pat, "1.0", nocase=True)  # wrap
        if pos:
            end = f"{pos}+{len(pat)}c"
            self.text.tag_add("hit", pos, end)
            self.text.mark_set("insert", end)
            self.text.see(pos)

    def _on_close(self):
        if self.busy and self.proc:
            if not messagebox.askyesno("Inchidere",
                                       "Un run e in curs. Il opresc si ies?"):
                return
            kill_tree(self.proc)
            time.sleep(0.3)
            self._clear_stale_lock()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
