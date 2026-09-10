"""Run one ring-bell headless suite via subprocess with file-redirected output.

Usage: python tools/run_suite.py --<flag> [timeout_s] [--rendered] [extra_game_args...]
  flag: --import | --terrainmaterialtest | --terraintest | --citytest | --cityruntime
        | --havoctest | --walkthrough | --smoke | --animationtest | --ruraltest
        | --buildingcontracttest | --g10p2a-ruralprobe
Logs are written to out_<flag>.txt next to this script.
Prints failure/pass summary lines plus the tail of the log and the exit code.

NOTE: exit code 3221225477 (0xC0000005) is a cosmetic headless-shutdown access
violation on Windows — judge success ONLY by a "finished with 0 failure(s)"
line in the log, not by the process exit code.
"""
import subprocess
import os
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
GIT_ROOT = SCRIPT_DIR.parent
# Worktree handling: canonical root is two levels up when in .worktrees/<id>, otherwise parent is correct.
# Try canonical Godot location first, fall back to worktree parent.
_candidate = GIT_ROOT.parent / "Godot_v4.7.2-stable_win64.exe"
_alt = Path("C:/Vibe Code project/Godot Project/Godot_v4.7.2-stable_win64.exe")
GODOT = _alt if _alt.exists() else _candidate
PROJ = GIT_ROOT


def main() -> int:
    flag = sys.argv[1] if len(sys.argv) > 1 else "--citytest"
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    tag = flag.strip("-") or "run"
    game_args = sys.argv[3:]
    rendered = "--rendered" in game_args
    game_args = [arg for arg in game_args if arg != "--rendered"]
    outf = SCRIPT_DIR / f"out_{tag}.txt"
    t0 = time.time()
    # Regression saves/logs belong to the checkout, never the player's
    # ordinary Ring Bell profile. Godot's Windows data path uses APPDATA.
    test_env = os.environ.copy()
    test_env["APPDATA"] = str(SCRIPT_DIR / ".test-user-data")
    Path(test_env["APPDATA"]).mkdir(parents=True, exist_ok=True)
    with open(outf, "w", encoding="utf-8", errors="replace") as f:
        try:
            r = subprocess.run(
                [str(GODOT), *([] if rendered else ["--headless"]), "--path", str(PROJ), "--", flag, *game_args],
                stdout=f, stderr=subprocess.STDOUT, timeout=timeout, env=test_env)
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
    success = "finished with 0 failure(s)" in text
    if flag == "--import":
        success = "[Import] boot OK" in text
    success = success and "SCRIPT ERROR" not in text and "Compilation failed" not in text
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
