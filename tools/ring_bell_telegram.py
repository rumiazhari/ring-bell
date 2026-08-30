#!/usr/bin/env python3
"""
Ring Bell Telegram helper — HUMAN OBSERVABILITY ONLY, never authoritative.
Must never block Architect/Builder. Dedup ledger is observability, not lifecycle state.
"""
from __future__ import annotations
import hashlib
import json
import pathlib
import subprocess
import datetime
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
RUNTIME_DIR = REPO / ".hermes" / "autopilot" / "runtime"
LEDGER = RUNTIME_DIR / "telegram_notifications.json"
RUNTIME_DIR.mkdir(parents=True, exist_ok=True)

DEDUP_WINDOW_S = 3600  # 1h dedup for same fingerprint

def _load_ledger():
    if not LEDGER.exists(): return {}
    try: return json.loads(LEDGER.read_text(encoding="utf-8"))
    except: return {}

def _save_ledger(data):
    tmp = LEDGER.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    tmp.replace(LEDGER)

def _fingerprint(event_type: str, content: str) -> str:
    h = hashlib.sha256()
    h.update(f"{event_type}:{content}".encode())
    return h.hexdigest()[:16]

def should_send(event_type: str, content: str) -> bool:
    fp = _fingerprint(event_type, content)
    ledger = _load_ledger()
    entry = ledger.get(fp)
    if not entry: return True
    try:
        ts = datetime.datetime.fromisoformat(entry["timestamp"].replace("Z","+00:00"))
        age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
        return age > DEDUP_WINDOW_S
    except: return True

def record(event_type: str, content: str, ok: bool, error: str = ""):
    fp = _fingerprint(event_type, content)
    ledger = _load_ledger()
    ledger[fp] = {
        "event_type": event_type,
        "fingerprint": fp,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "ok": ok,
        "error": error[:300] if error else "",
    }
    # prune old >100 entries (keep last 100)
    if len(ledger) > 100:
        # sort by timestamp keep newest 100
        sorted_items = sorted(ledger.items(), key=lambda kv: kv[1].get("timestamp",""), reverse=True)
        ledger = dict(sorted_items[:100])
    try: _save_ledger(ledger)
    except: pass

def send(event_type: str, message: str, dedup_key: str = None) -> bool:
    """
    Send Telegram via hermes send --to telegram:518829299.
    dedup_key overrides fingerprint content (if provided).
    Returns True if attempted (sent or deduped), False only on hard misuse.
    Never raises, never blocks caller for long.
    """
    content = dedup_key if dedup_key is not None else message
    if not should_send(event_type, content):
        print(f"[telegram] deduped {event_type} fp={_fingerprint(event_type, content)}", flush=True)
        return True
    # try send via hermes
    try:
        r = subprocess.run(["hermes", "send", "--to", "telegram:518829299", message],
                           capture_output=True, text=True, timeout=20)
        ok = r.returncode == 0
        err = (r.stderr or r.stdout or "")[:500] if not ok else ""
        if ok:
            print(f"[telegram] sent {event_type}", flush=True)
        else:
            print(f"[telegram] failed {event_type} rc={r.returncode} {err[:200]}", flush=True)
        record(event_type, content, ok, err)
        # Telegram failure must NOT block development — return True regardless
        return True
    except Exception as e:
        print(f"[telegram] exception {event_type}: {e}", flush=True)
        try: record(event_type, content, False, str(e))
        except: pass
        return True  # still not blocking

def send_raw(message: str) -> bool:
    # convenience: event_type derived from first line
    first = message.split("\n")[0].strip()[:40]
    return send(first, message)

if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("event_type", nargs="?", default="test")
    p.add_argument("message", nargs="?", default="🌍 Ring Bell — test telegram")
    args = p.parse_args()
    ok = send(args.event_type, args.message)
    sys.exit(0 if ok else 1)
