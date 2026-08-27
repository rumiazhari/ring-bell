"""Deterministic Ring Bell pilot controller.

This controller is deliberately not an LLM. It creates at most one task for a
state transition, pins every worker to its role/model, and never reassigns a
build card into a review card. Muse build cards remain in Kanban ``review``
after their handoff; a separate Luna review card is created for that handoff.

The controller does not edit production code. It may create Kanban control
cards and audit the project control state. Run from this repository.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
STATE_PATH = ROOT / "AUTOPILOT_STATE.json"
BOARD = "ring-bell"
REPO = "C:/Vibe Code project/Godot Project/ring-bell"
LUNA = "lunaringbell"
MUSE = "museringbell"
LUNA_MODEL = "gpt-5.6-luna"
LUNA_PROVIDER = "openai-codex"
MUSE_MODEL = "muse-spark-1.2-contributor"
MUSE_PROVIDER = "opencode-go"
SPAWNABLE = {"ready", "running"}
REVIEWABLE = {"review"}
OPEN_STATUSES = SPAWNABLE | REVIEWABLE


def load_state() -> dict[str, Any]:
    with STATE_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)


def validate_state(state: dict[str, Any]) -> None:
    required = {
        "schema_version", "project_id", "repo_path", "phase", "revision",
        "milestone", "spec", "acceptance_criteria", "completed_items",
        "remaining_items", "known_bugs", "architectural_decisions",
        "current_builder_task", "last_successful_test", "last_luna_review",
        "escalation", "lease",
    }
    missing = sorted(required - set(state))
    if missing:
        raise RuntimeError("state missing: " + ", ".join(missing))
    if state["schema_version"] != 1 or state["project_id"] != "ring-bell":
        raise RuntimeError("state identity/schema mismatch")
    if state["phase"] not in {
        "needs_architect", "authorized_build", "building", "review",
        "blocked", "paused", "accepted",
    }:
        raise RuntimeError(f"unsupported phase: {state['phase']}")
    if str(state["repo_path"]).replace("\\", "/") != REPO:
        raise RuntimeError("state repo_path is not the canonical Ring Bell path")


def run_kanban(args: list[str]) -> str:
    command = ["hermes", "kanban", "--board", BOARD, *args]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    output = (result.stdout + result.stderr).strip()
    if result.returncode:
        raise RuntimeError(f"kanban command failed ({result.returncode}): {output}")
    return output


def parse_json_output(output: str) -> Any:
    """Parse JSON even when the CLI adds progress text around it."""
    decoder = json.JSONDecoder()
    for index, char in enumerate(output):
        if char not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(output[index:])
        except json.JSONDecodeError:
            continue
        return value
    raise RuntimeError("Kanban command did not return parseable JSON")


def board_tasks() -> list[dict[str, Any]]:
    value = parse_json_output(run_kanban(["list", "--json"]))
    if not isinstance(value, list):
        raise RuntimeError("Kanban list JSON was not an array")
    return [item for item in value if isinstance(item, dict)]


def show_task(task_id: str) -> dict[str, Any]:
    value = parse_json_output(run_kanban(["show", task_id, "--json"]))
    if not isinstance(value, dict) or not isinstance(value.get("task"), dict):
        raise RuntimeError(f"Kanban show returned no task for {task_id}")
    return value


def norm_path(value: Any) -> str:
    return str(value or "").replace("\\", "/").rstrip("/").lower()


def same_repo(task: dict[str, Any]) -> bool:
    return norm_path(task.get("workspace_path")) == norm_path(REPO)


def repo_tasks(tasks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [task for task in tasks if same_repo(task)]


def active_repo_tasks(tasks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        task for task in repo_tasks(tasks)
        if task.get("status") in SPAWNABLE
    ]


def format_tasks(tasks: list[dict[str, Any]]) -> str:
    return ", ".join(
        f"{task.get('id')}:{task.get('status')}:{task.get('assignee')}"
        for task in tasks
    ) or "none"


def require_no_active_actor(tasks: list[dict[str, Any]], purpose: str) -> None:
    active = active_repo_tasks(tasks)
    if active:
        raise RuntimeError(
            f"refusing {purpose}: another Ring Bell actor is active ({format_tasks(active)})"
        )


def create_card(args: list[str]) -> dict[str, Any]:
    output = run_kanban(["create", *args, "--json"])
    value = parse_json_output(output)
    if not isinstance(value, dict) or not value.get("id"):
        raise RuntimeError("Kanban create returned no task id")
    print(json.dumps(value, indent=2))
    return value


def create_luna(state: dict[str, Any]) -> None:
    if state.get("phase") == "paused":
        print("paused: no Luna task created")
        return
    if state["phase"] not in {"needs_architect", "blocked"}:
        print(f"no Luna task: phase={state['phase']}")
        return
    tasks = board_tasks()
    require_no_active_actor(tasks, "Luna architecture task")
    revision = int(state["revision"])
    key = f"ring-bell:architect:revision-{revision}"
    body = f"""Ring Bell architect pass, state revision {revision}.

