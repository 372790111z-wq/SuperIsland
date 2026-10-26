// SuperIsland KA1 owned adapter v1. No prompts, messages or file paths are read.
import { spawn } from "node:child_process";
const tool = __SUPERISLAND_TOOL__;
const credential = __SUPERISLAND_CREDENTIAL__;
export const SuperIslandKeepAwake = async () => {
  const states = new Map();
  let pending = Promise.resolve(), queued = 0;
  const send = (session, state, startsTask = false) => {
    if (typeof session !== "string" || !session || session.length > 512) return;
    if (!states.has(session) && states.size >= 1024) return;
    states.set(session, state);
    if (queued >= 32) return;
    queued++;
    // Bound buffering and serialize so a slow child cannot reorder stop/start.
    pending = pending.then(() => new Promise((resolve) => {
      const child = spawn(tool, ["--superisland-ka1", "opencode", credential], { stdio: ["pipe", "ignore", "ignore"] });
      const timeout = setTimeout(() => { child.kill(); resolve(); }, 2000);
      child.on("error", () => { clearTimeout(timeout); resolve(); });
      child.on("exit", () => { clearTimeout(timeout); resolve(); });
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify({ session_id: session, hook_event_name: state, task_start: startsTask }));
    })).catch(() => {}).finally(() => { queued--; });
  };
  const heartbeat = setInterval(() => {
    for (const [id, state] of states) if (state === "running" || state === "waiting") send(id, state);
  }, 20000);
  heartbeat.unref();
  // This timer cannot keep the source process alive; if it exits/crashes,
  // SuperIsland keeps established work as unknown. No process-presence heuristic.
  return { event: async ({ event }) => {
    const p = event?.properties;
    if (!p || typeof p.sessionID !== "string") return;
    switch (event.type) {
      case "session.status":
        if (p.status?.type === "busy" || p.status?.type === "retry") send(p.sessionID, "running", !states.has(p.sessionID));
        if (p.status?.type === "idle") send(p.sessionID, "idle");
        break;
      case "session.idle": send(p.sessionID, "idle"); break;
      case "session.error": send(p.sessionID, "failed"); break;
      case "permission.asked": send(p.sessionID, "waiting"); break;
      // A permission reply is not proof of work. Wait for a new busy event.
    }
  }};
};
