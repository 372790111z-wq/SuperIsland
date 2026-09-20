import copy
import importlib.util
import json
import pathlib
import tempfile
import time
import unittest
from unittest import mock


SERVER_PATH = pathlib.Path(__file__).with_name("server.py")
SPEC = importlib.util.spec_from_file_location("agents_status_server", SERVER_PATH)
server = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(server)


class AgentsStatusServerTests(unittest.TestCase):
    def test_health_identifies_launch_owner_without_reading_sessions(self):
        with mock.patch.object(server, "OWNER_TOKEN", "fixture-owner"), \
             mock.patch.object(server, "_snapshot", side_effect=AssertionError("must not scan sessions")):
            response = server._route_get("/health")
        chunked = response.split(b"\r\n\r\n", 1)[1]
        size, body = chunked.split(b"\r\n", 1)
        payload = json.loads(body[:int(size, 16)])
        self.assertEqual(payload["ownerToken"], "fixture-owner")
        self.assertEqual(payload["port"], server.PORT)

    def test_app_hosted_server_stops_when_parent_is_gone(self):
        listener = mock.Mock()
        with mock.patch.object(server, "PARENT_PID", 42424), \
             mock.patch.object(server.os, "getppid", return_value=1), \
             mock.patch.object(server.socket, "socket", return_value=listener), \
             mock.patch.object(server.sys, "stderr"):
            server.main()
        listener.accept.assert_not_called()
        listener.close.assert_called_once()

    def setUp(self):
        self._sessions = copy.deepcopy(server._sessions)
        self._recently_ended = copy.deepcopy(server._recently_ended_pids)
        server._sessions.clear()
        server._recently_ended_pids.clear()

    def tearDown(self):
        server._sessions.clear()
        server._sessions.update(self._sessions)
        server._recently_ended_pids.clear()
        server._recently_ended_pids.update(self._recently_ended)

    def _session(self, **overrides):
        base = {
            "agent": "Claude",
            "session_id": "session-1",
            "state": "Idle",
            "title": "",
            "cwd": "/tmp",
            "terminal": "Warp",
            "pid": 99999,
            "turn_id": None,
            "turn_active": False,
            "turn_started_at": None,
            "last_event": "Stop",
            "last_assistant_message": None,
            "error_expires_at": None,
            "updated_at": 100.0,
            "synthetic": False,
            "transcript_path": "",
        }
        base.update(overrides)
        return base

    def test_ended_event_removes_claude_session_by_pid(self):
        server._sessions[("Claude", "real-session")] = self._session(
            session_id="real-session",
            pid=42424,
        )

        ok, payload = server._apply_event({
            "state": "Ended",
            "agent": "Claude",
            "session_id": "default",
            "pid": 42424,
        })

        self.assertTrue(ok)
        self.assertTrue(payload["removed"])
        self.assertNotIn(("Claude", "real-session"), server._sessions)
        self.assertTrue(server._pid_recently_ended(42424, time.time()))

    def test_idle_claude_exit_prunes_without_error(self):
        key = ("Claude", "session-1")
        server._sessions[key] = self._session(pid=51515, state="Idle", turn_active=False)

        with mock.patch.object(server, "_pid_alive", return_value=False):
            now = 200.0
            server._mark_unexpected_claude_exits(now)
            self.assertEqual(server._sessions[key]["state"], "Idle")
            server._prune(now, ttl=999.0)

        self.assertNotIn(key, server._sessions)

    def test_codex_interrupt_marker_flips_working_session_idle(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as handle:
            handle.write(
                "<turn_aborted>\n"
                "  <turn_id>turn-123</turn_id>\n"
                "  <reason>interrupted</reason>\n"
                "</turn_aborted>\n"
            )
            transcript_path = handle.name

        key = ("Codex", "session-1")
        server._sessions[key] = self._session(
            agent="Codex",
            state="Working",
            pid=61616,
            turn_id="turn-123",
            turn_active=True,
            transcript_path=transcript_path,
        )

        try:
            server._decay_working(300.0)
        finally:
            pathlib.Path(transcript_path).unlink(missing_ok=True)

        self.assertEqual(server._sessions[key]["state"], "Idle")
        self.assertFalse(server._sessions[key]["turn_active"])
        self.assertIsNone(server._sessions[key]["turn_started_at"])


if __name__ == "__main__":
    unittest.main()
