// Pi primary captain-attention nudge.
//
// Pi normally asks the captain in chat. Once agent_settled proves no automatic
// retry, compaction, or follow-up remains, this extension inspects the latest
// assistant text and arms bin/fm-decision-nudge.sh only for an explicit
// captain-facing question or decision request. The shared script owns primary
// scope, Telegram opt-in, marker, timer, and send semantics.
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const nudgeScript = `${fmRoot}/bin/fm-decision-nudge.sh`;

const DECISION_PATTERNS = [
  /\b(?:yes\s*\/\s*no|yes\s+or\s+no)\b/i,
  /\b(?:do you want|would you like|shall I|should I|may I|can I)\b/i,
  /\b(?:choose|select|pick|decide|confirm|approve)\b/i,
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
    if (entry.type !== "message" || entry.message?.role !== "assistant") continue;
    const id = typeof entry.id === "string" ? entry.id : "";
    const text = assistantText(entry.message.content);
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
}
