// SuperIsland KA1 owned adapter v1. Only lifecycle and opaque session identity.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
const tool = __SUPERISLAND_TOOL__;
const credential = __SUPERISLAND_CREDENTIAL__;
export default function (pi) {
  let session, taskID, state = "idle", timer;
  let pending = Promise.resolve(), queued = 0;
  const send = (next, startsTask = false) => {
    state = next;
    if (!session) return;
    const id = session, round = taskID;
    if (queued >= 32) return;
    queued++;
    pending = pending.then(() => new Promise((resolve) => {
      const child = spawn(tool, ["--superisland-ka1", "pi", credential], { stdio: ["pipe", "ignore", "ignore"] });
      const timeout = setTimeout(() => { child.kill(); resolve(); }, 2000);
      child.on("error", () => { clearTimeout(timeout); resolve(); });
      child.on("exit", () => { clearTimeout(timeout); resolve(); });
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify({ session_id: id, hook_event_name: next, task_start: startsTask, ka1_task_id: round }));
    })).catch(() => {}).finally(() => { queued--; });
  };
  pi.on("session_start", (_event, ctx) => {
    clearInterval(timer);
    session = ctx.sessionManager.getSessionId();
    taskID = undefined; state = "idle";
    timer = setInterval(() => { if (state === "running") send(state); }, 20000);
    timer.unref();
  });
  pi.on("agent_start", () => {
    // Retries/compaction can start another low-level run before settlement.
    // Keep one task identity until the complete batch is actually settled.
    const startsTask = !taskID || ["idle", "completed", "cancelled"].includes(state);
    if (startsTask) taskID = randomUUID();
    send("running", startsTask);
  });
  // agent_end can be followed by retries/continuations; only settled is final.
  pi.on("agent_settled", () => send("completed"));
  pi.on("session_shutdown", () => { clearInterval(timer); send("cancelled"); session = undefined; taskID = undefined; });
}
