// Reports this OpenCode tab's status to Archipel. Archipel loads it into the TUI process through
// OPENCODE_CLI_CONFIG_CONTENT, so process.env is the tab's own environment. It only observes: every
// failure is swallowed so a bug here can never get in the way of the user's session.
import { spawn } from "node:child_process";

const HOOK = process.env.ARCHIPEL_HOOK_BIN;
const SESSION = process.env.ARCHIPEL_SESSION_ID;
const ROUTE_POLL_MS = 500;

// One archipel-hook at a time, so the app sees events in the order they happened.
let queue = Promise.resolve();
function send(event, fields = {}) {
  const payload = JSON.stringify({ event, ...fields });
  queue = queue
    .then(
      () =>
        new Promise((resolve) => {
          try {
            const child = spawn(HOOK, ["event", "opencode"], { stdio: ["pipe", "ignore", "ignore"] });
            child.on("error", resolve);
            child.on("exit", resolve);
            child.stdin.on("error", () => {});
            child.stdin.end(payload);
          } catch {
            resolve();
          }
        }),
    )
    .catch(() => {});
}

export default {
  id: "archipel.status",
  setup(ctx) {
    if (!HOOK || !SESSION) return;
    try {
      return start(ctx);
    } catch {
      return undefined;
    }
  },
};

function start(ctx) {
  const data = ctx.data;
  // Subagents run as sessions of their own; they count as part of the conversation they belong to.
  const rootOf = (id) => {
    try {
      return data.session.root?.(id) || id;
    } catch {
      return id;
    }
  };

  // The background service delivers events for every session of every tab, so everything is
  // filtered against the conversation this tab is showing. The TUI has no route-change event, and
  // the user can switch sessions from inside it, which is why this is polled.
  let shown;
  const currentRoot = () => {
    const route = ctx.ui.router.current();
    return route?.type === "session" ? rootOf(route.sessionID) : undefined;
  };
  const isMine = (sessionID) => typeof sessionID === "string" && shown !== undefined && rootOf(sessionID) === shown;

  const follow = async () => {
    try {
      const next = currentRoot();
      if (!next || next === shown) return;
      const first = shown === undefined;
      shown = next;
      // The app cannot know whether the conversation it switches to is mid-turn, so say so.
      let running = false;
      try {
        running = (await data.session.status(next)) === "running";
      } catch {}
      send(first ? "started" : "switched", { opencodeSessionID: next, running });
    } catch {}
  };
  const timer = setInterval(follow, ROUTE_POLL_MS);
  follow();

  const stopListening = data.listen((message) => {
    try {
      const type = message?.details?.type;
      const d = message?.details?.data ?? {};
      const sessionID = d.sessionID ?? d.form?.sessionID;
      if (!type || !isMine(sessionID)) return;
      // Turn state belongs to the conversation itself, not to its subagents.
      const isRoot = sessionID === shown;
      const report = (event, fields = {}) => send(event, { opencodeSessionID: shown, ...fields });
      switch (type) {
        case "session.created":
          if (isRoot) report("started");
          break;
        case "session.inbox.enqueued":
          if (isRoot && d.item?.type === "user") report("prompt");
          break;
        case "session.execution.started":
          if (isRoot) report("busy");
          break;
        case "session.execution.succeeded":
        case "session.execution.interrupted":
          if (isRoot) report("idle");
          break;
        case "session.execution.failed":
          if (isRoot) report("error", { message: d.error?.message ?? d.error?.type });
          break;
        case "permission.asked":
          report("permission", { action: d.action, resources: d.resources });
          break;
        case "permission.replied":
          report("permission-replied");
          break;
        case "form.created":
          report("question");
          break;
      }
    } catch {}
  });

  return () => {
    clearInterval(timer);
    try {
      stopListening?.();
    } catch {}
  };
}
