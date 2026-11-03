#!/usr/bin/env python3
"""Read-only cycle adjudication and reviewable wake plans; never controls power."""
import argparse
import datetime as dt
import json
import math
from pathlib import Path
import re
import uuid

TERMINALS = {"completed", "cancelled", "failed", "ended"}


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def identity(row):
    return row["source"], row["sessionHash"], row.get("taskHash", "legacy")


def system_events(lines):
    """A future Wake Requests line is deliberately not an actual Wake."""
    output = []
    pattern = r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) ([+-]\d{4}) (DarkWake|Wake|Sleep)\s+(.+)$"
    for line in lines:
        match = re.match(pattern, line)
        if not match:
            continue
        date, zone, kind, reason = match.groups()
        prefix = {"Sleep": "Entering Sleep state", "Wake": "Wake from", "DarkWake": "DarkWake from"}[kind]
        if not reason.startswith(prefix):
            continue
        when = dt.datetime.strptime(date + " " + zone, "%Y-%m-%d %H:%M:%S %z").timestamp()
        output.append({"epoch": when, "kind": kind, "reason": reason,
                       "manual": bool(re.search(r"\blid\b|\bpwrbtn\b|UserActivity|RTP\.multi-touch", reason, re.I))})
    return sorted(output, key=lambda row: row["epoch"])


def sleep_proofs(samples):
    output, pairs = [], set()
    for sample in samples:
        slept, woke = sample.get("kernelSleepTime"), sample.get("kernelWakeTime")
        if all(finite(v) for v in (slept, woke)) and 0 < slept < woke <= sample["epoch"]:
            pair = slept, woke
            if pair not in pairs:
                pairs.add(pair)
                output.append({"start": slept, "end": woke, "seconds": woke - slept, "evidence": "kernel-pair"})
    for before, after in zip(samples, samples[1:]):
        values = [before.get("continuous"), after.get("continuous"), before.get("awake"), after.get("awake")]
        if not all(finite(v) for v in values):
            continue
        elapsed, awake = values[1] - values[0], values[3] - values[2]
        if elapsed >= 0 and awake >= 0 and elapsed - awake > 0.01:
            output.append({"start": before["epoch"], "end": after["epoch"],
                           "seconds": elapsed - awake, "evidence": "continuous-minus-awake"})
    return output


