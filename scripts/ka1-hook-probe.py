#!/usr/bin/python3
"""Temporary local acceptance probe: metadata only, never task content or IDs."""
import json
import ctypes
import plistlib
import os
import re
import subprocess
import sys
import time
from pathlib import Path

EVENTS = {"SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure"}
try:
    if (Path(sys.argv[1]) / ".disabled").exists():
        sys.exit(0)
    raw = sys.stdin.buffer.read(2097153)
    if len(raw) > 2097152:
        raise ValueError("oversize")
    value = json.loads(raw)
    event = value.get("hook_event_name")
    if event not in EVENTS:
        raise ValueError("unknown event")
    ancestors = []
    pid = os.getppid()
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    for _ in range(16):
        path_buffer = ctypes.create_string_buffer(4096)
        count = libproc.proc_pidpath(pid, path_buffer, len(path_buffer))
        executable = path_buffer.value.decode(errors='replace') if count > 0 else ''
        app = re.search(r"/([^/]+\.app)/Contents/", executable)
        bundle_id = None
        if '.app/Contents/' in executable:
            root = executable.split('.app/Contents/', 1)[0] + '.app'
            try:
                with open(root + '/Contents/Info.plist', 'rb') as stream:
                    candidate = plistlib.load(stream).get('CFBundleIdentifier')
                if candidate in ['com.qodercn.app', 'com.tencent.workbuddy.mac', 'dev.zcode.app']:
                    bundle_id = candidate
            except Exception:
                pass
        ancestors.append({"app": app.group(1) if app else None, "recognized_bundle": bundle_id})
        try:
            pid = int(subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "ppid="], timeout=0.2, text=True).strip())
        except Exception:
            break
        if pid <= 1:
            break
    output = {"time": time.time(), "event": event, "has_session": isinstance(value.get("session_id"), str),
              "fields": sorted(k for k in value if isinstance(k, str) and re.fullmatch(r"[a-zA-Z_]{1,60}", k)),
              "tool": value.get("tool_name") if value.get("tool_name") in ["Bash", "AskUserQuestion", "ask_user_question"] else "other",
              "notification_type": value.get("notification_type") if value.get("notification_type") in ["permission_prompt", "elicitation_dialog", "idle_prompt", "task_started", "task_completed", "agent_needs_input", "agent_completed", "auth_success"] else None,
              "ancestors": ancestors}
    destination = Path(sys.argv[1])
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    if len(list(destination.glob("*.json"))) < 100:
        file = destination / (str(time.time_ns()) + ".json")
        fd = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(output, stream)
except Exception:
    pass
# A probe is observational: no approve/deny, stdout context, or failing exit.
