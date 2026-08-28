from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import Any

BOARD = "ring-bell-v2"
REPO = "C:/Vibe Code project/Godot Project/ring-bell"
ARCHITECT_PROFILE = "lunaringbell"
BUILDER_PROFILE = "museringbell"
MODEL = "gpt-5.6-luna"
PROVIDER = "openai-codex"
# OpenAI Codex rejects the literal value "ultra". For GPT-5.6, "max" is the
# highest supported reasoning tier and is the requested Luna Ultra mapping.
REASONING_EFFORT = "max"
MAX_REVISION_ROUNDS = 2
GRAND_PLAN_SHA256 = "06bf72c031b2bbf94bc162825388711e4c3f47e0b55a7f78a5dcd76072bfbca8"
ACTIVE_STATUSES = {"ready", "running"}
ROOT = Path(__file__).resolve().parents[1]
STATE_PATH = ROOT / "AUTOPILOT_STATE.json"
DECISIONS_PATH = ROOT / ".hermes" / "autopilot" / "decisions"


class InvariantError(RuntimeError):
    pass


class DecisionError(RuntimeError):
    pass


def initial_state() -> dict[str, Any]:
    return {
        "schema_version": 2,
        "project_id": "ring-bell",
        "controller": "ring-bell-autopilot-v2",
        "board": BOARD,
        "repo_path": REPO,
        "enabled": False,
        "phase": "paused",
        "pause_reason": "Configured only; explicit user start is required.",
        "grand_plan": {
            "path": ".hermes/autopilot/GRAND_PLAN.md",
            "source_path": ".hermes/plans/2026-08-27_224936-ring-bell-macro-world-plan.md",
            "source_sha256": GRAND_PLAN_SHA256,
            "principle": "Maximize sustained player enjoyment.",
        },
        "roles": {
            "architect_reviewer": {
                "profile": ARCHITECT_PROFILE,
                "model": MODEL,
                "provider": PROVIDER,
                "reasoning_effort": REASONING_EFFORT,
            },
            "builder": {
                "profile": BUILDER_PROFILE,
                "model": MODEL,
                "provider": PROVIDER,
                "reasoning_effort": REASONING_EFFORT,
            },
        },
        "policy": {
            "max_revision_rounds": MAX_REVISION_ROUNDS,
            "minor_findings": "defer_to_next_design",
            "principal_findings": "architect_designs_bounded_revision",
            "revision_limit_outcome": "architect_recovery_cycle",
            "post_acceptance": "next_architect_cycle",
            "one_active_writer": True,
            "review_link_is_nonblocking": True,
        },
        "current": {
            "cycle": 1,
            "revision_round": 0,
            "milestone_id": None,
            "milestone_title": None,
            "spec_path": None,
            "spec_sha256": None,
            "acceptance_criteria": [],
            "required_tests": [],
            "gameplay_value": None,
            "architect_task_id": None,
            "build_task_id": None,
            "build_handoff_run": None,
            "review_task_id": None,
        },
        "deferred_findings": [],
        "accepted_milestones": [],
        "history": [],
    }


def validate_state(state: dict[str, Any]) -> None:
    required = {
        "schema_version",
        "project_id",
        "controller",
        "board",
        "repo_path",
        "enabled",
        "phase",
        "grand_plan",
        "roles",
        "policy",
        "current",
        "deferred_findings",
        "accepted_milestones",
        "history",
    }
    missing = sorted(required - state.keys())
    if missing:
        raise InvariantError("state missing: " + ", ".join(missing))
    if state["schema_version"] != 2 or state["project_id"] != "ring-bell":
        raise InvariantError("state identity/schema mismatch")
    if state["board"] != BOARD or state["repo_path"] != REPO:
        raise InvariantError("state points outside the v2 Ring Bell control plane")
    if state["phase"] == "paused" and state["enabled"]:
        raise InvariantError("paused state cannot be enabled")
    if state["policy"].get("max_revision_rounds") != MAX_REVISION_ROUNDS:
        raise InvariantError("revision cap drift")
    for role_name, profile in (
        ("architect_reviewer", ARCHITECT_PROFILE),
        ("builder", BUILDER_PROFILE),
    ):
        role = state["roles"].get(role_name, {})
        expected = (profile, MODEL, PROVIDER, REASONING_EFFORT)
        actual = (
            role.get("profile"),
            role.get("model"),
            role.get("provider"),
            role.get("reasoning_effort"),
        )
        if actual != expected:
            raise InvariantError(f"{role_name} model/profile pin drift")
    round_number = state["current"].get("revision_round")
    if not isinstance(round_number, int) or not 0 <= round_number <= MAX_REVISION_ROUNDS:
        raise InvariantError("invalid revision round")


