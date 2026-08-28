"""Run one ring-bell headless suite via subprocess with file-redirected output.

Usage: python tools/run_suite.py --<flag> [timeout_s]
  flag: --import | --terrainmaterialtest | --terraintest | --citytest | --cityruntime | --havoctest | --walkthrough | --smoke
Logs are written to out_<flag>.txt next to this script.
Prints failure/pass summary lines plus the tail of the log and the exit code.

NOTE: exit code 3221225477 (0xC0000005) is a cosmetic headless-shutdown access
violation on Windows — judge success ONLY by a "finished with 0 failure(s)"
line in the log, not by the process exit code.
"""
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
GIT_ROOT = SCRIPT_DIR.parent
GODOT = GIT_ROOT.parent / "Godot_v4.7.2-stable_win64.exe"
PROJ = GIT_ROOT


def main() -> int:
    flag = sys.argv[1] if len(sys.argv) > 1 else "--citytest"
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    tag = flag.strip("-") or "run"
    outf = SCRIPT_DIR / f"out_{tag}.txt"
    t0 = time.time()
    with open(outf, "w", encoding="utf-8", errors="replace") as f:
        try:
            r = subprocess.run(
                [str(GODOT), "--headless", "--path", str(PROJ), "--", flag],
                stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
            code = r.returncode
        except subprocess.TimeoutExpired:
            code = -99
    dt = time.time() - t0
    text = outf.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    print(f"=== {flag} exit={code} elapsed={dt:.0f}s log={outf} ===")
    # Print failure/pass summary lines and the tail.
    interesting = [
        ln for ln in lines
        if ("FAIL" in ln or "PASS" in ln or "finished with" in ln
            or "ERROR" in ln.upper() or "WATCHDOG" in ln or "SCRIPT ERROR" in ln)
    ]
    for ln in interesting[-80:]:
        print(ln)
    print("--- tail ---")
    for ln in lines[-15:]:
        print(ln)
    return 0


if __name__ == "__main__":
    sys.exit(main())
