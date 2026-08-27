"""Ring Bell pilot supervisor: deterministic routing, no LLM calls.

The supervisor creates at most one idempotent Luna or Muse task for the
current state revision. It never selects milestones and never edits production
code. Run from the Ring Bell repository or pass --root explicitly.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE_PATH = ROOT / "AUTOPILOT_STATE.json"
BOARD = "ring-bell"
REPO = "C:/Vibe Code project/Godot Project/ring-bell"
LUNA = "lunaringbell"
MUSE = "museringbell"


def load_state() -> dict:
    with STATE_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)


def validate_state(state: dict) -> None:
    required = {"schema_version", "project_id", "repo_path", "phase", "revision", "milestone", "spec", "acceptance_criteria", "completed_items", "remaining_items", "known_bugs", "architectural_decisions", "current_builder_task", "last_successful_test", "last_luna_review", "escalation", "lease"}
    missing = sorted(required - set(state))
    if missing:
        raise RuntimeError("state missing: " + ", ".join(missing))
    if state["schema_version"] != 1 or state["project_id"] != "ring-bell":
        raise RuntimeError("state identity/schema mismatch")
    if state["phase"] not in {"needs_architect", "authorized_build", "building", "review", "blocked", "paused", "accepted"}:
        raise RuntimeError(f"unsupported phase: {state['phase']}")
    if state["repo_path"].replace("\\", "/") != REPO:
        raise RuntimeError("state repo_path is not the canonical Ring Bell path")


def run_kanban(args: list[str]) -> str:
    command = ["hermes", "kanban", "--board", BOARD, *args]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    output = (result.stdout + result.stderr).strip()
    if result.returncode:
        raise RuntimeError(f"kanban command failed ({result.returncode}): {output}")
    return output


def parse_json_output(output: str) -> dict | None:
    try:
        value = json.loads(output)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        for line in reversed(output.splitlines()):
            try:
                value = json.loads(line)
                if isinstance(value, dict):
                    return value
            except json.JSONDecodeError:
                continue
    return None


def create_luna(state: dict) -> None:
    if state["phase"] not in {"needs_architect", "blocked"}:
        print(f"no Luna task: phase={state['phase']}")
        return
    revision = state["revision"]
    key = f"ring-bell:architect:revision-{revision}"
    body = f"""Ring Bell architect pass, state revision {revision}.

Read the repository at {REPO}. Inspect Git history, AUTOPILOT_STATE.json,
AUTOPILOT_STATE.md historical notes, ARCHITECTURE.md, DEVELOPMENT.md, TODO.md,
and the current test harness. The old iterations were facade-detail focused;
do not continue cosmetic work when higher-value gameplay or architecture
remains.

Choose and specify the single highest-value next milestone. Write the detailed
specification to .hermes/autopilot/specs/SPEC-{revision + 1:03d}.md and update
AUTOPILOT_STATE.json. The supervisor will create the Muse implementation task
only after the state says authorized_build.

Do not edit production code, tests, scenes, assets, or project settings. Do not
create roadmap tasks. If the current repository is inconsistent or the user
must decide something, leave the state blocked/needs_architect with a precise
reason and finish through the Kanban completion protocol.
"""
    output = run_kanban([
        "create", f"Ring Bell architect pass revision {revision}",
        "--body", body, "--assignee", LUNA,
        "--workspace", f"dir:{REPO}",
        "--max-runtime", "30m", "--max-retries", "2",
        "--model", "gpt-5.6-luna", "--provider", "openai-codex",
        "--created-by", "pilot-supervisor", "--idempotency-key", key, "--json",
    ])
    print(output)


def create_muse(state: dict) -> None:
    if state["phase"] != "authorized_build":
        print(f"no Muse task: phase={state['phase']}")
        return
    spec = state["spec"].get("path")
    if not spec or not state["spec"].get("approved"):
        raise RuntimeError("authorized_build requires an approved specification path")
    revision = state["revision"]
    review_result = state.get("last_luna_review", {}).get("result", "")
    phase_suffix = "continuation-after-review" if review_result.startswith("continuation_") else "initial"
    key = f"ring-bell:build:{state['milestone']['id']}:revision-{revision}:{phase_suffix}"
    title_suffix = " continuation" if phase_suffix != "initial" else ""
    body = f"""Ring Bell implementation task for state revision {revision}.

