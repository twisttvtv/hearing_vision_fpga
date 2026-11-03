"""Behavior checks using synthetic files, not hardware bitstreams."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


chain = load('chain', 'fpga-reproduce/scripts/check_bit_chain.py')
regression = load('regression', 'fpga-reproduce/scripts/run_regression.py')


class HelperTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bit = self.root / 'demo.bit'
        self.bit.write_bytes(b'SYNTHETIC-NOT-A-REAL-BITSTREAM')
        self.xsa = self.root / 'demo.xsa'

    def archive(self, **entries):
        with zipfile.ZipFile(self.xsa, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)

    def test_same_bit_bytes_pass(self):
        self.archive(**{'nested/demo.bit': self.bit.read_bytes()})
        self.assertEqual(len(chain.check(self.bit, self.xsa, self.bit)), 3)

    def test_stale_debug_bit_rejected(self):
        self.archive(**{'demo.bit': self.bit.read_bytes()})
        debug = self.root / 'old.bit'
        debug.write_bytes(b'stale')
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            chain.check(self.bit, self.xsa, debug)

    def test_absent_embedded_bit_rejected(self):
        self.archive(**{'metadata.xml': b'<xml/>'})
        with self.assertRaises(ValueError):
            chain.check(self.bit, self.xsa)

    def test_ambiguous_xsa_requires_member(self):
        self.archive(**{'a.bit': self.bit.read_bytes(), 'b.bit': b'other'})
        with self.assertRaises(ValueError):
            chain.check(self.bit, self.xsa)
        self.assertEqual(len(chain.check(self.bit, self.xsa, member='a.bit')), 2)

    def test_zero_exit_fail_is_failure(self):
        with self.assertRaises(ValueError):
            regression.require_pass(subprocess.CompletedProcess([], 0, 'FAIL broken\n', ''))

    def test_missing_pass_is_failure(self):
        with self.assertRaises(ValueError):
            regression.require_pass(subprocess.CompletedProcess([], 0, 'simulation ended\n', ''))

    def test_error_followed_by_pass_is_failure(self):
        with self.assertRaises(ValueError):
            regression.require_pass(subprocess.CompletedProcess([], 0, 'ERROR: bad result\nPASS done\n', ''))

    def test_explicit_pass(self):
        self.assertEqual(regression.require_pass(
            subprocess.CompletedProcess([], 0, 'PASS behavior\n', '')), 'PASS behavior')

    @unittest.skipUnless(shutil.which('iverilog') and shutil.which('vvp'), 'Requires iverilog/vvp')
    def test_relocated_package_with_custom_project_and_rtl_directory(self):
        workspace = self.root / 'renamed checkout with spaces'
        shutil.copytree(ROOT, workspace / 'skill', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        project = workspace / 'another project name'
        hdl = project / 'hardware sources'
        hdl.mkdir(parents=True)
        (hdl / 'invert.v').write_text('module invert(input a, output b); assign b=~a; endmodule\n',
                                    encoding='utf-8')
        bench = project / 'independent_test.v'
        bench.write_text('''module independent_tb;
reg a; wire b; invert dut(a,b);
initial begin
    a=0; #1;
    if(b!==1'b1) begin $display("FAIL low input"); $finish; end
    a=1; #1;
    if(b!==1'b0) begin $display("FAIL high input"); $finish; end
    $display("PASS relocated custom design"); $finish;
end
endmodule
''', encoding='utf-8')
        result = subprocess.run([
            sys.executable, '-B', 'skill/fpga-reproduce/scripts/run_regression.py',
            '--root', str(project.relative_to(workspace)),
            '--rtl-dir', str(hdl.relative_to(workspace)),
            '--top', 'independent_tb', '--tb', str(bench.relative_to(workspace))],
            cwd=workspace, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS relocated custom design', result.stdout)


if __name__ == '__main__':
    unittest.main()