Read the repository at {REPO}. Inspect AUTOPILOT_STATE.json,
AUTOPILOT_STATE.md historical notes, ARCHITECTURE.md, DEVELOPMENT.md, TODO.md,
and the current test harness. The old iterations were facade-detail focused;
do not continue cosmetic work when higher-value gameplay or architecture
remains.

Choose and specify exactly one highest-value next milestone. Write the detailed
specification to .hermes/autopilot/specs/SPEC-{revision + 1:03d}.md and update
AUTOPILOT_STATE.json. The supervisor will create exactly one Muse build card
only after the state says authorized_build.

Do not edit production code, tests, scenes, assets, or project settings. Do not
create roadmap tasks. If the repository is inconsistent or the user must decide
something, leave the state blocked/needs_architect with a precise reason and
finish through the Kanban completion protocol.
"""
    create_card([
        f"Ring Bell architect pass revision {revision}",
        "--body", body,
        "--assignee", LUNA,
        "--workspace", f"dir:{REPO}",
        "--max-runtime", "30m",
        "--max-retries", "2",
        "--model", LUNA_MODEL,
        "--provider", LUNA_PROVIDER,
        "--skill", "godot-development",
        "--created-by", "pilot-supervisor",
        "--idempotency-key", key,
    ])


def create_muse(state: dict[str, Any]) -> None:
    if state.get("phase") == "paused":
        print("paused: no Muse task created")
        return
    if state["phase"] != "authorized_build":
        print(f"no Muse task: phase={state['phase']}")
        return
    spec = state["spec"].get("path")
    if not spec or not state["spec"].get("approved"):
        raise RuntimeError("authorized_build requires an approved specification path")
    tasks = board_tasks()
    require_no_active_actor(tasks, "Muse build task")

    revision = int(state["revision"])
    milestone_id = str(state["milestone"].get("id"))
    orchestration = state.get("orchestration", {})
    attempt = int(orchestration.get("build_attempt", 1))
    key = f"ring-bell:build:{milestone_id}:revision-{revision}:attempt-{attempt}"
    body = f"""Ring Bell implementation task for state revision {revision}.

Approved Luna specification: {spec}
Specification SHA-256: {state['spec'].get('sha256')}
Milestone: {milestone_id} — {state['milestone'].get('title')}

Implement only this specification. Read AUTOPILOT_STATE.json, AGENTS.md,
AUTOPILOT_POLICY.md, ARCHITECTURE.md, and DEVELOPMENT.md first. Do not choose
another task, create roadmap work, or add facade-only cosmetics. Run the
specified tests, commit coherent stable progress, update evidence, and request
Luna review through Kanban when complete. Escalate architecture ambiguity
instead of inventing a redesign.

IMPORTANT LIFECYCLE RULE: this card belongs to Muse only. When implementation
is complete, leave this card in review with a structured handoff. Do not
reassign or reuse this card as a Luna review card. A separate Luna review card
will be created by the deterministic supervisor.
"""
    create_card([
        f"Ring Bell build {milestone_id} revision {revision} attempt {attempt}",
        "--body", body,
        "--assignee", MUSE,
        "--workspace", f"dir:{REPO}",
        "--max-runtime", "2h",
        "--max-retries", "3",
        "--model", MUSE_MODEL,
        "--provider", MUSE_PROVIDER,
        "--skill", "godot-development",
        "--created-by", "pilot-supervisor",
        "--idempotency-key", key,
    ])


def latest_review_handoff(details: dict[str, Any]) -> dict[str, Any] | None:
    runs = details.get("runs", [])
    candidates = [
        run for run in runs
        if isinstance(run, dict)
        and run.get("status") == "review"
        and run.get("outcome") == "review_requested"
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda run: int(run.get("id", 0)))


def find_review_source(state: dict[str, Any], requested_id: str | None) -> str | None:
    if requested_id:
        return requested_id
    control_id = state.get("orchestration", {}).get("build_task_id")
    if control_id:
        return str(control_id)
    candidates = []
    for task in repo_tasks(board_tasks()):
        if task.get("status") in REVIEWABLE:
            details = show_task(str(task.get("id")))
            if latest_review_handoff(details):
                candidates.append(str(task.get("id")))
    if len(candidates) == 1:
        return candidates[0]
    return None


def create_review(state: dict[str, Any], source_task_id: str | None) -> None:
    if state.get("phase") == "paused":
        print("paused: no Luna review task created")
        return
    source_id = find_review_source(state, source_task_id)
    if not source_id:
        print("no unique Muse review handoff found")
        return
    source = show_task(source_id)
    source_task = source["task"]
    if source_task.get("status") not in REVIEWABLE:
        print(f"no review card: source task {source_id} is {source_task.get('status')}")
        return
    handoff = latest_review_handoff(source)
    if not handoff:
        print(f"no review handoff: source task {source_id}")
        return
    require_no_active_actor(board_tasks(), "Luna review task")

    revision = int(state["revision"])
    milestone_id = str(state["milestone"].get("id"))
    run_id = int(handoff["id"])
    key = f"ring-bell:review:{source_id}:run-{run_id}"
    summary = handoff.get("summary") or "Muse requested Luna review without a summary."
    body = f"""Ring Bell Luna review for Muse task {source_id}, run {run_id}.

