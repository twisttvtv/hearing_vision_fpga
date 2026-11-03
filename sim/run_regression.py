"""Run the three supplied testbenches from any current directory."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
script = root / 'skill/fpga-reproduce/scripts/run_regression.py'
for top in ('model_camera_vad_tb', 'model_camera_servo_direction_tb', 'model_camera_alert_policy_tb'):
    result = subprocess.run([sys.executable, '-B', str(script), '--root', str(root),
        '--rtl-dir', str(root / 'src/rtl'), '--top', top,
        '--tb', str(root / 'sim/tb' / (top + '.v'))])
    if result.returncode:
        raise SystemExit(result.returncode)
print('PASS: all three packaged RTL regressions; no board validation')