def next_action(state: dict[str, Any], tasks: list[dict[str, Any]]) -> dict[str, str]:
    validate_state(state)
    active = [task for task in tasks if task.get("status") in ACTIVE_STATUSES]
    if len(active) > 1:
        ids = ", ".join(str(task.get("id")) for task in active)
        raise InvariantError(f"multiple active actors: {ids}")
    if not state["enabled"] or state["phase"] == "paused":
        return {"kind": "none", "reason": "paused"}
    if active:
        return {"kind": "wait", "reason": f"active task {active[0].get('id')}"}
    mapping = {
        "needs_architect": "create_architect",
        "ready_to_build": "create_builder",
        "revision_ready": "create_builder",
        "awaiting_review": "create_review",
    }
    kind = mapping.get(state["phase"], "reconcile")
    return {"kind": kind, "reason": state["phase"]}


def architect_task_arguments(state: dict[str, Any]) -> list[str]:
    validate_state(state)
    if state["phase"] != "needs_architect":
        raise InvariantError("architect task requires phase=needs_architect")
    cycle = int(state["current"]["cycle"])
    decision_path = f".hermes/autopilot/decisions/ARCHITECT-C{cycle:03d}.json"
    deferred = state.get("deferred_findings") or []
    body = "\n".join(
        [
            "You are the sole Ring Bell architect and later reviewer.",
            "Read AGENTS.md, AUTOPILOT_POLICY.md, AUTOPILOT_STATE.json, .hermes/autopilot/GRAND_PLAN.md, the saved macro-world plan, Git history, current code, and tests.",
            "Expand the user's grand plan into exactly one bounded technical construction milestone that will maximize sustained player enjoyment.",
            "Prefer playable systems, meaningful exploration/survival decisions, tactile feedback, coherent world progression, and technical foundations that unlock future fun.",
            "You own roadmap selection, architecture, interfaces, sequencing, acceptance criteria, and rollback design.",
            "You must not edit production code, tests, scenes, assets, or project settings.",
            "Write one executable specification under .hermes/autopilot/specs/ with 3-7 independently verifiable acceptance criteria and a bounded test plan.",
            f"Write the machine decision to {decision_path}; use decision=authorize_build and cycle={cycle}.",
            "Carry relevant deferred findings into this design when they fit naturally; do not create a polish-only loop.",
            "Do not create or dispatch a builder card. The deterministic controller owns routing.",
            f"Deferred findings JSON: {deferred}",
        ]
    )
    return [
        "create",
        f"Ring Bell architect cycle {cycle:03d}",
        "--body",
        body,
        "--assignee",
        ARCHITECT_PROFILE,
        "--workspace",
        f"dir:{REPO}",
        "--max-runtime",
        "90m",
        "--max-retries",
        "2",
        "--model",
        MODEL,
        "--provider",
        PROVIDER,
        "--skill",
        "godot-development",
        "--idempotency-key",
        f"ring-bell-v2:architect:c{cycle}",
        "--created-by",
        "ring-bell-autopilot-v2",
        "--json",
    ]