Approved Luna specification: {spec}
Specification SHA-256: {state['spec'].get('sha256')}
Milestone: {state['milestone'].get('id')} — {state['milestone'].get('title')}

Implement only this specification. Read AUTOPILOT_STATE.json, AGENTS.md,
AUTOPILOT_POLICY.md, ARCHITECTURE.md, and DEVELOPMENT.md first. Do not choose
another task, create roadmap work, or add facade-only cosmetics. Run the
specified tests, commit coherent stable progress, update evidence, and request
Luna review through Kanban when complete. Escalate architecture ambiguity
instead of inventing a redesign.
"""
    output = run_kanban([
        "create", f"Ring Bell build {state['milestone']['id']} revision {revision}{title_suffix}",
        "--body", body, "--assignee", MUSE,
        "--workspace", f"dir:{REPO}",
        "--max-runtime", "2h", "--max-retries", "3",
        "--created-by", "pilot-supervisor", "--idempotency-key", key, "--json",
    ])
    print(output)


def create_review(state: dict) -> None:
    if state["phase"] not in {"authorized_build", "review", "blocked"}:
        print(f"no Luna review task: phase={state['phase']}")
        return
    revision = state["revision"]
    milestone = state["milestone"].get("id") or "unknown-milestone"
    reports_dir = ROOT / ".hermes" / "autopilot" / "reports"
    review_number = len(list(reports_dir.glob("REVIEW-*.md"))) + 1
    key = f"ring-bell:review:{milestone}:revision-{revision}:review-{review_number}"
    body = f"""Ring Bell Luna review for state revision {revision} (review {review_number}).

Inspect the actual repository at {REPO}, including the current Git diff and
commits, AUTOPILOT_STATE.json, the approved specification, and the real test
outputs. This review was requested after Muse reported a bounded partial
implementation of {milestone}. Do not trust the builder summary alone.

Evaluate desired architecture vs implemented architecture vs player-facing
behavior. Check scope drift, acceptance evidence, regressions, maintainability,
and whether the work is worth continuing. Review commits 6c36a6c and 14f05bc
and all subsequent changes in the Ring Bell repository.

Do not edit production code, tests, scenes, assets, or project settings. Update
only AUTOPILOT_STATE.json and review/report files under .hermes/autopilot.
If continuation is correct, keep or set phase authorized_build and record the
next bounded builder task and exact remaining acceptance criteria. If the
implementation is accepted, set phase accepted and record final evidence. If
architecture or product direction is ambiguous, set phase needs_architect or
blocked with a precise reason. Finish through the Kanban completion protocol;
do not create roadmap tasks.
"""
    output = run_kanban([
        "create", f"Ring Bell Luna review {milestone} revision {revision}",
        "--body", body, "--assignee", LUNA,
        "--workspace", f"dir:{REPO}",
        "--max-runtime", "30m", "--max-retries", "2",
        "--model", "gpt-5.6-luna", "--provider", "openai-codex",
        "--created-by", "pilot-supervisor", "--idempotency-key", key, "--json",
    ])
    print(output)


def status(state: dict) -> None:
    validate_state(state)
    print(json.dumps({"phase": state["phase"], "revision": state["revision"], "milestone": state["milestone"], "spec": state["spec"], "escalation": state["escalation"]}, indent=2))
    print(run_kanban(["list", "--json", "--sort", "updated"]))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["validate", "status", "create-luna", "create-muse", "create-review"])
    args = parser.parse_args()
    state = load_state()
    validate_state(state)
    if args.command == "validate":
        print(f"pilot supervisor state valid: revision={state['revision']} phase={state['phase']}")
    elif args.command == "status":
        status(state)
    elif args.command == "create-luna":
        create_luna(state)
    elif args.command == "create-muse":
        create_muse(state)
    else:
        create_review(state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
