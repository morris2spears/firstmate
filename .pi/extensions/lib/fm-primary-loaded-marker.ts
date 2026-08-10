// One definition of "this Pi session owns the firstmate session lock" and of the
// extension version stamp, shared by every tracked primary extension that writes
// a state/.pi-*-extension-loaded marker. bin/fm-session-start.sh reads those
// markers and compares each stamp against the hash of the extension file it
// found on disk, so all writers must agree on both contracts.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

export type LockOwnership = "owned" | "missing" | "other";

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

export function lockOwnership(state: string): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

export function extensionVersionOf(extensionFile: string): string {
  return `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
}
