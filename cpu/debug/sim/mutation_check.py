"""Inject CPU/SoC defects in a temporary copy and require the selected test to reject each."""

from pathlib import Path
import argparse
import json
import shutil
import subprocess
import sys
import tempfile


# name, file, original expression, faulty expression, detecting bench (with its plusargs)
MUTATIONS = [
    ("subtraction", "cpu/hdl/rv32i_alu.v", "operand_a_i - operand_b_i", "operand_b_i - operand_a_i", "rv32i_tb_isa"),
    ("arithmetic_shift", "cpu/hdl/rv32i_alu.v", "$signed(operand_a_i) >>>", "operand_a_i >>", "rv32i_tb_isa"),
    ("load_sign", "cpu/hdl/rv32i_lsu.v", "{{24{lbyte[7]}}, lbyte}", "{24'b0, lbyte}", "rv32i_tb_isa"),
    ("byte_strobe", "cpu/hdl/rv32i_lsu.v", "4'b0001 << addr_i[1:0]", "4'b1111", "rv32i_tb_isa"),
    ("half_strobe", "cpu/hdl/rv32i_lsu.v", "4'b0011 << addr_i[1:0]", "4'b1111", "rv32i_tb_isa"),
    ("counter_write", "cpu/hdl/rv32i_csr_file.v", "csr_new_val(cur[31:0], wdata, op)", "csr_new_val(inc[31:0], wdata, op)", "rv32i_tb_counters"),
    ("counter_carry", "cpu/hdl/rv32i_csr_file.v", "{cur[63:32], csr_new_val", "{inc[63:32], csr_new_val", "rv32i_tb_counters"),
    ("pic_mask", "cpu/hdl/pic.v", "req[s] && cpu_mask_i[s]", "req[s]", "pic_tb_reference"),
    ("pic_tie", "cpu/hdl/pic.v", "15 - s", "s", "pic_tb_reference"),
    ("pic_empty_eoi", "cpu/hdl/pic.v", "cpu_irq_eoi_i && has_active", "cpu_irq_eoi_i", "pic_tb_feature"),
    ("decoder_stale_write", "soc/hdl/soc_axi_lite_dec.v", "wr_addr_valid_q ? wr_sel_q : aw_hit", "m_awvalid_i ? aw_hit : wr_sel_q", "soc_tb_addr_map"),
    ("arbiter_directions", "soc/hdl/soc_axi_lite_arb.v", "!write_grant_q && !ar_taken_q && |(gnt & m_arvalid_i)", "!ar_taken_q && |(gnt & m_arvalid_i)", "soc_tb_arb"),
    ("burst_response", "soc/hdl/soc_axi_full2lite.v", "m_bresp_i > w_resp", "m_bresp_i != RESP_OKAY", "soc_tb_full2lite_err"),
    ("decoder_read_route", "soc/hdl/soc_axi_lite_dec.v", "ar_accept = ~rd_addr_valid_q", "ar_accept = 1'b1", "soc_tb_addr_map"),
    ("arbiter_second_address", "soc/hdl/soc_axi_lite_arb.v", "write_grant_q && !aw_taken_q && |(gnt & m_awvalid_i)", "write_grant_q && |(gnt & m_awvalid_i)", "soc_tb_arb"),
    ("bridge_alignment", "soc/hdl/soc_axi_full2lite.v", " && (s_awaddr_i[1:0] == 2'b00)", "", "soc_tb_full2lite"),
    ("slt_unsigned", "cpu/hdl/rv32i_alu.v", "$signed(operand_a_i) < $signed(operand_b_i)", "operand_a_i < operand_b_i", "rv32i_tb_isa +isa=program_isa_r1"),
    ("irq_decodes_instruction", "cpu/hdl/rv32i_cpu_top.v", "ifdx_valid_q && !irq_take && !ifdx_fault_q", "ifdx_valid_q && !ifdx_fault_q", "rv32i_tb_traps"),
    ("pic_claim_past_limit", "cpu/hdl/pic.v", "cpu_irq_ack_i && (depth < nest_max)", "cpu_irq_ack_i", "pic_tb_random"),
    ("timer_compare_strict", "cpu/hdl/mtimer.v", "irq_o <= (mtime_q >= mtimecmp_q);", "irq_o <= (mtime_q > mtimecmp_q);", "mtimer_tb_regs"),
    ("timer_armed_at_reset", "cpu/hdl/mtimer.v", "mtimecmp_q <= {64{1'b1}};", "mtimecmp_q <= 64'd0;", "mtimer_tb_regs"),
    ("decoder_no_decerr", "soc/hdl/soc_axi_lite_dec.v", "wr_err_q ? RESP_DECERR : bresp_mux", "bresp_mux", "soc_tb_isolation"),
    ("decoder_keeps_write_in_reset", "soc/hdl/soc_axi_lite_dec.v", "if (!rst_n_i) wr_addr_valid_q <= 1'b0;", "if (!rst_n_i) wr_addr_valid_q <= wr_addr_valid_q;", "soc_tb_reset_traffic"),
    ("burst_drops_beat_error", "soc/hdl/soc_axi_full2lite.v", "w_beat_ack && m_bresp_i > w_resp", "1'b0", "soc_tb_same_addr"),
    ("arbiter_release_before_b", "soc/hdl/soc_axi_lite_arb.v", "(s_bvalid_i & s_bready_o[0])", "s_bvalid_i", "soc_tb_fabric_random +seed=1"),
]

