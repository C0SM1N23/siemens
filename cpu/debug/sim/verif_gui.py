#!/usr/bin/env python3
# Tkinter launcher for the ModelSim and Verilator scripts in this directory.
# Worker threads stream output through a queue to the UI thread.
# Verdicts require successful completion, exact run counts and zero failures.
# Stop terminates the launched process tree; source files are preserved.

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
    "imem_RL":   "/rv32i_tb_cpu_axi/imem_inst/READ_LAT",
    "imem_SP":   "/rv32i_tb_cpu_axi/imem_inst/STALL_PROB",
    "imem_SEED": "/rv32i_tb_cpu_axi/imem_inst/SEED",
    "dmem_RL":   "/rv32i_tb_cpu_axi/dmem_inst/READ_LAT",
    "dmem_WL":   "/rv32i_tb_cpu_axi/dmem_inst/WRITE_LAT",
    "dmem_SP":   "/rv32i_tb_cpu_axi/dmem_inst/STALL_PROB",
    "dmem_SEED": "/rv32i_tb_cpu_axi/dmem_inst/SEED",
    "ENTRIES":   "/rv32i_tb_cpu_axi/uut/branch_predictor_inst/ENTRIES",
    "RAS_DEPTH": "/rv32i_tb_cpu_axi/uut/branch_predictor_inst/RAS_DEPTH",
}

INFRA_TOKENS = (
    "vlog failed", "vsim failed", "Giving up waiting on lock",
    "Error loading design", "not recognized as an internal",
    "cannot open", "No such file or directory", "command not found",
    "no installed distributions",
)

STATUS_COLOR = {"PASS": "#2e9e4f", "FAIL": "#d23131",
                "INFRA": "#e08a00", "RUN": "#888888", "IDLE": "#666666"}