def apply_architect_decision(state: dict[str, Any], decision: dict[str, Any]) -> dict[str, Any]:
    validate_state(state)
    if state["phase"] != "architecting":
        raise DecisionError("architect decision requires phase=architecting")
    cycle = int(state["current"]["cycle"])
    if decision.get("decision") != "authorize_build" or decision.get("cycle") != cycle:
        raise DecisionError("architect decision identity mismatch")
    milestone_id = str(decision.get("milestone_id") or "").strip()
    milestone_title = str(decision.get("milestone_title") or "").strip()
    gameplay_value = str(decision.get("gameplay_value") or "").strip()
    spec_path = decision.get("spec_path")
    digest = decision.get("spec_sha256")
    criteria = decision.get("acceptance_criteria")
    tests = decision.get("required_tests")
    if not milestone_id or not milestone_title or not gameplay_value:
        raise DecisionError("architect decision requires milestone identity and gameplay value")
    if not isinstance(spec_path, str) or not spec_path.startswith(".hermes/autopilot/specs/"):
        raise DecisionError("architect spec must live under .hermes/autopilot/specs/")
    if not isinstance(digest, str) or len(digest) != 64:
        raise DecisionError("architect decision requires a sha256")
    if not isinstance(criteria, list) or not 3 <= len(criteria) <= 7 or any(not isinstance(x, str) or not x.strip() for x in criteria):
        raise DecisionError("architect must define 3-7 non-empty acceptance criteria")
    if not isinstance(tests, list) or not 1 <= len(tests) <= 8 or any(not isinstance(x, str) or not x.strip() for x in tests):
        raise DecisionError("architect must define 1-8 required tests")
    result = copy.deepcopy(state)
    current = result["current"]
    current.update(
        {
            "milestone_id": milestone_id,
            "milestone_title": milestone_title,
            "gameplay_value": gameplay_value,
            "spec_path": spec_path,
            "spec_sha256": digest,
            "acceptance_criteria": list(criteria),
            "required_tests": list(tests),
            "build_task_id": None,
            "build_handoff_run": None,
            "review_task_id": None,
        }
    )
    result["phase"] = "ready_to_build"
    result["history"].append(
        {
            "event": "build_authorized",
            "cycle": cycle,
            "milestone_id": milestone_id,
            "spec_path": spec_path,
        }
    )
    return result


def builder_task_arguments(state: dict[str, Any]) -> list[str]:
    validate_state(state)
    if state["phase"] not in {"ready_to_build", "revision_ready"}:
        raise InvariantError("builder task requires an authorized build phase")
    current = state["current"]
    spec = current.get("spec_path")
    digest = current.get("spec_sha256")
    if not spec or not digest:
        raise InvariantError("builder task requires an approved specification")
    cycle = int(current["cycle"])
    revision_round = int(current["revision_round"])
    criteria = current.get("acceptance_criteria") or []
    tests = current.get("required_tests") or []
    body = "\n".join(
        [
            "You are the Ring Bell builder. The architect exclusively owns product direction and technical design.",
            f"Implement only the approved specification: {spec}",
            f"Approved specification SHA-256: {digest}",
            f"Milestone: {current.get('milestone_id')} — {current.get('milestone_title')}",
            f"Gameplay value: {current.get('gameplay_value')}",
            f"Acceptance criteria: {criteria}",
            f"Required tests: {tests}",
            "Do not select roadmap work, broaden scope, redesign architecture, or substitute unrelated polish.",
            "Use strict TDD for new behavior, preserve user files, commit coherent verified construction, and record exact test evidence.",
            "If the specification conflicts with the real repository, report the exact conflict; do not invent a new design.",
            "When the construction is complete, request review with changed files, commits, tests, player-facing evidence, and residual risks.",
            "Do not create the reviewer card and do not edit AUTOPILOT_STATE.json.",
        ]
    )
    return [
        "create",
        f"Ring Bell build C{cycle:03d} R{revision_round:02d} {current.get('milestone_id')}",
        "--body",
        body,
        "--assignee",
        BUILDER_PROFILE,
        "--workspace",
        f"dir:{REPO}",
        "--max-runtime",
        "3h",
        "--max-retries",
        "2",
        "--model",
        MODEL,
        "--provider",
        PROVIDER,
        "--skill",
        "godot-development",
        "--skill",
        "test-driven-development",
        "--idempotency-key",
        f"ring-bell-v2:build:c{cycle}:r{revision_round}:{current.get('milestone_id')}",
        "--created-by",
        "ring-bell-autopilot-v2",
        "--json",
    ]


