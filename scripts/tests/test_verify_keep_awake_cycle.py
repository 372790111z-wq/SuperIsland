import datetime as dt
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("cycle", Path(__file__).parents[1] / "verify-keep-awake-cycle.py")
cycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cycle)
BASE = dt.datetime(2026, 11, 2, 17, tzinfo=dt.timezone(dt.timedelta(hours=8))).timestamp()
TASK = dict(source="codex-desktop", sessionHash="a" * 64, taskHash="b" * 64, state="running")


def fixture(background=False):
    end = 340 if background else 240
    asleep = [(160, 200), (266, 340)] if background else [(160, 240)]
    times = list(range(0, 154, 3)) + ([156, 200, 203, 230, 260, 263, 266, 340] if background else [156, 240])
    rows = []
    for t in times:
        hold = t < 153
        slept = sum(max(0, min(t, b) - a) for a, b in asleep)
        rows.append(dict(event="power-sample", epoch=BASE+t, continuous=t, awake=t-slept,
                         actualHold=hold, sleepDisabled=hold, lidApplied=hold, lidReleaseConfirmed=not hold,
                         lidClosed=t<end, externalDisplays=0, cpuSleepBlocked=False,
                         unfinishedCount=int(t<=120), pending=[TASK] if t<=120 else []))
    rows += [dict(TASK, event="accepted-task-event", epoch=BASE),
             dict(TASK, event="accepted-task-event", epoch=BASE+120),
             dict(TASK, event="accepted-task-event", epoch=BASE+121, state="completed"),
             dict(event="completion-sleep-request", epoch=BASE+154, ownAssertionsReleased=True, cpuSleepBlocked=False),
             dict(event="completion-sleep-accepted", epoch=BASE+154.1)]
    if background:
        rows += [dict(event="completion-sleep-kernel-wake-recheck", epoch=BASE+200, delaySeconds=60),
                 dict(event="completion-sleep-request", epoch=BASE+261, ownAssertionsReleased=True, cpuSleepBlocked=False)]
    def line(t, kind, text):
        date = dt.datetime.fromtimestamp(BASE+t, dt.timezone(dt.timedelta(hours=8))).strftime("%Y-%m-%d %H:%M:%S")
        return f"{date} +0800 {kind:<20}\t{text}"
    lines = [line(156, "Sleep", "Entering Sleep state due to 'Software Sleep pid=42'")]
    if background:
        lines += [line(200, "DarkWake", "DarkWake from Deep Idle due to RTC/Maintenance"),
                  line(264, "Sleep", "Entering Sleep state due to 'Software Sleep pid=42'")]
    lines += [line(end, "Wake", "Wake from Deep Idle due to lid/UserActivity")]
    native = dict(pid=42, build="test", start=BASE, firstOpen={"epoch": BASE+end}, rows=rows)
    recap = dict(releaseReason="tasksEnded", hadHold=True, releasedAt=BASE+153,
                 start={"wall":BASE}, end={"wall":BASE+end})
    return native, {"lines":lines}, recap


