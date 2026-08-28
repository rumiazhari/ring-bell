from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from tools.ring_bell_autopilot_tick import should_dispatch
from tools.ring_bell_autopilot_v2 import (
    ARCHITECT_PROFILE,
    BOARD,
    BUILDER_PROFILE,
    MODEL,
    PROVIDER,
    REASONING_EFFORT,
    DecisionError,
    InvariantError,
    apply_architect_decision,
    apply_review_decision,
    architect_task_arguments,
    builder_task_arguments,
    controller_main,
    initial_state,
    load_state,
    next_action,
    parse_json_output,
    review_task_arguments,
    save_state,
    tick_once,
    validate_state,
)


class FakeBoard:
    def __init__(self) -> None:
        self.tasks: dict[str, dict] = {}
        self.created: list[list[str]] = []
        self.completed: list[str] = []

    def list_tasks(self) -> list[dict]:
        return [entry["task"] for entry in self.tasks.values()]

    def create_task(self, arguments: list[str]) -> dict:
        self.created.append(arguments)
        task_id = f"t_fake_{len(self.created)}"
        assignee = arguments[arguments.index("--assignee") + 1]
        wrapper = {
            "task": {"id": task_id, "status": "ready", "assignee": assignee},
            "runs": [],
            "events": [],
        }
        self.tasks[task_id] = wrapper
        return wrapper["task"]

    def show_task(self, task_id: str) -> dict:
        return self.tasks[task_id]

    def complete_task(self, task_id: str, result: str) -> None:
        self.completed.append(task_id)
        self.tasks[task_id]["task"]["status"] = "done"