def review_task_arguments(state: dict[str, Any]) -> list[str]:
    validate_state(state)
    current = state["current"]
    source = current.get("build_task_id")
    run = current.get("build_handoff_run")
    if not source or run is None:
        raise InvariantError("review requires a source task and handoff run")
    cycle = int(current["cycle"])
    revision_round = int(current["revision_round"])
    body = "\n".join(
        [
            "You are the sole Ring Bell architect acting as independent implementation reviewer.",
            f"review_of_task: {source}",
            f"review_of_run: {run}",
            "nonblocking_review_link: true",
            f"Approved specification: {current.get('spec_path')}",
            f"Approved specification SHA-256: {current.get('spec_sha256')}",
            f"Revision round: {revision_round} of {MAX_REVISION_ROUNDS}",
            "Do not edit production code, tests, scenes, assets, or project settings.",
            "Inspect the real repository, commits/diff, test outputs, conflicts, performance/save compatibility, and ordinary player-facing behavior against the design.",
            "Write a human report under .hermes/autopilot/reports/ and the machine decision to "
            f".hermes/autopilot/decisions/REVIEW-C{cycle:03d}-R{revision_round:02d}.json.",
            "Allowed verdicts: accept; accept_with_deferred for minor findings; revise only for a principal blocker below the revision cap; recovery_required when another direct patch loop is wrong or the cap is reached.",
            "If revise, write a bounded revision specification and include revision_spec plus revision_spec_sha256. Never create or dispatch a builder card.",
        ]
    )
    return [
        "create",
        f"Ring Bell review C{cycle:03d} R{revision_round:02d}",
        "--body",
        body,
        "--assignee",
        ARCHITECT_PROFILE,
        "--workspace",
        f"dir:{REPO}",
        "--max-runtime",
        "60m",
        "--max-retries",
        "2",
        "--model",
        MODEL,
        "--provider",
        PROVIDER,
        "--idempotency-key",
        f"ring-bell-v2:review:c{cycle}:r{revision_round}:task:{source}:run:{run}",
        "--created-by",
        "ring-bell-autopilot-v2",
        "--json",
    ]


