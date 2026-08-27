"""Deterministic Ring Bell pilot state and lease checks.

This helper deliberately never calls an LLM and never deletes files. It is safe
for a supervisor or human to use after a Hermes/Godot/OpenCode crash.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "AUTOPILOT_STATE.json"
LOCK = ROOT / ".hermes" / "autopilot" / "locks" / "pilot.lock"
JUNK = ROOT / "junk" / "autopilot-locks"
VALID_PHASES = {"needs_architect", "authorized_build", "building", "review", "blocked", "paused", "accepted"}
STALE_SECONDS = 4 * 60 * 60


def now() -> float:
    return time.time()


def iso(ts: float | None = None) -> str:
    return datetime.fromtimestamp(ts or now(), timezone.utc).isoformat()


def load_state() -> dict:
    with STATE.open(encoding="utf-8") as f:
        return json.load(f)


def validate() -> None:
    state = load_state()
    required = {"schema_version", "project_id", "repo_path", "phase", "revision", "milestone", "spec", "acceptance_criteria", "completed_items", "remaining_items", "known_bugs", "architectural_decisions", "current_builder_task", "last_successful_test", "last_luna_review", "escalation", "lease"}
    missing = sorted(required - set(state))
    if missing:
        raise SystemExit(f"invalid state: missing keys: {', '.join(missing)}")
    if state["schema_version"] != 1 or state["project_id"] != "ring-bell":
        raise SystemExit("invalid state: wrong schema_version or project_id")
    if state["phase"] not in VALID_PHASES:
        raise SystemExit(f"invalid state: phase={state['phase']}")
    if not isinstance(state["revision"], int) or state["revision"] < 0:
        raise SystemExit("invalid state: revision must be a non-negative integer")
    print(f"state valid: ring-bell revision={state['revision']} phase={state['phase']}")


def quarantine(path: Path, reason: str) -> Path:
    JUNK.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = JUNK / f"{path.stem}-{reason}-{stamp}{path.suffix}"
    shutil.move(str(path), str(target))
    return target


def acquire(owner: str, task_id: str, ttl: int = STALE_SECONDS) -> None:
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    if LOCK.exists():
        age = now() - LOCK.stat().st_mtime
        try:
            previous = json.loads(LOCK.read_text(encoding="utf-8"))
        except Exception:
            previous = {"owner": "unknown", "task_id": "unknown"}
        if previous.get("status") == "active" and age < ttl:
            raise SystemExit(f"pilot lease busy: owner={previous.get('owner')} task={previous.get('task_id')} age={age:.0f}s")
        quarantine(LOCK, "stale")
    payload = {"status": "active", "owner": owner, "task_id": task_id, "pid": os.getpid(), "started_at": iso(), "expires_at": iso(now() + ttl)}
    temp = LOCK.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, LOCK)
    print(f"pilot lease acquired: {task_id}")


def release(owner: str, task_id: str) -> None:
    if not LOCK.exists():
        print("pilot lease already absent")
        return
    current = json.loads(LOCK.read_text(encoding="utf-8"))
    if current.get("owner") != owner or current.get("task_id") != task_id:
        raise SystemExit("refusing to release a lease owned by another task")
    current.update({"status": "released", "released_at": iso()})
    temp = LOCK.with_suffix(".tmp")
    temp.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, LOCK)
    print("pilot lease released")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    acq = sub.add_parser("acquire")
    acq.add_argument("owner")
    acq.add_argument("task_id")
    acq.add_argument("--ttl", type=int, default=STALE_SECONDS)
    rel = sub.add_parser("release")
    rel.add_argument("owner")
    rel.add_argument("task_id")
    args = parser.parse_args()
    if args.command == "validate":
        validate()
    elif args.command == "acquire":
        validate()
        acquire(args.owner, args.task_id, args.ttl)
    else:
        release(args.owner, args.task_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