# Benches whose verdict comes from a script run after the simulation.
POST_CHECK = {"pic_tb_random": [sys.executable, "pic_model.py", "pic_random.trace"]}


def post_check(top, cwd):
    """True when the bench has no post-check or its post-check passes."""
    if top not in POST_CHECK:
        return True
    return subprocess.run(POST_CHECK[top], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vsim", default="vsim")
    parser.add_argument("names", nargs="*", help="run only these mutations")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    scratch = Path(tempfile.mkdtemp(prefix="siemens-mutations-"))
    files = subprocess.check_output(["git", "ls-files", "-c", "-o", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    for name in set(files):
        source = root / name
        if source.is_file() and source.suffix in (".v", ".vh", ".sv", ".hex", ".f", ".do", ".py"):
            target = scratch / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    print(f"Mutation workspace: {scratch}", flush=True)
    results = []
    for block in ("cpu", "soc"):
        cases = [case for case in MUTATIONS if case[1].startswith(block + "/")
                 and (not args.names or case[0] in args.names)]
        if not cases:
            continue
        cwd = scratch / block / "debug/sim"
        helper = "run_common.do" if block == "cpu" else "../../../cpu/debug/sim/run_common.do"
        benches = list(dict.fromkeys(case[4] for case in cases))
        tops = [bench.split()[0] for bench in benches]
        baseline = f"do compile.do; do {helper}; " + "; ".join(f"run_case {bench.split()[0]} baseline {' '.join(bench.split()[1:])}" for bench in benches) + "; quit -f"
        result = subprocess.run([args.vsim, "-c", "-do", baseline], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=1800)
        (root / block / "debug/sim/mutation_baseline.log").write_text(result.stdout)
        if result.returncode or any(f"PASS: {top}" not in result.stdout for top in tops) or not all(post_check(top, cwd) for top in tops):
            raise SystemExit(f"FAIL: {block} mutation baseline")
        for name, filename, old, new, bench in cases:
            top, plusargs = bench.split()[0], " ".join(bench.split()[1:])
            target = scratch / filename
            original = target.read_text()
            if original.count(old) != 1:
                raise SystemExit(f"FAIL: stale mutation anchor: {name}")
            target.write_text(original.replace(old, new))
            try:
                command = f"do compile.do; do {helper}; run_case {top} {name} {plusargs}; quit -f"
                run = subprocess.run([args.vsim, "-c", "-do", command], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=900)
                # A compile error is not a detected behavioral defect.
                elaborated = f"Loading work.{top}" in run.stdout
                failed_in_sim = run.returncode != 0 and "FAIL:" in run.stdout
                killed = elaborated and (failed_in_sim or not post_check(top, cwd))
                (root / block / f"debug/sim/mutation_{name}.log").write_text(run.stdout)
                results.append({"mutation": name, "bench": top, "detected": killed})
                print(f"{'DETECTED' if killed else 'MISSED'}: {name} ({top})", flush=True)
            finally:
                target.write_text(original)
    (root / "cpu/debug/sim/mutation_results.json").write_text(json.dumps(results, indent=2) + "\n")
    if not all(result["detected"] for result in results):
        raise SystemExit(1)
    print(f"MUTATION PASS: {len(results)}/{len(results)} detected; baselines passed")


if __name__ == "__main__":
    main()