def tick_once(
    state: dict[str, Any],
    board: Any,
    *,
    decision_loader: Any,
) -> tuple[dict[str, Any], list[str]]:
    """Advance at most one deterministic transition.

    The board adapter owns persistence. This function never dispatches workers and
    intentionally emits messages only for state transitions.
    """
    validate_state(state)
    tasks = board.list_tasks()
    action = next_action(state, tasks)
    if action["kind"] in {"none", "wait"}:
        return state, []

    result = copy.deepcopy(state)
    messages: list[str] = []
    current = result["current"]
    if action["kind"] == "create_architect":
        task = board.create_task(architect_task_arguments(result))
        current["architect_task_id"] = task["id"]
        result["phase"] = "architecting"
        messages.append(f"architect task created: {task['id']}")
        return result, messages

    if action["kind"] == "create_builder":
        task = board.create_task(builder_task_arguments(result))
        current["build_task_id"] = task["id"]
        current["build_handoff_run"] = None
        current["review_task_id"] = None
        result["phase"] = "building"
        messages.append(f"builder task created: {task['id']}")
        return result, messages

    if action["kind"] == "create_review":
        task = board.create_task(review_task_arguments(result))
        current["review_task_id"] = task["id"]
        result["phase"] = "reviewing"
        messages.append(f"review task created: {task['id']}")
        return result, messages

    phase = result["phase"]
    if phase == "architecting":
        task_id = current.get("architect_task_id")
        if not task_id:
            raise InvariantError("architecting state has no task id")
        wrapper = board.show_task(task_id)
        status = _task_record(wrapper).get("status")
        if status == "done":
            name = f"ARCHITECT-C{int(current['cycle']):03d}.json"
            decision = decision_loader(name)
            result = apply_architect_decision(result, decision)
            messages.append(f"architect decision applied: {name}")
        elif status not in {"todo", "ready", "running"}:
            raise InvariantError(f"architect task {task_id} ended without an applicable decision: {status}")
        return result, messages

    if phase == "building":
        task_id = current.get("build_task_id")
        if not task_id:
            raise InvariantError("building state has no task id")
        wrapper = board.show_task(task_id)
        task = _task_record(wrapper)
        if task.get("status") == "review":
            handoffs = [
                run
                for run in (wrapper.get("runs") or [])
                if run.get("status") == "review" and run.get("outcome") == "review_requested"
            ]
            if not handoffs:
                raise InvariantError(f"builder task {task_id} is in review without a review_requested run")
            current["build_handoff_run"] = max(int(run["id"]) for run in handoffs)
            result["phase"] = "awaiting_review"
            messages.append(f"builder handoff recorded: {task_id}:{current['build_handoff_run']}")
        elif task.get("status") not in {"todo", "ready", "running"}:
            raise InvariantError(f"builder task {task_id} ended without requesting review: {task.get('status')}")
        return result, messages

    if phase == "reviewing":
        task_id = current.get("review_task_id")
        if not task_id:
            raise InvariantError("reviewing state has no review task id")
        wrapper = board.show_task(task_id)
        status = _task_record(wrapper).get("status")
        if status == "done":
            name = f"REVIEW-C{int(current['cycle']):03d}-R{int(current['revision_round']):02d}.json"
            decision = decision_loader(name)
            source_id = current.get("build_task_id")
            if not source_id:
                raise InvariantError("review decision has no source build task")
            board.complete_task(source_id, str(decision.get("verdict")))
            result = apply_review_decision(result, decision)
            messages.append(f"review decision applied: {name}")
        elif status not in {"todo", "ready", "running"}:
            raise InvariantError(f"review task {task_id} ended without an applicable decision: {status}")
        return result, messages

    raise InvariantError(f"unsupported controller phase: {phase}")


def _task_record(wrapper: dict[str, Any]) -> dict[str, Any]:
    task = wrapper.get("task", wrapper)
    if not isinstance(task, dict) or not task.get("id"):
        raise InvariantError("Kanban response has no task record")
    return task


