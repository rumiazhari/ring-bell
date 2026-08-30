#!/usr/bin/env python3
"""
Ring Bell Common Runtime Helpers
Minimal state helpers for Architect↔Builder loop. Repository-derived recovery.
"""
from __future__ import annotations
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import datetime

REPO = pathlib.Path(__file__).resolve().parents[1]
AUTOPILOT_DIR = REPO / ".hermes" / "autopilot"
RUNTIME_DIR = AUTOPILOT_DIR / "runtime"
LOCK_PATH = AUTOPILOT_DIR / "builder.lock"
TELEGRAM_LEDGER = RUNTIME_DIR / "telegram_notifications.json"

# Ensure runtime exists
RUNTIME_DIR.mkdir(parents=True, exist_ok=True)

def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()

def task_fingerprint() -> str:
    p = AUTOPILOT_DIR / "AUTOPILOT_TASK.md"
    if not p.exists():
        return "no-task"
    return sha256_file(p)[:16]

def git_head(short: bool = True) -> str:
    try:
        r = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short" if short else "HEAD", "HEAD"],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else "unknown"
    except: return "unknown"

def git_head_full() -> str:
    return git_head(short=False)

def heartbeat_write(role: str, action: str, task_hash: str = None, git_head_val: str = None, failure_count: int = 0):
    path = RUNTIME_DIR / f"{role}_heartbeat.json"
    if task_hash is None:
        task_hash = task_fingerprint()
    if git_head_val is None:
        git_head_val = git_head()
    data = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "role": role,
        "action": action,
        "task_hash": task_hash,
        "git_head": git_head_val,
        "failure_count": failure_count,
        "pid": os.getpid(),
        "host": os.environ.get("COMPUTERNAME") or os.environ.get("HOSTNAME") or "unknown",
    }
    # atomic write
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    tmp.replace(path)
    return data

def heartbeat_read(role: str):
    p = RUNTIME_DIR / f"{role}_heartbeat.json"
    if not p.exists(): return None
    try: return json.loads(p.read_text(encoding="utf-8"))
    except: return None

def heartbeat_age_seconds(role: str) -> float:
    hb = heartbeat_read(role)
    if not hb: return float("inf")
    try:
        ts = datetime.datetime.fromisoformat(hb["timestamp"].replace("Z","+00:00"))
        now = datetime.datetime.now(datetime.timezone.utc)
        return (now - ts).total_seconds()
    except: return float("inf")

def is_heartbeat_stale(role: str, threshold_s: int = 1200) -> bool:
    age = heartbeat_age_seconds(role)
    return age > threshold_s

# ---- Lock with stale recovery ----

def lock_acquire(task_hash: str = None, stale_s: int = 1800) -> bool:
    """Try to acquire builder.lock. Returns True if acquired, False if held by live process.
    If stale (>stale_s seconds), removes and acquires."""
    if task_hash is None:
        task_hash = task_fingerprint()
    now = time.time()
    if LOCK_PATH.exists():
        try:
            data = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
            started = data.get("started_at","")
            try:
                ts = datetime.datetime.fromisoformat(started.replace("Z","+00:00")).timestamp()
            except: ts = 0
            age = now - ts
            pid = data.get("pid")
            # stale if age > stale_s OR pid not alive (Windows check)
            stale = age > stale_s
            if not stale and pid:
                # try to check if pid alive (Windows tasklist heuristic)
                try:
                    r = subprocess.run(["tasklist", "/FI", f"PID eq {pid}"], capture_output=True, text=True, timeout=5)
                    if str(pid) not in r.stdout:
                        stale = True
                except: pass
            if stale:
                # recover
                try: LOCK_PATH.unlink()
                except: pass
                print(f"[lock] stale lock recovered pid={pid} age={age:.0f}s", flush=True)
            else:
                return False
        except Exception as e:
            # corrupted lock -> recover
            try: LOCK_PATH.unlink()
            except: pass
            print(f"[lock] corrupted lock recovered: {e}", flush=True)
    # acquire
    data = {
        "pid": os.getpid(),
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "host": os.environ.get("COMPUTERNAME") or "unknown",
        "task_hash": task_hash,
        "git_head": git_head(),
    }
    try:
        # exclusive create - if exists now, race lost
        if LOCK_PATH.exists():
            return False
        LOCK_PATH.write_text(json.dumps(data, indent=2), encoding="utf-8")
        return True
    except: return False

def lock_release(task_hash: str = None):
    if not LOCK_PATH.exists(): return
    try:
        if task_hash:
            data = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
            if data.get("task_hash") != task_hash and data.get("pid") != os.getpid():
                # don't release someone else's lock
                return
        LOCK_PATH.unlink()
    except: pass

def lock_info():
    if not LOCK_PATH.exists(): return None
    try: return json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    except: return None

if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["fingerprint","head","heartbeat","lock-acquire","lock-release","lock-info","heartbeat-stale"])
    p.add_argument("--role", default="builder")
    p.add_argument("--action", default="probe")
    args = p.parse_args()
    if args.cmd == "fingerprint": print(task_fingerprint())
    elif args.cmd == "head": print(git_head())
    elif args.cmd == "heartbeat": print(json.dumps(heartbeat_write(args.role, args.action), indent=2))
    elif args.cmd == "lock-acquire": print(lock_acquire())
    elif args.cmd == "lock-release": lock_release(); print("released")
    elif args.cmd == "lock-info": print(json.dumps(lock_info() or {}, indent=2))
    elif args.cmd == "heartbeat-stale": print(is_heartbeat_stale(args.role))
