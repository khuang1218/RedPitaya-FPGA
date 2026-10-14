"""Run the real reader scheduler in Icarus, adapting its interface port only.

Usage: python run_bnet_reader_scheduler.py [--iverilog PATH] [--vvp PATH] [-B IVL_DIR]
FIFO/AXI protocol models do not test DDR data or vendor IP timing.
"""
import argparse
import pathlib
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iverilog', default='iverilog')
parser.add_argument('--vvp', default='vvp')
parser.add_argument('-B', dest='ivl_dir')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'prj/v0.94/rtl/bnet_axi_reader_ch.sv').read_text()
source, count = re.subn(r'axi_sys_if\.s\s+axi_sys,', 'input wire axi_clk, axi_rstn,', source)
assert count == 1
source = source.replace('axi_sys.clk', 'axi_clk').replace('axi_sys.rstn', 'axi_rstn')
source, count = re.subn(r'\.axi_sys\s*\(axi_sys\),', '.axi_clk(axi_clk), .axi_rstn(axi_rstn),', source)
assert count == 1
with tempfile.TemporaryDirectory(prefix='bnet-scheduler-') as directory:
    adapter = pathlib.Path(directory) / 'reader_adapter.sv'
    output = pathlib.Path(directory) / 'test.vvp'
    adapter.write_text(source)
    command = [args.iverilog]
    if args.ivl_dir:
        command += ['-B', args.ivl_dir]
    command += ['-g2012', '-s', 'tb_bnet_reader_scheduler', '-o', str(output),
                str(adapter), str(root / 'tbn/tb_bnet_reader_scheduler.sv')]
    subprocess.run(command, check=True)
    subprocess.run([args.vvp, str(output)], check=True)
