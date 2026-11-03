# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""State-machine tests for zoom_guard: uv run --script test_zoom_guard.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zoom_guard as g  # noqa: E402

H = 3600
CLEAN = {"Result": "success", "ExecMainCode": "exited", "ExecMainStatus": "0"}
SEGV = {"Result": "signal", "ExecMainCode": "killed", "ExecMainStatus": "SEGV"}
DUMP = {"Result": "core-dump", "ExecMainCode": "dumped", "ExecMainStatus": "ABRT"}
ERR = {"Result": "exit-code", "ExecMainCode": "exited", "ExecMainStatus": "1"}
TERM = {"Result": "signal", "ExecMainCode": "killed", "ExecMainStatus": "TERM"}


def run(state, now, why, lived=g.GOOD_S):
    rank, _ = g.decide(state, now)
    return g.record(state, rank, why, now, lived)


def test_quick_relaunches_never_demote():
    s = g.empty()
    for i in range(5):
        s, a = run(s, 1000 + i * 10, g.classify(CLEAN, 5), lived=5)
        assert a == "ok", a
    assert s["rank"] == 0


def test_two_early_failures_in_window_demote():
    s, a = run(g.empty(), 1000, g.classify(ERR, 10), lived=10)
    assert a == "counted"
    s, a = run(s, 1300, g.classify(DUMP, 10), lived=10)
    assert a == "demoted" and s["rank"] == 1 and s["pinned_until"] == 1300 + g.PIN_S


def test_failures_far_apart_do_not_demote():
    s, _ = run(g.empty(), 1000, "early-exit", lived=10)
    s, a = run(s, 1000 + g.WINDOW_S + 1, "early-exit", lived=10)
    assert a == "counted" and s["rank"] == 0


def test_long_lived_segv_still_counts_but_alone_does_not_demote():
    why = g.classify(SEGV, 3 * H)
    assert why == "crash"
    s, a = run(g.empty(), 1000, why, lived=3 * H)
    assert a == "counted" and s["rank"] == 0


def test_long_lived_error_exit_is_not_a_failure():
    assert g.classify(ERR, 3 * H) is None


def test_user_quit_is_clean():
    assert g.classify(CLEAN, 2) is None
    assert g.classify(TERM, 2) is None


def test_restart_is_failure():
    assert g.classify({**CLEAN, "NRestarts": "1"}, 500) == "restart"


def test_llvmpipe_demotes_at_once():
    s, a = run(g.empty(), 1000, "llvmpipe", lived=60)
    assert a == "demoted" and s["rank"] == 1


def test_pin_then_probe_then_promote():
    s, _ = run(g.empty(), 1000, "llvmpipe")
    assert g.decide(s, 1000 + H) == (1, False)
    assert g.decide(s, 1000 + g.PIN_S) == (0, True)
    s, a = run(s, 1000 + g.PIN_S, None, lived=g.GOOD_S)
    assert a == "promoted" and s["rank"] == 0 and s["pinned_until"] == 0


def test_failed_probe_repins():
    s, _ = run(g.empty(), 1000, "llvmpipe")
    t = 1000 + g.PIN_S
    s, a = run(s, t, "llvmpipe")
    assert a == "demoted" and s["rank"] == 1 and s["pinned_until"] == t + g.PIN_S


def test_floor_only_notifies():
    s = {**g.empty(), "rank": g.FLOOR, "pinned_until": 10**12}
    s, _ = run(s, 1000, "crash", lived=10)
    s, a = run(s, 1100, "crash", lived=10)
    assert a == "floor" and s["rank"] == g.FLOOR


def test_floor_llvmpipe_is_expected_not_checked():
    assert not g.PROFILES[g.FLOOR]["gpu"]


def test_bad_state_resets():
    assert g.valid(None) == g.empty()
    assert g.valid({"v": 99, "rank": 1}) == g.empty()
    assert g.valid({"v": 1, "rank": 7})["rank"] == 0


def test_pruning():
    s, _ = run(g.empty(), 1000, "early-exit", lived=10)
    s, _ = run(s, 1000 + g.PRUNE_S + 1, None, lived=5)
    assert s["failures"] == []


def test_step_down_and_floor():
    s, a = g.step_down(g.empty(), 1000)
    assert a == "demoted" and s["rank"] == 1
    s, a = g.step_down(s, 1001)
    assert a == "floor" and s["rank"] == g.FLOOR


def test_good_run_clears_rank_failures():
    s, _ = run(g.empty(), 1000, "early-exit", lived=10)
    s, a = run(s, 1100, None, lived=g.GOOD_S)
    assert a == "ok" and s["failures"] == [] and s["good_at"] == 1100


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"{len(tests)} passed")
