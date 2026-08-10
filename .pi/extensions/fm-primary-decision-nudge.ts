// Pi primary captain-attention nudge.
//
// Pi normally asks the captain in chat. Once agent_settled proves no automatic
// retry, compaction, or follow-up remains, this extension inspects the latest
// assistant text and arms bin/fm-decision-nudge.sh only for an explicit
// captain-facing question or decision request. The shared script owns primary
// scope, Telegram opt-in, marker, timer, and send semantics.
import { spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { extensionVersionOf, lockOwnership } from "./lib/fm-primary-loaded-marker.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const nudgeScript = `${fmRoot}/bin/fm-decision-nudge.sh`;
const loadedMarker = `${state}/.pi-decision-nudge-extension-loaded`;
const extensionVersion = extensionVersionOf(extensionFile);

// Same loaded-marker contract as the two sibling primary extensions, so
// bin/fm-session-start.sh can report this one as missing instead of silently
// losing the nudge when project trust was never approved.
function markLoaded(): void {
  try {
    if (!existsSync(state) || lockOwnership(state) === "other") return;
    writeFileSync(loadedMarker, `${extensionVersion}\n${process.pid}\n`);
  } catch {
  }
}

// A bare decision verb is not an ask: a settled watcher turn like "Captain, PR
// #7 is merged. I'll confirm the deploy once you're back." must not page him.
// The verb only counts in an imperative (sentence- or vocative-initial) or
// second-person/explicit-request position.
const DECISION_VERBS = "choose|select|pick|decide|confirm|approve";
const DECISION_PATTERNS = [
  /\b(?:yes\s*\/\s*no|yes\s+or\s+no)\b/i,
  /\b(?:do you want|would you like|shall I|should I|may I|can I)\b/i,
  new RegExp(String.raw`(?:^|[.!?]\s+|\n\s*|\bcaptain\s*[,:-]\s*)(?:please\s+)?(?:${DECISION_VERBS})\b`, "i"),
  new RegExp(
    String.raw`\b(?:please|need you to|needs you to|want you to|waiting (?:on|for) you to|for you to|your call|up to you)\b[^.?!]{0,60}\b(?:${DECISION_VERBS})\b`,
    "i",
  ),
  new RegExp(String.raw`\byou\s+(?:${DECISION_VERBS})\b`, "i"),
  /\b(?:need|needs|awaiting|requires?|requesting)\b.{0,80}\b(?:decision|approval|choice|answer|confirmation)\b/i,
  /\b(?:decision|approval|choice|answer|confirmation)\b.{0,80}\b(?:needed|required|awaiting|please)\b/i,
  /\boptions?\s*:/i,
];

export function isCaptainAttentionWait(text: string): boolean {
  const candidate = text.trim();
  if (!candidate || candidate === "Captain, shipshape.") return false;
  if (!/\bCaptain\b/.test(candidate)) return false;
  return candidate.includes("?") || DECISION_PATTERNS.some((pattern) => pattern.test(candidate));
}

type SessionMessageEntry = {
  type?: string;
  id?: string;
  message?: {
    role?: string;
    content?: unknown;
  };
};

function assistantText(content: unknown): string {
  if (typeof content === "string") return content.trim();
  if (!Array.isArray(content)) return "";
  return content
    .filter((block): block is { type: "text"; text: string } => (
      typeof block === "object" && block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string"
    ))
    .map((block) => block.text)
    .join("\n")
    .trim();
}

export function latestCaptainAttentionWait(ctx: Pick<ExtensionContext, "sessionManager">): { id: string; text: string } | null {
  const branch = ctx.sessionManager.getBranch() as SessionMessageEntry[];
  for (let index = branch.length - 1; index >= 0; index -= 1) {
    const entry = branch[index];
    if (entry.type !== "message") continue;
    // The scan stops at the turn boundary: an ask from an earlier turn the
    // captain already answered must never re-arm.
    if (entry.message?.role === "user") return null;
    if (entry.message?.role !== "assistant") continue;
    const text = assistantText(entry.message.content);
    if (!text) continue;
    const id = typeof entry.id === "string" ? entry.id : "";
    return id && isCaptainAttentionWait(text) ? { id, text } : null;
  }
  return null;
}

function invokeNudge(mode: "--pi-arm" | "--pi-resolved", id = ""): void {
  try {
    const args = id ? [mode, id] : [mode];
    const child = spawn(nudgeScript, args, {
      detached: true,
      env: {
        ...process.env,
        FM_HOME: fmHome,
        FM_ROOT_OVERRIDE: fmRoot,
        FM_STATE_OVERRIDE: state,
        FM_CONFIG_OVERRIDE: config,
      },
      stdio: "ignore",
    });
    child.on("error", () => {});
    child.unref();
  } catch {
    // Notification support must never interfere with the Pi session.
  }
}

export default function (pi: ExtensionAPI) {
  const disarm = (): void => invokeNudge("--pi-resolved");

  // A real interactive or RPC input is direct evidence that the captain is
  // present. Extension-injected operational messages are not presence signals.
  pi.on("input", (event) => {
    if (event.source !== "extension") disarm();
    return { action: "continue" };
  });

  // Covers expanded prompts and any run started without traversing input.
  pi.on("before_agent_start", () => {
    disarm();
  });

  pi.on("agent_settled", (_event, ctx) => {
    const wait = latestCaptainAttentionWait(ctx);
    if (wait) invokeNudge("--pi-arm", wait.id);
  });

  pi.on("session_shutdown", () => {
    disarm();
  });

  pi.on?.("session_start", () => {
    markLoaded();
  });

  markLoaded();
}