Inspect the actual repository at {REPO}, including Git status/diff/history,
AUTOPILOT_STATE.json, the approved specification, and the real test outputs.
Do not trust the builder summary alone.

This is a review-only card. Do not edit production code, tests, scenes, assets,
or project settings. Update only AUTOPILOT_STATE.json and review/report files
under .hermes/autopilot. Compare desired architecture, implemented
architecture, and player-facing behavior. Verify acceptance criteria and
residual risks.

If continuation is correct, set the project state to authorized_build and
record the next bounded builder task. If accepted, set phase accepted. If the
architecture or product direction is ambiguous, set phase needs_architect or
blocked with a precise reason. Finish through the Kanban completion protocol.
Do not create roadmap tasks and do not reassign the source Muse card.

Muse handoff summary:
{summary}
"""
    create_card([
        f"Ring Bell Luna review {milestone_id} source {source_id} run {run_id}",
        "--body", body,
        "--assignee", LUNA,
        "--parent", source_id,
        "--workspace", f"dir:{REPO}",
        "--max-runtime", "30m",
        "--max-retries", "2",
        "--model", LUNA_MODEL,
        "--provider", LUNA_PROVIDER,
        "--skill", "godot-development",
        "--created-by", "pilot-supervisor",
        "--idempotency-key", key,
    ])


def status(state: dict[str, Any]) -> None:
    validate_state(state)
    tasks = repo_tasks(board_tasks())
    print(json.dumps({
        "phase": state["phase"],
        "revision": state["revision"],
        "milestone": state["milestone"],
        "spec": state["spec"],
        "orchestration": state.get("orchestration", {}),
        "repo_tasks": [
            {"id": task.get("id"), "status": task.get("status"), "assignee": task.get("assignee"), "title": task.get("title")}
            for task in tasks
        ],
    }, indent=2))


def audit(state: dict[str, Any]) -> int:
    validate_state(state)
    tasks = repo_tasks(board_tasks())
    active = active_repo_tasks(tasks)
    problems: list[str] = []
    if len(active) > 1:
        problems.append("multiple active Ring Bell actors: " + format_tasks(active))
    for task in active:
        if task.get("assignee") not in {LUNA, MUSE}:
            problems.append(f"unexpected active assignee on {task.get('id')}: {task.get('assignee')}")
    report = {
        "valid_state": True,
        "phase": state["phase"],
        "active_repo_tasks": [
            {"id": task.get("id"), "status": task.get("status"), "assignee": task.get("assignee")}
            for task in active
        ],
        "problems": problems,
        "safe_to_dispatch": not problems and state["phase"] != "paused",
    }
    print(json.dumps(report, indent=2))
    return 1 if problems else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=["validate", "status", "audit", "create-luna", "create-muse", "create-review"],
    )
    parser.add_argument("task_id", nargs="?", help="Muse source task for create-review")
    args = parser.parse_args()
    state = load_state()
    validate_state(state)
    if args.command == "validate":
        print(f"pilot supervisor state valid: revision={state['revision']} phase={state['phase']}")
    elif args.command == "status":
        status(state)
    elif args.command == "audit":
        return audit(state)
    elif args.command == "create-luna":
        create_luna(state)
    elif args.command == "create-muse":
        create_muse(state)
    else:
        create_review(state, args.task_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