# info tab text
INFO_PAGES = [
    ("ModelSim TB + waveforms", """\
What it does: opens ModelSim (GUI), compiles the RTL and the testbenches, loads
rv32i_tb_cpu_axi with the AXI signals already in the Wave window (wave.do) and runs
the test program to completion. The verdict appears here, because the
transcript is tailed live, while you stay in ModelSim to look at the waveforms.

What it checks (90 checks, self-checking program):
  - every RV32I instruction class plus S3->S2 forwarding (dependent chains,
    with the CPI measured: 33 cycles for 33 instructions)
  - load/store at every width: per-byte-lane WSTRB (SB/SH/SW) and extraction
    with sign/zero extension (LB/LBU/LH/LHU)
  - Supported synchronous trap causes (0..7, 11), counted EXACTLY:
    17 entries into the direct handler, 26 in total (hardware counter mhpm6)
  - an illegal instruction with no side effects (an illegal store never
    reaches memory), a misaligned access with no AXI transaction issued
  - bus errors (SLVERR/DECERR) turning into precise access faults, raised by
    the real peripherals (PIC / mtimer) and not only by the memory model
  - CSRs: the immediate forms, the negatives (a CSR that does not exist, a
    write to a read-only one), mtval carrying the faulting address,
    misa / mvendorid / marchid / mimpid
  - interrupts through the real PIC: priority, the two independent masks
    (PIC enable versus mie), in-service suppression, an interrupt raised
    during an AXI stall (the claim is held to the instruction boundary)
  - vectored mtvec (interrupt -> BASE + 4*cause, exception -> BASE)
  - WFI: the fetch goes to sleep (the instruction bus is measured silent),
    mepc = wfi+4 on wake, fall-through when MIE = 0; the mtimer end to end
    (armed without a false fire)
  - the predictor: learned loops, BTB aliasing (three branches on one index),
    the return-address stack with three call sites and a nested chain
  - AXI protocol monitors on every bus, on every cycle

The waveforms show AXI at both ends: IBUS (CPU to imem), DBUS at the CPU
master, then what each slave sees (dmem / PIC / mtimer), plus the interrupt
lines. A transfer is the cycle where VALID and READY are high together."""),

    ("Regression 21-run", """\
Runs the CPU regression in the console:
  - system bench under four memory timing configurations;
  - two cores sharing data memory;
  - PIC features, scheduling, reset, access rules and status;
  - PIC reference: 275 cases, all 256 band configurations;
  - timer, CSR access and counter write/carry checks;
  - synchronous traps, predictor and ALU;
  - independent ISA trace under four memory timing configurations.

Parameter overrides are read back after elaboration.
PASS requires exit code zero, 21 completed runs and zero failures."""),

    ("Dual-core", """\
What it does: runs only the dual-core test (tb_dual_core), in the console.

The scenario: two cpu_top instances (HART_ID 0 and 1), each with its own
instruction memory, sharing one data memory through a round-robin AXI arbiter.
The two cores hand off to each other through flags in the shared memory (no
LR/SC - which works because each core is in-order with blocking transactions,
and is therefore sequentially consistent).

What it proves: the core can be instantiated N times with no shared state,
mhartid lets software tell the instances apart, and two blocking AXI masters
make progress through an arbitrated slave without deadlock or corruption.

Verdict: "DUAL-CORE TEST PASSED" plus a clean shared-bus monitor."""),

    ("Verilator SVA + coverage", """Runs all 15 CPU/PIC benches through Verilator in WSL with applicable bound
SVA. The nominal CPU system test also records user functional coverage.

Assertions check AXI handshakes, pipeline/trap state and PIC scheduling/nesting.
They check only the instances and scenarios executed by the tests.

The nominal coverage gate requires every mandatory bin. The current result is
88/92; the four optional misses are two masked-source bins and two backpressure
bins exercised separately by the ModelSim timing sweep.

PASS requires exit code zero, no failure messages, the coverage gate and the
final 15-bench completion marker. Build failures are reported separately.
The first C++ build may take several minutes."""),

    ("Assemble", """Regenerates the simulation images and symbol tables:

  program_axi.s  -> program_axi.hex and program_axi_sym.vh
  program_dual.s -> program_dual.hex and program_dual_sym.vh
  isa_reference.py -> independent instruction trace and memory expectations
  pic_reference.py -> independent priority expectations

Auto-assemble checks the assembly and reference-generator timestamps before
running simulation. Run Assemble explicitly after changing image inputs."""),

    ("RUN ALL", """Runs these steps in order:
  1. Assemble programs and reference images.
  2. ModelSim: all 21 CPU/PIC configurations.
  3. Verilator: all 15 benches, SVA and nominal CPU coverage.

An environment error stops the chain. A test failure is recorded and the
remaining flows still run."""),

    ("Clean / Stop / verdicts", """\
Clean: deletes the build artifacts (work/, obj_dir/, cov_annotated/,
coverage.dat, transcript, *.log). The sources and the hex files stay. Useful
when you want a from-scratch rebuild, or after an odd crash.

Stop: kills the ENTIRE process tree of the current run (vsim spawns children,
so taskkill /T). After a stop, an orphaned work/_lock is removed automatically,
so the next run - from here or from a terminal - does not block on it.

Verdicts require the process status and the completed-test markers:
  - PASS (green)         the expected banners counted exactly (20 x "ALL TESTS
                         PASSED" plus the dual-core one, for the regression)
                         plus exit code zero, the final marker and zero failures
  - FAIL (red)           there is a "FAIL:", or banners are missing, so a test
                         failed
  - ENVIRONMENT (orange) the environment is broken: vsim not found, a compile
                         error, a stuck lock. This does NOT mean the RTL is
                         wrong - fix the environment and run again.

The -G parameters in the panel apply ONLY to the "ModelSim TB" run: latency and
backpressure on the memory models, ENTRIES and RAS_DEPTH on the predictor. The
defaults are exactly the testbench values; only what you change is sent as an
override."""),
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


# verdicts
# ModelSim: require exit code zero and exact completion counts.
# AND zero FAIL: AND no infra token. Infra tokens win (orange).

def _classify(lines, need_all, need_dual, extra_ok=None):
    txt = "\n".join(lines)
    for tok in INFRA_TOKENS:
        if tok in txt:
            return "INFRA", f"environment error: '{tok}'"
    n_all = txt.count("ALL TESTS PASSED")
    n_dual = txt.count("DUAL-CORE TEST PASSED")
    n_fail = sum(1 for l in lines if "FAIL:" in l)
    if n_fail == 0 and n_all == need_all and n_dual == need_dual \
            and (extra_ok is None or extra_ok(txt)):
        return "PASS", f"{n_all + n_dual} completed run(s)"
    return "FAIL", f"{n_fail} FAIL, banners {n_all}+{n_dual} " \
                   f"(required {need_all}+{need_dual})"


def verdict_sim(lines, rc):
    return _classify(lines, 1, 0, extra_ok=lambda _: rc == 0)


# Keep counts aligned with regress.do; an early exit must not report PASS.
REGRESS_ALL_BANNERS  = 20
REGRESS_DUAL_BANNERS = 1
REGRESS_RUNS         = 21


def verdict_regress(lines, rc):
    st, sm = _classify(lines, REGRESS_ALL_BANNERS, REGRESS_DUAL_BANNERS,
                       extra_ok=lambda t: rc == 0 and f"REGRESSION PASS: {REGRESS_RUNS} runs" in t)
    if st == "PASS":
        sm = "%d/%d runs, " % (REGRESS_RUNS, REGRESS_RUNS) + sm
    return st, sm


def verdict_dual(lines, rc):
    return _classify(lines, 0, 1, extra_ok=lambda _: rc == 0)


def verdict_verilator(lines, rc):
    txt = "\n".join(lines)
    for tok in INFRA_TOKENS:
        if tok in txt:
            return "INFRA", f"environment error: '{tok}'"
    m = re.search(r"\[FCOV\] ---- (\d+)/(\d+) bins hit \((\d+)%\)", txt)
    fcov = f", FCOV {m.group(1)}/{m.group(2)} ({m.group(3)}%)" if m else ""
    complete = "SVA REGRESSION PASS: CPU, 15 benches; functional coverage gate passed" in txt
    failed = any(token in txt for token in ("%Error", "FAIL:", "GATE FAILED"))
    if rc == 0 and complete and not failed and "COVERAGE GATE PASSED" in txt:
        return "PASS", "SVA clean" + fcov
    if rc != 0 and "%Error" in txt:
        return "FAIL", "assertion fired / test FAIL" + fcov
    # exit != 0 without a single PASS:/FAIL: line means the simulation never
    # started (build interrupted, WSL down, the g++ compile killed) - that is
    # an environment problem, not a failed test
    sim_ran = any(l.startswith(("PASS:", "FAIL:")) for l in lines)
    if rc != 0 and not sim_ran:
        return "INFRA", "build interrupted - the simulation never started " \
                        "(exit != 0, zero simulation lines)"
    return ("FAIL", "gate/tests failed" + fcov) if rc else \
           ("FAIL", "banner missing" + fcov)


def verdict_asm(lines, rc):
    return ("PASS", "hex + sym regenerated") if rc == 0 else \
           ("INFRA", "assembly failed (see the log)")


# app
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

    # style
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

    # UI
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
        self.status_lbl = ttk.Label(sb, text="idle - pick a run",
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
            ("regress", "Regression 21-run",        ["regress"],
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
        ttk.Checkbutton(uf, text="auto-assemble when a .s is newer than its .hex",
                        variable=self.auto_asm).pack(side="left", padx=12)

        # -- parameters (apply to the ModelSim TB run)
        pf = ttk.LabelFrame(root, text=" Parameters - applied to the "
                                       "'ModelSim TB + waveforms' run only ")
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
                  text="RL/WL = memory response latency (cycles) - "
                       "SP = READY stall probability, % (backpressure) - "
                       "SEED = samanta stall-urilor aleatoare · "
                       "ENTRIES/RAS_DEPTH = dimensiunea predictorului. "
                       "Only values that differ from the defaults are sent "
                       "as -G; the RTL is never modified.").grid(
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
            self._log_line("[gui] vsim not found (not in PATH, not in "
                           f"${VSIM_ENV_VAR}, and not in the usual install "
                           "locations) - set the environment variable "
                           f"{VSIM_ENV_VAR}=<path to vsim.exe>, or put vsim "
                           "in PATH. The ModelSim buttons are disabled.")
        if not self.wsl:
            self.buttons["vlt"].config(state="disabled")
            self._log_line("[gui] wsl not found - the Verilator button is disabled")
        self._clear_stale_lock(startup=True)

    # jobs
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
                        more_argv=[
                            [sys.executable, "asm.py", "program_dual.s", "program_dual.hex"],
                            [sys.executable, "isa_reference.py"],
                            [sys.executable, "pic_reference.py"],
                        ],
                        verdict=verdict_asm)
        if key == "msgui":
            g = self._gflags()
            # mirrors sim.do, with optional -G overrides on the inner vsim
            do = f"set sim_args {{{g}}}; do sim.do"
            return dict(key=key, label="ModelSim TB (GUI)", mode="gui_tail",
                        argv=[self.vsim, "-do", do], verdict=verdict_sim)
        if key == "regress":
            return dict(key=key, label="Regression 21-run", mode="stream",
                        argv=[self.vsim, "-c", "-do",
                              "do regress.do; quit -f"],
                        verdict=verdict_regress,
                        progress=re.compile(r"RUN (\d+): (.*)"))
        if key == "dual":
            return dict(key=key, label="Dual-core", mode="stream",
                        argv=[self.vsim, "-c", "-do",
                              "do compile.do; do run_common.do; "
                              "run_case rv32i_tb_dual_core dual; quit -f"],
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
                     ("program_dual.s", "program_dual.hex"),
                     ("isa_reference.py", "program_isa.hex"),
                     ("pic_reference.py", "pic_reference.hex")):
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
        self._result_row(job, "RUN", "running...")
        if key in ("msgui", "regress", "dual"):
            self._clear_stale_lock()
        threading.Thread(target=self._worker, args=(job,),
                         daemon=True).start()

    # worker
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
                    current = int(m.group(1))
                    self.q.put(("phase", f"run {current}/{REGRESS_RUNS}: {m.group(2)}",
                                100 * current / REGRESS_RUNS))

        try:
            proc = subprocess.Popen(job["argv"], **popen_kwargs())
        except OSError as e:
            self.q.put(("done", job, "INFRA", f"cannot start: {e}"))
            return
        self.proc = proc

        if job["mode"] == "gui_tail":
            self._tail_transcript(job, proc, emit, lines)
            return

        for line in proc.stdout:          # streamed live
            emit(line)
        rc = proc.wait()

        # Generate the remaining program and reference images in order.
        for argv in job.get("more_argv", []):
            if rc != 0:
                break
            try:
                p2 = subprocess.Popen(argv, **popen_kwargs())
                self.proc = p2
                for line in p2.stdout:
                    emit(line)
                rc = p2.wait()
            except OSError as e:
                self.q.put(("done", job, "INFRA", f"cannot start: {e}"))
                return

        st, sm = job["verdict"](lines, rc)
        self.q.put(("done", job, st, sm))

    def _tail_transcript(self, job, proc, emit, lines):
        """ModelSim GUI mode: output goes to ./transcript — tail it live so
        the verdict lands here while the user looks at the waveforms."""
        tpath = SIM_DIR / "transcript"
        off = tpath.stat().st_size if tpath.exists() else 0
        verdict_sent = False
        self.q.put(("line", "[gui] ModelSim is open - its transcript is "
                            "tailed here; close the ModelSim window to "
                            "release the runner"))
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
                                "SIMULATION PASS: rv32i_tb_cpu_axi" in chunk:
                            verdict_sent = True
                            self.q.put(("done_keep", job, "PASS",
                                        "completion verified - the GUI stays open"))
                        if not verdict_sent and any("FAIL:" in l
                                                    for l in chunk.splitlines()):
                            verdict_sent = True
                            self.q.put(("done_keep", job, "FAIL",
                                        "FAIL in the transcript (GUI still open)"))
            except OSError:
                pass
            if proc.poll() is not None:
                break
            time.sleep(0.3)
        if not verdict_sent:
            st, sm = job["verdict"](lines, proc.returncode or 0)
            self.q.put(("done", job, st, sm))
        else:
            st, sm = job["verdict"](lines, proc.returncode or 0)
            self.q.put(("done", job, st, sm + " (fereastra inchisa)"))

    # queue
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
                                 "open (close it to run something else)")
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

    # helpers
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
                self._status("IDLE", "idle - pick a run")
        else:
            self._status("RUN", f"{label} - running...")
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
               "INFRA": "● ENV", "RUN": "◐ ..."}.get(st, st)
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
                               + (" (at startup)" if startup else ""))
            except OSError as e:
                self._log_line(f"[gui] cannot remove the lock: {e}")

    # actions
    def _stop(self):
        self.abort_chain = True
        self.chain = []
        if self.proc:
            self._log_line("[gui] STOP - killing the process tree")
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
                                       "A run is in progress. Stop it and exit?"):
                return
            kill_tree(self.proc)
            time.sleep(0.3)
            self._clear_stale_lock()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
