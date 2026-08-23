# wave.do — AXI-focused waveform for tb_cpu_axi.
# Loaded automatically by sim.do (do sim.do), or by hand AFTER the design is
# elaborated:
#   do compile.do
#   vsim -voptargs=+acc work.tb_cpu_axi
#   do wave.do
#   run -all
#
# Signals are FLAT (no collapsible groups — ModelSim ASE adds script groups
# collapsed, which is why they looked empty). Each AXI link is separated by a
# divider and shows the master side (what the CPU drives OUT) and the slave side
# (what memory/peripheral answers), channel by channel, with the VALID/READY
# pair right next to the payload so a handshake reads at a glance.

onerror {resume}
quietly WaveActivateNextPane {} 0

# Log every signal so the traces actually have data (fills the WLF from t=0).
log -r /tb_cpu_axi/*

# start from a clean wave window, so re-running sim.do doesn't stack duplicates
delete wave *

# ---------------------------------------------------------------- clock / reset
add wave -noupdate -divider {CLK / RESET}
add wave -noupdate /tb_cpu_axi/clk
add wave -noupdate /tb_cpu_axi/rst_n

# ============================================================ IBUS  (read-only)
# One link: CPU fetch master <-> imem slave. AR = address the CPU asks for,
# R = the instruction word the memory returns.
add wave -noupdate -divider {IBUS  CPU-M <-> imem : AR (addr out)}
add wave -noupdate /tb_cpu_axi/ib_arvalid
add wave -noupdate /tb_cpu_axi/ib_arready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/ib_araddr
add wave -noupdate -divider {IBUS : R (data in)}
add wave -noupdate /tb_cpu_axi/ib_rvalid
add wave -noupdate /tb_cpu_axi/ib_rready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/ib_rdata
add wave -noupdate -radix hexadecimal /tb_cpu_axi/ib_rresp

# ======================================================= DBUS @ CPU master port
# What the CPU drives OUT and receives back on the data bus, before the decoder.
add wave -noupdate -divider {DBUS @ CPU-M : AW (waddr)}
add wave -noupdate /tb_cpu_axi/db_awvalid
add wave -noupdate /tb_cpu_axi/db_awready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/db_awaddr
add wave -noupdate -divider {DBUS @ CPU-M : W (wdata)}
add wave -noupdate /tb_cpu_axi/db_wvalid
add wave -noupdate /tb_cpu_axi/db_wready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/db_wdata
add wave -noupdate -radix binary      /tb_cpu_axi/db_wstrb
add wave -noupdate -divider {DBUS @ CPU-M : B (wresp)}
add wave -noupdate /tb_cpu_axi/db_bvalid
add wave -noupdate /tb_cpu_axi/db_bready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/db_bresp
add wave -noupdate -divider {DBUS @ CPU-M : AR (raddr)}
add wave -noupdate /tb_cpu_axi/db_arvalid
add wave -noupdate /tb_cpu_axi/db_arready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/db_araddr
add wave -noupdate -divider {DBUS @ CPU-M : R (rdata)}
add wave -noupdate /tb_cpu_axi/db_rvalid
add wave -noupdate /tb_cpu_axi/db_rready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/db_rdata
add wave -noupdate -radix hexadecimal /tb_cpu_axi/db_rresp

# ============================================================= dmem slave port
# The default dbus leg after the decoder: what dmem actually sees / answers.
add wave -noupdate -divider {dmem SLAVE : AW / W / B (write)}
add wave -noupdate /tb_cpu_axi/d0_awvalid
add wave -noupdate /tb_cpu_axi/d0_awready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/d0_awaddr
add wave -noupdate /tb_cpu_axi/d0_wvalid
add wave -noupdate /tb_cpu_axi/d0_wready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/d0_wdata
add wave -noupdate -radix binary      /tb_cpu_axi/d0_wstrb
add wave -noupdate /tb_cpu_axi/d0_bvalid
add wave -noupdate /tb_cpu_axi/d0_bready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/d0_bresp
add wave -noupdate -divider {dmem SLAVE : AR / R (read)}
add wave -noupdate /tb_cpu_axi/d0_arvalid
add wave -noupdate /tb_cpu_axi/d0_arready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/d0_araddr
add wave -noupdate /tb_cpu_axi/d0_rvalid
add wave -noupdate /tb_cpu_axi/d0_rready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/d0_rdata
add wave -noupdate -radix hexadecimal /tb_cpu_axi/d0_rresp

# ============================================================== PIC slave port
add wave -noupdate -divider {PIC SLAVE : AW / W / B (write)}
add wave -noupdate /tb_cpu_axi/pp_awvalid
add wave -noupdate /tb_cpu_axi/pp_awready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/pp_awaddr
add wave -noupdate /tb_cpu_axi/pp_wvalid
add wave -noupdate /tb_cpu_axi/pp_wready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/pp_wdata
add wave -noupdate -radix binary      /tb_cpu_axi/pp_wstrb
add wave -noupdate /tb_cpu_axi/pp_bvalid
add wave -noupdate /tb_cpu_axi/pp_bready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/pp_bresp
add wave -noupdate -divider {PIC SLAVE : AR / R (read)}
add wave -noupdate /tb_cpu_axi/pp_arvalid
add wave -noupdate /tb_cpu_axi/pp_arready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/pp_araddr
add wave -noupdate /tb_cpu_axi/pp_rvalid
add wave -noupdate /tb_cpu_axi/pp_rready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/pp_rdata
add wave -noupdate -radix hexadecimal /tb_cpu_axi/pp_rresp

# =========================================================== mtimer slave port
add wave -noupdate -divider {mtimer SLAVE : AW / W / B (write)}
add wave -noupdate /tb_cpu_axi/t_awvalid
add wave -noupdate /tb_cpu_axi/t_awready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/t_awaddr
add wave -noupdate /tb_cpu_axi/t_wvalid
add wave -noupdate /tb_cpu_axi/t_wready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/t_wdata
add wave -noupdate -radix binary      /tb_cpu_axi/t_wstrb
add wave -noupdate /tb_cpu_axi/t_bvalid
add wave -noupdate /tb_cpu_axi/t_bready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/t_bresp
add wave -noupdate -divider {mtimer SLAVE : AR / R (read)}
add wave -noupdate /tb_cpu_axi/t_arvalid
add wave -noupdate /tb_cpu_axi/t_arready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/t_araddr
add wave -noupdate /tb_cpu_axi/t_rvalid
add wave -noupdate /tb_cpu_axi/t_rready
add wave -noupdate -radix hexadecimal /tb_cpu_axi/t_rdata
add wave -noupdate -radix hexadecimal /tb_cpu_axi/t_rresp

# ================================================================= IRQ / trap
add wave -noupdate -divider {IRQ / TRAP}
add wave -noupdate -radix binary   /tb_cpu_axi/irq_src
add wave -noupdate                 /tb_cpu_axi/tmr_irq
add wave -noupdate                 /tb_cpu_axi/cpu_irq
add wave -noupdate -radix unsigned /tb_cpu_axi/cpu_irq_vec
add wave -noupdate                 /tb_cpu_axi/cpu_irq_ack
add wave -noupdate                 /tb_cpu_axi/cpu_irq_eoi
add wave -noupdate                 /tb_cpu_axi/cpu_in_trap
add wave -noupdate -radix unsigned /tb_cpu_axi/pic_inst/depth
add wave -noupdate -radix binary   /tb_cpu_axi/pic_inst/active

configure wave -namecolwidth 240
configure wave -valuecolwidth 100
configure wave -timelineunits ns
update