def analyze(native, system, recap, pid, build):
    if native.get("pid") != pid or native.get("build") != build:
        raise ValueError("Native PID/build does not match the expected installation")
    rows = native["rows"]
    if any(not finite(row.get("epoch")) for row in rows):
        raise ValueError("Missing or invalid event timestamp")
    samples = sorted((r for r in rows if r["event"] == "power-sample"), key=lambda r: r["epoch"])
    if not samples:
        raise ValueError("No power evidence")
    start, end = native["start"], native["firstOpen"]["epoch"]
    if not all(finite(v) for v in (start, end)) or start >= end:
        raise ValueError("Invalid cycle bounds")
    samples = [s for s in samples if start <= s["epoch"] <= end]
    if any(not all(finite(s.get(k)) for k in ("continuous", "awake")) for s in samples) or any(
        b[k] < a[k] for a, b in zip(samples, samples[1:]) for k in ("continuous", "awake")):
        raise ValueError("Invalid or regressing power clocks")
    rows = sorted((r for r in rows if start <= r["epoch"] <= end), key=lambda r: r["epoch"])
    events = [e for e in system_events(system["lines"]) if start - 1 <= e["epoch"] <= end + 1]
    proofs = [p for p in sleep_proofs(samples) if p["end"] >= start and p["start"] <= end]
    held = [s for s in samples if s.get("actualHold") is True and s.get("lidClosed") is True]
    held_span = held[-1]["continuous"] - held[0]["continuous"] if len(held) > 1 else 0
    hold_gap = max((b["continuous"] - a["continuous"] for a, b in zip(held, held[1:])), default=0)
    hold_ok = held_span >= 120 and hold_gap <= 5 and all(
        s.get("actualHold") is True and s.get("sleepDisabled") is True and s.get("lidApplied") is True
        and type(s.get("externalDisplays")) is int and s["externalDisplays"] == 0
        and s.get("lidClosed") is True
        for s in samples if held and held[0]["epoch"] <= s["epoch"] <= held[-1]["epoch"])
    hold_slept = any(p["seconds"] > 0.01 and held and p["start"] >= held[0]["epoch"]
                     and p["end"] <= held[-1]["epoch"] for p in proofs)
    task_events = [r for r in rows if r["event"] == "accepted-task-event"]
    running = [r["epoch"] for r in task_events if r.get("state") == "running" and held
               and held[0]["epoch"] <= r["epoch"] <= held[-1]["epoch"]]
    task_span = max(running) - min(running) if running else 0
    cycle = recap.get("latest", recap)
    bounds_match = all(finite(v) for v in (cycle.get("start", {}).get("wall"), cycle.get("end", {}).get("wall"))) and (
        abs(cycle["start"]["wall"] - start) <= 3 and abs(cycle["end"]["wall"] - end) <= 3)
    release, tasks, terminals = None, set(), []
    for candidate in samples:
        if not (type(candidate.get("unfinishedCount")) is int and candidate["unfinishedCount"] == 0
                and candidate.get("actualHold") is False
                and candidate.get("sleepDisabled") is False and candidate.get("lidReleaseConfirmed") is True
                and candidate.get("lidClosed") is True):
            continue
        # Work starting after this release must not erase evidence of an earlier
        # valid release, nor may its later terminal retroactively justify it.
        prior = [s for s in samples if s["epoch"] <= candidate["epoch"]]
        if any(s.get("pendingTruncated") is True or type(s.get("unfinishedCount")) is not int
               or s["unfinishedCount"] != len(s.get("pending", [])) for s in prior):
            continue
        admitted = {identity(t) for s in prior for t in s.get("pending", [])}
        matched = []
        for task in admitted:
            last_pending = max(s["epoch"] for s in prior if task in {identity(t) for t in s.get("pending", [])})
            matches = [e for e in task_events if identity(e) == task and e.get("state") in TERMINALS
                       and last_pending <= e["epoch"] <= candidate["epoch"]]
            if matches:
                matched.append(min(e["epoch"] for e in matches))
        released_at = cycle.get("releasedAt")
        if (admitted and any(s["epoch"] < candidate["epoch"] for s in held)
                and len(matched) == len(admitted) and finite(released_at)
                and candidate["epoch"] - 5 <= released_at <= candidate["epoch"]
                and released_at - max(matched) >= 29.9):
            release, tasks, terminals = candidate, admitted, matched
            break
    natural = bool(held and release and bounds_match and cycle.get("hadHold") is True
                   and cycle.get("releaseReason") == "tasksEnded")
    requests = [r for r in rows if r["event"] == "completion-sleep-request"]

    def valid_call(call):
        prior = next((s for s in reversed(samples) if s["epoch"] <= call["epoch"]), None)
        return bool(prior and call["epoch"] - prior["epoch"] <= 5
                    and prior.get("lidClosed") is True and type(prior.get("externalDisplays")) is int
                    and prior["externalDisplays"] == 0 and type(prior.get("unfinishedCount")) is int
                    and prior["unfinishedCount"] == 0 and call.get("ownAssertionsReleased") is True
                    and call.get("cpuSleepBlocked") is False)

    def actual(sleep):
        wake = next((e for e in events if e["kind"] != "Sleep" and e["epoch"] > sleep["epoch"]), None)
        return bool(wake and any(sleep["epoch"] - (30 if p["evidence"] == "kernel-pair" else 5)
                                 <= p["start"] <= sleep["epoch"] + 30
                                 and p["end"] >= wake["epoch"] - 2
                                 and p["end"] <= wake["epoch"] + 5 for p in proofs))

    def our_sleep(event):
        return bool(re.search(r"Software Sleep pid=" + str(pid) + r"(?!\d)", event["reason"]))

    initial = next((e for e in events if e["kind"] == "Sleep"
                    and our_sleep(e) and natural
                    and any(release["epoch"] - 3 <= r["epoch"] <= e["epoch"]
                            and e["epoch"] - r["epoch"] <= 30 and valid_call(r) for r in requests)
                    and actual(e)), None)
    retries = []
    for wake in events:
        if not initial or wake["kind"] == "Sleep" or wake["manual"] or wake["epoch"] <= initial["epoch"]:
            continue
        before = next((s for s in reversed(samples) if s["epoch"] <= wake["epoch"]), None)
        after = next((s for s in samples if s["epoch"] >= wake["epoch"]), None)
        if not before or not after or any(s.get("lidClosed") is not True or s.get("externalDisplays") != 0 for s in (before, after)):
            continue
        episode_end = next((e["epoch"] for e in events if e["kind"] != "Sleep"
                            and e["epoch"] > wake["epoch"]), end)
        later = next((e for e in events if e["kind"] == "Sleep"
                      and wake["epoch"] < e["epoch"] < episode_end and actual(e)), None)
        calls = [r for r in requests if wake["epoch"] < r["epoch"] < (later["epoch"] if later else episode_end)]

        def fresh_retry(call):
            markers = [r for r in rows if r["event"] in (
                "completion-sleep-wake-recheck", "completion-sleep-kernel-wake-recheck")
                and wake["epoch"] <= r["epoch"] < call["epoch"]]
            return bool(markers and all(r.get("delaySeconds") in (30, 60) for r in markers)
                        and call["epoch"] >= max(r["epoch"] + r["delaySeconds"] for r in markers))

        if after.get("unfinishedCount") != 0:
            verdict = "new-work; no completion-sleep acceptance"
        elif later and calls and all(valid_call(c) and fresh_retry(c) for c in calls) and our_sleep(later) \
                and later["epoch"] - calls[-1]["epoch"] <= 30:
            verdict = "app-request-and-actual-resleep"
        elif later and not calls:
            verdict = "system-returned-to-sleep; app-retry-not-exercised"
        elif later:
            verdict = "reslept; app-causal-attribution-unproved"
        elif after.get("cpuSleepBlocked") is not False:
            verdict = "cpu-blocked-or-unknown; no forced sleep"
        else:
            verdict = "insufficient-evidence-of-resleep"
        retries.append({"wake": wake, "verdict": verdict, "requestCountBeforeResleep": len(calls)})
    return {"hold": "passed" if hold_ok and not hold_slept and task_span >= 120 else "not-proved",
            "runningEventSpanSeconds": task_span,
            "naturalRelease": "passed" if natural else "not-proved", "coveredTasks": len(tasks),
            "terminalTasks": len(terminals), "firstActualSleep": "passed" if initial else "not-proved",
            "backgroundWakes": retries, "backgroundRetry": "passed" if any(
                r["verdict"] == "app-request-and-actual-resleep" for r in retries) else "not-covered-or-not-proved",
            "requestCount": len(requests), "scheduledWakeIsNotProof": True}