class CycleEvidenceTests(unittest.TestCase):
    def run_case(self, data):
        return cycle.analyze(*data, 42, "test")

    def test_first_sleep_and_manual_open_do_not_cover_background_retry(self):
        result = self.run_case(fixture())
        self.assertEqual(result["hold"], "passed")
        self.assertEqual(result["naturalRelease"], "passed")
        self.assertEqual(result["firstActualSleep"], "passed")
        self.assertEqual(result["backgroundWakes"], [])
        self.assertNotEqual(result["backgroundRetry"], "passed")

    def test_actual_background_wake_request_and_real_resleep(self):
        result = self.run_case(fixture(True))
        self.assertEqual(result["backgroundRetry"], "passed")
        self.assertEqual(len(result["backgroundWakes"]), 1)

    def test_future_wake_requests_never_count_as_actual_wakes(self):
        data = fixture()
        data[1]["lines"].append("2026-11-02 17:03:00 +0800 Wake Requests       [process=powerd wakeAt=2026-11-02 18:00:00]")
        self.assertEqual(self.run_case(data)["backgroundWakes"], [])

    def test_accepted_api_without_sleep_cannot_pass(self):
        data = fixture()
        data[1]["lines"] = []
        self.assertNotEqual(self.run_case(data)["firstActualSleep"], "passed")

    def test_sleep_entry_without_clock_or_kernel_sleep_proof_cannot_pass(self):
        data = fixture()
        for sample in data[0]["rows"]:
            if sample["event"] == "power-sample":
                sample["awake"] = sample["continuous"]
        self.assertNotEqual(self.run_case(data)["firstActualSleep"], "passed")

    def test_pid_and_build_mismatch_rejected(self):
        for field, value in [("pid",43), ("build","old")]:
            data = fixture()
            data[0][field] = value
            with self.assertRaises(ValueError):
                self.run_case(data)

    def test_disappearance_without_terminal_and_wrong_identity_do_not_pass(self):
        for mode in ["missing", "other-task"]:
            data = fixture()
            for event in data[0]["rows"]:
                if event["event"] == "accepted-task-event":
                    event["state"] = "idle" if mode == "missing" else "completed"
                    if mode == "other-task":
                        event["taskHash"] = "c"*64
            self.assertNotEqual(self.run_case(data)["naturalRelease"], "passed")

    def test_manual_release_or_an_old_recap_does_not_pass(self):
        for mode in ["manual", "old-cycle"]:
            data = fixture()
            if mode == "manual":
                data[2]["releaseReason"] = "manual"
            else:
                data[2]["start"]["wall"] -= 3600
            self.assertNotEqual(self.run_case(data)["naturalRelease"], "passed")

    def test_one_dropped_hold_sample_external_or_unknown_is_not_continuous_hold(self):
        for field,value in [("actualHold",False),("externalDisplays",1),("externalDisplays",None),("externalDisplays",False)]:
            data = fixture()
            data[0]["rows"][20][field] = value
            self.assertNotEqual(self.run_case(data)["hold"], "passed")

    def test_system_resleep_without_our_retry_does_not_exercise_our_retry(self):
        data = fixture(True)
        data[0]["rows"] = [r for r in data[0]["rows"] if r["event"] != "completion-sleep-request" or r["epoch"] < BASE+200]
        data[1]["lines"][2] = data[1]["lines"][2].replace("Software Sleep pid=42", "Maintenance Sleep")
        result = self.run_case(data)
        self.assertIn("system-returned-to-sleep", result["backgroundWakes"][0]["verdict"])
        self.assertNotEqual(result["backgroundRetry"], "passed")

    def test_retry_with_unreleased_assertions_or_unknown_cpu_does_not_pass(self):
        for field,value in [("ownAssertionsReleased",False),("cpuSleepBlocked",None),("cpuSleepBlocked",True)]:
            data = fixture(True)
            next(r for r in data[0]["rows"] if r["event"]=="completion-sleep-request" and r["epoch"]>BASE+200)[field] = value
            self.assertNotEqual(self.run_case(data)["backgroundRetry"], "passed")

    def test_new_work_after_wake_does_not_pass_completion_resleep(self):
        data = fixture(True)
        sample = next(r for r in data[0]["rows"] if r["event"]=="power-sample" and r["epoch"]==BASE+200)
        sample["unfinishedCount"] = 1
        sample["pending"] = [dict(TASK, taskHash="c"*64)]
        result = self.run_case(data)
        self.assertEqual(result["firstActualSleep"], "passed")
        self.assertNotEqual(result["backgroundRetry"], "passed")
        self.assertIn("new-work",result["backgroundWakes"][0]["verdict"])

    def test_truncated_or_inconsistent_task_coverage_cannot_prove_release(self):
        for field,value in [("pendingTruncated",True),("unfinishedCount",64)]:
            data=fixture();data[0]["rows"][10][field]=value
            self.assertNotEqual(self.run_case(data)["naturalRelease"],"passed")

    def test_pid_prefix_is_not_process_identity(self):
        data=fixture();data[1]["lines"][0]=data[1]["lines"][0].replace("pid=42'","pid=420'")
        self.assertNotEqual(self.run_case(data)["firstActualSleep"],"passed")

    def test_regressing_clock_rejected(self):
        data=fixture();data[0]["rows"][20]["continuous"]=-1
        with self.assertRaises(ValueError):self.run_case(data)

    def test_missing_recheck_or_unelapsed_wake_grace_cannot_pass_retry(self):
        for mode in ["missing", "too-soon"]:
            data=fixture(True)
            if mode=="missing":
                data[0]["rows"]=[r for r in data[0]["rows"] if r["event"]!="completion-sleep-kernel-wake-recheck"]
            else:
                next(r for r in data[0]["rows"] if r["event"]=="completion-sleep-kernel-wake-recheck")["epoch"]=BASE+250
            self.assertNotEqual(self.run_case(data)["backgroundRetry"],"passed")

    def test_malformed_external_count_cannot_pass_retry(self):
        data=fixture(True)
        next(r for r in data[0]["rows"] if r["event"]=="power-sample" and r["epoch"]==BASE+260)["externalDisplays"]=False
        self.assertNotEqual(self.run_case(data)["backgroundRetry"],"passed")

    def test_nan_timestamp_rejected(self):
        data = fixture();data[0]["rows"][0]["epoch"] = float("nan")
        with self.assertRaises(ValueError):self.run_case(data)

    def test_boolean_task_count_cannot_prove_release(self):
        data=fixture()
        for r in data[0]["rows"]:
            if r["event"]=="power-sample" and r["unfinishedCount"]==0:r["unfinishedCount"]=False
        self.assertNotEqual(self.run_case(data)["naturalRelease"],"passed")

    def test_hold_without_running_events_across_interval_is_unproved(self):
        data=fixture()
        data[0]["rows"]=[r for r in data[0]["rows"] if r.get("state")!="running"]
        self.assertNotEqual(self.run_case(data)["hold"],"passed")

    def test_unrelated_earlier_clock_gap_cannot_prove_later_sleep(self):
        data=fixture()
        data[0]["rows"]=[r for r in data[0]["rows"] if r["event"]!="power-sample" or r["epoch"]<BASE+100 or r["epoch"]==BASE+240]
        self.assertNotEqual(self.run_case(data)["firstActualSleep"],"passed")

    def test_stale_request_cannot_establish_app_causality(self):
        data=fixture(True)
        data[1]["lines"][2]=data[1]["lines"][2].replace("17:04:24", "17:05:10")
        self.assertNotEqual(self.run_case(data)["backgroundRetry"],"passed")

    def test_later_wake_episode_cannot_be_attributed_to_earlier_wake(self):
        data=fixture(True)
        data[1]["lines"].insert(2,"2026-11-02 17:04:10 +0800 Wake Wake from Deep Idle due to RTC/Maintenance")
        result=self.run_case(data)
        self.assertNotEqual(result["backgroundWakes"][0]["verdict"],"app-request-and-actual-resleep")


class WakePlanTests(unittest.TestCase):
    def test_plan_does_not_execute_and_rollback_matches_only_owned_event(self):
        plan = cycle.prepare_wake(1000,1420,1900,1000)
        self.assertIs(plan["scheduled"], False)
        self.assertTrue(plan["requiresUserApprovalAndAdministratorAuthentication"])
        self.assertEqual(plan["schedule"][-3:], plan["exactRollback"][-3:])
        self.assertEqual(plan["schedule"][3:], plan["exactRollback"][4:])
        self.assertNotIn("cancelall", plan["exactRollback"])
        self.assertNotIn("relative", plan["schedule"])
        self.assertTrue(plan["notGuaranteedDarkWake"])

    def test_expired_unbounded_or_inadequate_window_and_timezone_rejected(self):
        for args in [(900,1420,1800,1000),(1000,1100,1900,1000),(1000,1800,1900,1000),
                     (1000,1420,2000,1000),(float("nan"),1420,1900,1000)]:
            with self.assertRaises(ValueError):cycle.prepare_wake(*args)
        with self.assertRaises(ValueError):cycle.prepare_wake(1000,1420,1900,1000,0)


if __name__ == "__main__":
    unittest.main()