def apply_review_decision(state: dict[str, Any], decision: dict[str, Any]) -> dict[str, Any]:
    validate_state(state)
    if state["phase"] != "reviewing":
        raise DecisionError("review decision requires phase=reviewing")
    verdict = decision.get("verdict")
    severity = decision.get("severity")
    summary = str(decision.get("summary") or "").strip()
    if not summary:
        raise DecisionError("review decision requires a summary")
    if verdict == "revise" and severity == "minor":
        raise DecisionError("minor findings must be deferred to the next design")

    result = copy.deepcopy(state)
    current = result["current"]
    if verdict == "revise":
        if severity != "principal":
            raise DecisionError("revision requires principal severity")
        if current["revision_round"] >= result["policy"]["max_revision_rounds"]:
            raise DecisionError("revision limit reached; use recovery_required")
        spec = decision.get("revision_spec")
        digest = decision.get("revision_spec_sha256")
        if not isinstance(spec, str) or not spec.startswith(".hermes/autopilot/specs/"):
            raise DecisionError("revision requires a repository-local revision spec")
        if not isinstance(digest, str) or len(digest) != 64:
            raise DecisionError("revision requires a sha256")
        current["revision_round"] += 1
        current["spec_path"] = spec
        current["spec_sha256"] = digest
        current["build_task_id"] = None
        current["build_handoff_run"] = None
        current["review_task_id"] = None
        result["phase"] = "revision_ready"
        result["history"].append(
            {
                "event": "revision_authorized",
                "cycle": current["cycle"],
                "revision_round": current["revision_round"],
                "summary": summary,
            }
        )
        return result

    if verdict not in {"accept", "accept_with_deferred", "recovery_required"}:
        raise DecisionError(f"unsupported review verdict: {verdict}")
    if verdict == "accept" and severity not in {"none", None}:
        raise DecisionError("accept verdict cannot carry a defect severity")
    if verdict == "accept_with_deferred" and severity != "minor":
        raise DecisionError("accept_with_deferred requires minor severity")
    if verdict == "recovery_required" and severity != "principal":
        raise DecisionError("recovery_required requires principal severity")

    findings = decision.get("deferred_findings") or []
    if not isinstance(findings, list) or any(not isinstance(item, str) for item in findings):
        raise DecisionError("deferred_findings must be a list of strings")
    for finding in findings:
        result["deferred_findings"].append(
            {
                "from_cycle": current["cycle"],
                "finding": finding,
                "source_verdict": verdict,
            }
        )
    if verdict in {"accept", "accept_with_deferred"}:
        result["accepted_milestones"].append(
            {
                "cycle": current["cycle"],
                "milestone_id": current.get("milestone_id"),
                "title": current.get("milestone_title"),
                "revision_rounds": current.get("revision_round"),
                "verdict": verdict,
                "summary": summary,
            }
        )
    result["history"].append(
        {
            "event": verdict,
            "cycle": current["cycle"],
            "revision_round": current["revision_round"],
            "summary": summary,
        }
    )
    _advance_to_next_architect_cycle(result)
    return result


def _advance_to_next_architect_cycle(state: dict[str, Any]) -> None:
    next_cycle = int(state["current"]["cycle"]) + 1
    state["phase"] = "needs_architect"
    state["pause_reason"] = None
    state["current"] = {
        "cycle": next_cycle,
        "revision_round": 0,
        "milestone_id": None,
        "milestone_title": None,
        "spec_path": None,
        "spec_sha256": None,
        "acceptance_criteria": [],
        "required_tests": [],
        "gameplay_value": None,
        "architect_task_id": None,
        "build_task_id": None,
        "build_handoff_run": None,
        "review_task_id": None,
    }


def save_state(path: Path, state: dict[str, Any]) -> None:
    validate_state(state)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def load_state(path: Path = STATE_PATH) -> dict[str, Any]:
    state = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(state, dict):
        raise InvariantError("state root must be an object")
    validate_state(state)
    return state


def parse_json_output(raw: str) -> Any:
    text = raw.strip()
    if not text:
        raise InvariantError("Kanban command returned no JSON")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        decoder = json.JSONDecoder()
        for index, char in enumerate(text):
            if char not in "[{":
                continue
            try:
                value, _end = decoder.raw_decode(text[index:])
            except json.JSONDecodeError:
                continue
            return value
    raise InvariantError("Kanban command did not return parseable JSON")