class RingBellAutopilotV2Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.state = initial_state()

    def test_scheduler_never_dispatches_while_paused(self) -> None:
        self.assertFalse(should_dispatch(self.state))
        armed = copy.deepcopy(self.state)
        armed.update({"enabled": True, "phase": "needs_architect", "pause_reason": None})
        self.assertTrue(should_dispatch(armed))

    def test_state_round_trip_is_atomic_and_validated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "AUTOPILOT_STATE.json"
            save_state(path, self.state)
            loaded = load_state(path)
            self.assertEqual(loaded, self.state)
            self.assertFalse((Path(directory) / "AUTOPILOT_STATE.tmp").exists())

    def test_kanban_json_parser_tolerates_progress_text(self) -> None:
        payload = {"task": {"id": "t_123", "status": "ready"}}
        raw = "creating task...\n" + json.dumps(payload) + "\ncreated"
        self.assertEqual(parse_json_output(raw), payload)

    def test_paused_cli_tick_does_not_touch_the_board(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "AUTOPILOT_STATE.json"
            save_state(path, self.state)
            board = FakeBoard()
            result = controller_main(
                ["--state", str(path), "tick"],
                board_factory=lambda: board,
                decision_root=Path(directory),
            )
            self.assertEqual(result, 0)
            self.assertEqual(board.created, [])
            self.assertEqual(load_state(path), self.state)

    def test_paused_tick_is_inert(self) -> None:
        board = FakeBoard()
        result, messages = tick_once(copy.deepcopy(self.state), board, decision_loader=lambda _name: {})
        self.assertEqual(result, self.state)
        self.assertEqual(messages, [])
        self.assertEqual(board.created, [])

    def test_repeated_architect_ticks_do_not_duplicate_the_card(self) -> None:
        board = FakeBoard()
        state = copy.deepcopy(self.state)
        state.update({"enabled": True, "phase": "needs_architect", "pause_reason": None})
        first, first_messages = tick_once(state, board, decision_loader=lambda _name: {})
        self.assertEqual(first["phase"], "architecting")
        self.assertEqual(len(board.created), 1)
        self.assertEqual(len(first_messages), 1)

        second, second_messages = tick_once(first, board, decision_loader=lambda _name: {})
        self.assertEqual(second, first)
        self.assertEqual(second_messages, [])
        self.assertEqual(len(board.created), 1)

    def test_builder_handoff_creates_one_nonblocking_review_card(self) -> None:
        board = FakeBoard()
        board.tasks["t_build"] = {
            "task": {"id": "t_build", "status": "review", "assignee": BUILDER_PROFILE},
            "runs": [{"id": 7, "status": "review", "outcome": "review_requested"}],
            "events": [{"kind": "review_requested", "run_id": 7}],
        }
        state = copy.deepcopy(self.state)
        state.update({"enabled": True, "phase": "building", "pause_reason": None})
        state["current"].update(
            {
                "milestone_id": "M001",
                "milestone_title": "Playable slice",
                "spec_path": ".hermes/autopilot/specs/SPEC-C001.md",
                "spec_sha256": "a" * 64,
                "acceptance_criteria": ["A", "B", "C"],
                "required_tests": ["--smoke"],
                "gameplay_value": "Fun",
                "build_task_id": "t_build",
            }
        )
        handoff, _ = tick_once(state, board, decision_loader=lambda _name: {})
        self.assertEqual(handoff["phase"], "awaiting_review")
        self.assertEqual(handoff["current"]["build_handoff_run"], 7)

        reviewing, _ = tick_once(handoff, board, decision_loader=lambda _name: {})
        self.assertEqual(reviewing["phase"], "reviewing")
        self.assertEqual(len(board.created), 1)
        self.assertNotIn("--parent", board.created[0])

    def test_initial_state_is_paused_and_dispatches_nothing(self) -> None:
        validate_state(self.state)
        self.assertFalse(self.state["enabled"])
        self.assertEqual(self.state["phase"], "paused")
        self.assertEqual(next_action(self.state, []), {"kind": "none", "reason": "paused"})

    def test_roles_are_pinned_to_luna_max_on_fresh_board(self) -> None:
        self.assertEqual(BOARD, "ring-bell-v2")
        self.assertEqual(ARCHITECT_PROFILE, "lunaringbell")
        self.assertEqual(BUILDER_PROFILE, "museringbell")
        self.assertEqual(MODEL, "gpt-5.6-luna")
        self.assertEqual(PROVIDER, "openai-codex")
        self.assertEqual(REASONING_EFFORT, "max")

    def test_architect_decision_authorizes_one_bounded_builder_spec(self) -> None:
        state = copy.deepcopy(self.state)
        state.update({"enabled": True, "phase": "architecting"})
        state["current"]["architect_task_id"] = "t_arch"
        decision = {
            "decision": "authorize_build",
            "cycle": 1,
            "milestone_id": "M001-PLAYABLE-HILLS",
            "milestone_title": "Playable hills beyond Prague",
            "gameplay_value": "Creates a readable exploration destination and traversal challenge.",
            "spec_path": ".hermes/autopilot/specs/SPEC-C001.md",
            "spec_sha256": "e" * 64,
            "acceptance_criteria": [
                "The player can reach the hills with ordinary movement.",
                "The terrain is readable and collision-safe.",
                "Existing city play remains intact.",
            ],
            "required_tests": ["--import", "--terrainmaterialtest", "--smoke"],
        }
        result = apply_architect_decision(state, decision)
        self.assertEqual(result["phase"], "ready_to_build")
        self.assertEqual(result["current"]["milestone_id"], "M001-PLAYABLE-HILLS")
        self.assertEqual(result["current"]["spec_path"], decision["spec_path"])
        self.assertEqual(result["current"]["spec_sha256"], decision["spec_sha256"])
        self.assertEqual(len(result["current"]["acceptance_criteria"]), 3)

    def test_architect_card_owns_design_but_not_production(self) -> None:
        state = copy.deepcopy(self.state)
        state.update({"enabled": True, "phase": "needs_architect"})
        args = architect_task_arguments(state)
        body = args[args.index("--body") + 1]
        self.assertIn("maximize sustained player enjoyment", body.lower())
        self.assertIn("must not edit production code", body.lower())
        self.assertIn("GRAND_PLAN.md", body)
        self.assertIn("--model", args)
        self.assertEqual(args[args.index("--model") + 1], MODEL)
        self.assertEqual(args[args.index("--provider") + 1], PROVIDER)
        self.assertIn("--idempotency-key", args)

    def test_builder_card_can_only_implement_the_architect_spec(self) -> None:
        state = copy.deepcopy(self.state)
        state.update({"enabled": True, "phase": "ready_to_build"})
        state["current"].update(
            {
                "cycle": 3,
                "revision_round": 0,
                "milestone_id": "M003-SURVIVAL-LOOP",
                "milestone_title": "First survival loop",
                "spec_path": ".hermes/autopilot/specs/SPEC-C003.md",
                "spec_sha256": "f" * 64,
                "acceptance_criteria": ["Playable", "Stable", "Enjoyable"],
                "required_tests": ["--import", "--smoke"],
            }
        )
        args = builder_task_arguments(state)
        body = args[args.index("--body") + 1]
        self.assertIn("SPEC-C003.md", body)
        self.assertIn("f" * 64, body)
        self.assertIn("Do not select roadmap work", body)
        self.assertIn("request review", body.lower())
        self.assertNotIn("--parent", args)
        self.assertEqual(args[args.index("--assignee") + 1], BUILDER_PROFILE)
        self.assertEqual(args[args.index("--model") + 1], MODEL)
        self.assertEqual(args[args.index("--provider") + 1], PROVIDER)

    def test_review_task_is_nonblocking_and_has_no_parent_dependency(self) -> None:
        state = copy.deepcopy(self.state)
        state.update({"enabled": True, "phase": "awaiting_review"})
        state["current"].update(
            {
                "cycle": 4,
                "revision_round": 1,
                "milestone_id": "M004",
                "build_task_id": "t_build",
                "build_handoff_run": 9,
            }
        )
        args = review_task_arguments(state)
        self.assertNotIn("--parent", args)
        body = args[args.index("--body") + 1]
        self.assertIn("review_of_task: t_build", body)
        self.assertIn("review_of_run: 9", body)
        self.assertIn("nonblocking_review_link: true", body)

    def test_two_active_writers_fail_closed(self) -> None:
        state = copy.deepcopy(self.state)
        state.update({"enabled": True, "phase": "needs_architect"})
        tasks = [
            {"id": "t_a", "status": "running", "assignee": ARCHITECT_PROFILE},
            {"id": "t_b", "status": "ready", "assignee": BUILDER_PROFILE},
        ]
        with self.assertRaisesRegex(InvariantError, "multiple active actors"):
            next_action(state, tasks)

    def test_minor_review_findings_are_deferred_and_cycle_continues(self) -> None:
        state = self._reviewing_state(revision_round=0)
        result = apply_review_decision(
            state,
            {
                "verdict": "accept_with_deferred",
                "severity": "minor",
                "summary": "Core construction is sound.",
                "deferred_findings": ["Improve distant terrain material blending."],
            },
        )
        self.assertEqual(result["phase"], "needs_architect")
        self.assertEqual(result["current"]["cycle"], 2)
        self.assertEqual(result["current"]["revision_round"], 0)
        self.assertEqual(len(result["deferred_findings"]), 1)
        self.assertTrue(result["enabled"])

    def test_minor_finding_cannot_force_revision(self) -> None:
        state = self._reviewing_state(revision_round=0)
        with self.assertRaisesRegex(DecisionError, "minor findings must be deferred"):
            apply_review_decision(
                state,
                {
                    "verdict": "revise",
                    "severity": "minor",
                    "summary": "Polish only.",
                    "revision_spec": ".hermes/autopilot/specs/REVISION-C001-R01.md",
                    "revision_spec_sha256": "a" * 64,
                },
            )

    def test_principal_revision_is_allowed_only_below_cap(self) -> None:
        state = self._reviewing_state(revision_round=1)
        result = apply_review_decision(
            state,
            {
                "verdict": "revise",
                "severity": "principal",
                "summary": "Collision ownership conflicts with the approved design.",
                "revision_spec": ".hermes/autopilot/specs/REVISION-C001-R02.md",
                "revision_spec_sha256": "b" * 64,
            },
        )
        self.assertEqual(result["phase"], "revision_ready")
        self.assertEqual(result["current"]["revision_round"], 2)

        capped = self._reviewing_state(revision_round=2)
        with self.assertRaisesRegex(DecisionError, "revision limit reached"):
            apply_review_decision(
                capped,
                {
                    "verdict": "revise",
                    "severity": "principal",
                    "summary": "No third direct rework loop.",
                    "revision_spec": ".hermes/autopilot/specs/REVISION-C001-R03.md",
                    "revision_spec_sha256": "c" * 64,
                },
            )

    def test_acceptance_immediately_continues_to_next_architect_cycle(self) -> None:
        state = self._reviewing_state(revision_round=1)
        result = apply_review_decision(
            state,
            {
                "verdict": "accept",
                "severity": "none",
                "summary": "The milestone follows the design and is principally complete.",
                "deferred_findings": [],
            },
        )
        self.assertEqual(result["phase"], "needs_architect")
        self.assertEqual(result["current"]["cycle"], 2)
        self.assertEqual(result["current"]["revision_round"], 0)
        self.assertTrue(result["enabled"])

    def test_recovery_after_revision_cap_routes_to_architect_not_pause(self) -> None:
        state = self._reviewing_state(revision_round=2)
        result = apply_review_decision(
            state,
            {
                "verdict": "recovery_required",
                "severity": "principal",
                "summary": "A fresh architecture slice is safer than another patch loop.",
                "deferred_findings": ["Design a bounded recovery milestone for terrain ownership."],
            },
        )
        self.assertEqual(result["phase"], "needs_architect")
        self.assertEqual(result["current"]["cycle"], 2)
        self.assertTrue(result["enabled"])
        self.assertNotEqual(result["phase"], "paused")

    def _reviewing_state(self, revision_round: int) -> dict:
        state = copy.deepcopy(self.state)
        state.update({"enabled": True, "phase": "reviewing"})
        state["current"].update(
            {
                "cycle": 1,
                "revision_round": revision_round,
                "milestone_id": "M001",
                "milestone_title": "First enjoyment milestone",
                "spec_path": ".hermes/autopilot/specs/SPEC-C001.md",
                "spec_sha256": "d" * 64,
                "build_task_id": "t_build",
                "review_task_id": "t_review",
            }
        )
        return state


if __name__ == "__main__":
    unittest.main()
