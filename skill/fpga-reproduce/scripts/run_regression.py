"""Run real RTL testbenches; reject zero-exit FAIL and missing PASS."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def require_pass(result):
    output = (result.stdout or '') + (result.stderr or '')
    if result.returncode or re.search(r'\b(?:FAIL|FATAL|ERROR)\b', output, re.I):
        raise ValueError(output or f'exit {result.returncode}')
    if not re.search(r'^PASS\b', output, re.M):
        raise ValueError('Simulation ended without explicit PASS\n' + output)
    return output.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--rtl-dir', type=Path, help='RTL directory; default: ROOT/rtl; paths relative to caller')
    parser.add_argument('--top', help='Custom testbench top; requires --tb')
    parser.add_argument('--tb', action='append', type=Path)
    parser.add_argument('--timeout', type=int, default=180, help='Seconds per process')
    args = parser.parse_args()
    root = args.root.resolve()
    rtl_dir = args.rtl_dir.resolve() if args.rtl_dir else root / 'rtl'
    rtl = sorted(rtl_dir.glob('*.v'))
    if not rtl:
        parser.error(f'No .v files directly in {rtl_dir}; specify --rtl-dir')
    if bool(args.top) != bool(args.tb):
        parser.error('Use --top and --tb together')
    cases = [(args.top, [p.resolve() for p in args.tb])] if args.top else [
        (name, [root / 'tests' / (name + '.v')]) for name in (
            'model_camera_vad_tb', 'model_camera_servo_direction_tb',
            'model_camera_alert_policy_tb')]
    with tempfile.TemporaryDirectory(prefix='fpga-regression-') as directory:
        for index, (top, benches) in enumerate(cases):
            compiled = Path(directory) / f'case{index}.vvp'
            command = ['iverilog', '-g2005', '-s', top, '-o', str(compiled)]
            command += [str(p) for p in rtl + benches]
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=args.timeout, cwd=root)
            if result.returncode:
                raise ValueError(result.stdout + result.stderr)
            result = subprocess.run(['vvp', str(compiled)], capture_output=True,
                                    text=True, timeout=args.timeout, cwd=root)
            print(require_pass(result))
    print('PASS: all requested RTL regressions (not board validation)')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f'ERROR: {exc}')
        raise SystemExit(1)