def prepare_wake(start, wake, end, now, system_offset=28800):
    """Return exact, reviewable commands only. No subprocess or privilege calls."""
    if not all(finite(v) for v in (start, wake, end, now)):
        raise ValueError("Invalid clock")
    if system_offset != 28800:
        raise ValueError("System timezone must match the Asia/Shanghai plan")
    if not (now <= start <= now + 120 and start + 180 <= wake <= end - 180 and end - start <= 900):
        raise ValueError("Wake must fit a future <=900s recording window with guard margins")
    when = dt.datetime.fromtimestamp(wake, dt.timezone(dt.timedelta(hours=8))).strftime("%m/%d/%y %H:%M:%S")
    owner = "com.workview.SuperIsland.Acceptance." + str(uuid.uuid4()).upper()
    return {"scheduled": False, "preparedAt": now, "recordingStart": start, "recordingEnd": end,
            "wakeEpoch": wake, "wakeType": "wake", "owner": owner,
            "timezone": "Asia/Shanghai", "schedule": ["/usr/bin/sudo", "/usr/bin/pmset", "schedule", "wake", when, owner],
            "exactRollback": ["/usr/bin/sudo", "/usr/bin/pmset", "schedule", "cancel", "wake", when, owner],
            "requiresUserApprovalAndAdministratorAuthentication": True,
            "mustRecheckBeforeScheduling": ["lid open", "AC", "external displays 0", "no other unfinished work",
                "same app PID/build", "no protection or AlDente conflict", "record existing schedules"],
            "notGuaranteedDarkWake": True, "relativeAndCancelAllNeverUsed": True}


def load(path):
    p = Path(path)
    if p.stat().st_size > 2_097_152:
        raise ValueError("Evidence file exceeds bounded input size")
    return json.loads(p.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("analyze")
    for option in ("native", "system", "recap", "build"):
        check.add_argument("--" + option, required=True)
    check.add_argument("--pid", required=True, type=int)
    plan = commands.add_parser("prepare-wake")
    for name in ("start", "wake", "end", "now"):
        plan.add_argument("--" + name, required=True, type=float)
    args = parser.parse_args()
    if args.command == "analyze":
        output = analyze(load(args.native), load(args.system), load(args.recap), args.pid, args.build)
    else:
        output = prepare_wake(args.start, args.wake, args.end, args.now,
                              dt.datetime.now().astimezone().utcoffset().total_seconds())
    print(json.dumps(output, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
