from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "AUTOPILOT_STATE.json"
CONTROLLER = ROOT / "tools" / "ring_bell_autopilot_v2.py"
BOARD = "ring-bell-v2"


def should_dispatch(state: dict[str, Any]) -> bool:
    return bool(state.get("enabled")) and state.get("phase") != "paused"


def main() -> int:
    state = json.loads(STATE.read_text(encoding="utf-8"))
    if not should_dispatch(state):
        return 0

    tick = subprocess.run(
        [sys.executable, str(CONTROLLER), "tick"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    tick_output = "\n".join(part for part in (tick.stdout, tick.stderr) if part).strip()
    if tick.returncode != 0:
        print(f"[ring-bell-v2 controller_error] {tick_output}")
        return tick.returncode
    if tick_output:
        print(tick_output)

    dispatch = subprocess.run(
        [
            "hermes",
            "kanban",
            "--board",
            BOARD,
            "dispatch",
            "--max",
            "1",
            "--failure-limit",
            "2",
            "--json",
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if dispatch.returncode != 0:
        output = "\n".join(part for part in (dispatch.stdout, dispatch.stderr) if part).strip()
        print(f"[ring-bell-v2 dispatch_error] {output}")
        return dispatch.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