class HermesBoard:
    def _run(self, arguments: list[str]) -> str:
        command = ["hermes", "kanban", "--board", BOARD, *arguments]
        completed = subprocess.run(
            command,
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
        output = "\n".join(part for part in (completed.stdout, completed.stderr) if part).strip()
        if completed.returncode != 0:
            raise InvariantError(f"Kanban command failed ({completed.returncode}): {output}")
        return output

    def list_tasks(self) -> list[dict[str, Any]]:
        value = parse_json_output(self._run(["list", "--json"]))
        tasks = value.get("tasks", []) if isinstance(value, dict) else value
        if not isinstance(tasks, list):
            raise InvariantError("Kanban list did not return a task list")
        return tasks

    def create_task(self, arguments: list[str]) -> dict[str, Any]:
        return _task_record(parse_json_output(self._run(arguments)))

    def show_task(self, task_id: str) -> dict[str, Any]:
        value = parse_json_output(self._run(["show", task_id, "--json"]))
        if not isinstance(value, dict):
            raise InvariantError(f"Kanban show returned invalid data for {task_id}")
        return value

    def complete_task(self, task_id: str, result: str) -> None:
        self._run(["complete", task_id, "--result", result])


def _load_decision(decision_root: Path, name: str) -> dict[str, Any]:
    path = Path(decision_root) / name
    if not path.is_file():
        raise DecisionError(f"decision file is missing: {path}")
    decision = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(decision, dict):
        raise DecisionError(f"decision file must contain an object: {path}")
    spec_path = decision.get("spec_path") or decision.get("revision_spec")
    digest = decision.get("spec_sha256") or decision.get("revision_spec_sha256")
    if spec_path or digest:
        if not isinstance(spec_path, str) or not isinstance(digest, str):
            raise DecisionError("decision spec path/hash must be supplied together")
        candidate = (ROOT / spec_path).resolve()
        specs_root = (ROOT / ".hermes" / "autopilot" / "specs").resolve()
        try:
            candidate.relative_to(specs_root)
        except ValueError as exc:
            raise DecisionError("decision spec escapes the v2 specs directory") from exc
        if not candidate.is_file():
            raise DecisionError(f"approved specification is missing: {spec_path}")
        actual = hashlib.sha256(candidate.read_bytes()).hexdigest()
        if actual != digest:
            raise DecisionError(f"approved specification hash mismatch: {spec_path}")
    return decision


def controller_main(
    argv: list[str] | None = None,
    *,
    board_factory: Any = HermesBoard,
    decision_root: Path = DECISIONS_PATH,
) -> int:
    parser = argparse.ArgumentParser(description="Ring Bell deterministic architect-builder controller v2")
    parser.add_argument("--state", type=Path, default=STATE_PATH)
    parser.add_argument("command", choices=("validate", "status", "audit", "tick", "pause", "resume"))
    args = parser.parse_args(argv)
    state = load_state(args.state)

    if args.command == "validate":
        print(f"state valid: ring-bell v2 phase={state['phase']} cycle={state['current']['cycle']}")
        return 0
    if args.command == "status":
        print(json.dumps(state, indent=2))
        return 0

    board = board_factory()
    if args.command == "audit":
        tasks = board.list_tasks()
        next_action(state, tasks)
        active = [task for task in tasks if task.get("status") in ACTIVE_STATUSES]
        if (not state["enabled"] or state["phase"] == "paused") and active:
            raise InvariantError("paused controller has active Ring Bell v2 tasks")
        print(f"audit clean: phase={state['phase']} tasks={len(tasks)} active={len(active)}")
        return 0
    if args.command == "pause":
        active = [task for task in board.list_tasks() if task.get("status") in ACTIVE_STATUSES]
        if active:
            raise InvariantError("refusing to pause while a task is ready or running")
        state["enabled"] = False
        state["phase"] = "paused"
        state["pause_reason"] = "Paused by explicit controller command."
        save_state(args.state, state)
        print("Ring Bell autopilot v2 paused")
        return 0
    if args.command == "resume":
        if state["enabled"] or state["phase"] != "paused":
            raise InvariantError("resume requires the configured paused state")
        if any(task.get("status") in ACTIVE_STATUSES for task in board.list_tasks()):
            raise InvariantError("refusing to resume with an active Ring Bell v2 task")
        state["enabled"] = True
        state["phase"] = "needs_architect"
        state["pause_reason"] = None
        save_state(args.state, state)
        print("Ring Bell autopilot v2 armed; architect routing begins on the next tick")
        return 0

    updated, messages = tick_once(
        state,
        board,
        decision_loader=lambda name: _load_decision(decision_root, name),
    )
    if updated != state:
        save_state(args.state, updated)
    for message in messages:
        print(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(controller_main())
