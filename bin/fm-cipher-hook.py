#!/usr/bin/env python3
"""Authenticated, idempotent Cipher/Hermes event delivery implementation.

The shell entrypoint owns operator-facing commands and current-state preflight.
This module owns the payload allowlist, local configuration validation, durable
request/delivery records, HMAC transport, and exact-head merge authorization.
"""

from __future__ import annotations

import hashlib
import hmac
import http.client
import json
import os
import re
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fm_cipher_repositories import RegistrationError, registered_repositories

SCHEMA = "firstmate.cipher-hook.v1"
DELIVERY_ACK_SCHEMA = "firstmate.cipher-hook-delivery-ack.v1"
DELIVERY_SCHEMA = "firstmate.cipher-hook-delivery.v1"
HOLD_SCHEMA = "firstmate.cipher-hook-hold.v1"
TASK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
DECISION_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
REPO_PART_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,98}[A-Za-z0-9])?$")
OWNER_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
PR_RE = re.compile(
    r"^https://github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/"
    r"([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$"
)
ISSUE_RE = re.compile(
    r"^https://github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/"
    r"([A-Za-z0-9._-]{1,100})/issues/([1-9][0-9]*)$"
)
ISSUE_FIND_RE = re.compile(
    r"https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}/issues/[1-9][0-9]*"
)
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
REQUEST_RE = re.compile(r"^fmch-v1-[0-9a-f]{64}$")
RECEIVE_RE = re.compile(r"^fmcr-v1-[0-9a-f]{64}$")
COMMENT_RE = re.compile(
    r"^https://github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/"
    r"([A-Za-z0-9._-]{1,100})/(?:issues|pull)/[1-9][0-9]*#issuecomment-[1-9][0-9]*$"
)
TRANSIENT_HTTP = frozenset({408, 425, 429})
SUPERSEDED_PREFIX = "superseded-"
SUPERSEDE_REASON_RE = re.compile(r"^[a-z0-9-]{1,64}$")
MAX_BODY = 4096
MAX_RESPONSE = 4096
MAX_META = 65536
MAX_STATUS = 1024 * 1024
MAX_BACKLOG = 1024 * 1024


class HookError(Exception):
    def __init__(self, reason: str, *, usage: bool = False) -> None:
        super().__init__(reason)
        self.reason = reason
        self.usage = usage


class RouteDisabled(HookError):
    pass


def code_root() -> Path:
    return Path(__file__).resolve().parent.parent


def gated_repos() -> frozenset[str]:
    try:
        return registered_repositories()
    except RegistrationError as exc:
        raise HookError("repository-registration-unavailable") from exc


def operational_paths() -> tuple[Path, Path, Path]:
    root = Path(os.environ.get("FM_ROOT_OVERRIDE", str(code_root()))).resolve()
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", str(root)))).resolve()
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", str(home / "state"))).resolve()
    data_dir = Path(os.environ.get("FM_DATA_OVERRIDE", str(home / "data"))).resolve()
    config_dir = Path(os.environ.get("FM_CONFIG_OVERRIDE", str(home / "config"))).resolve()
    return state_dir, data_dir, config_dir


def validate_task(task_id: str) -> None:
    if not TASK_RE.fullmatch(task_id) or task_id in {".", ".."}:
        raise HookError("invalid-task", usage=True)


def validate_decision(decision_id: str) -> None:
    if not DECISION_RE.fullmatch(decision_id) or decision_id in {".", ".."}:
        raise HookError("invalid-decision", usage=True)


def canonical_repo(owner: str, repo: str) -> str:
    if not OWNER_RE.fullmatch(owner) or "--" in owner:
        raise HookError("invalid-repository", usage=True)
    if not REPO_PART_RE.fullmatch(repo) or repo in {".", ".."}:
        raise HookError("invalid-repository", usage=True)
    return f"{owner}/{repo}".lower()


def parse_pr(url: str) -> tuple[str, str]:
    match = PR_RE.fullmatch(url)
    if not match:
        raise HookError("invalid-pr-url", usage=True)
    return canonical_repo(match.group(1), match.group(2)), url


def parse_issue(url: str) -> tuple[str, str]:
    match = ISSUE_RE.fullmatch(url)
    if not match:
        raise HookError("invalid-issue-url", usage=True)
    return canonical_repo(match.group(1), match.group(2)), url


def regular_file(path: Path, maximum: int, *, mode_600: bool = False) -> bytes:
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise HookError("file-missing") from exc
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise HookError("file-unsafe")
    if mode_600 and stat.S_IMODE(info.st_mode) != 0o600:
        raise HookError("file-mode")
    if info.st_size > maximum:
        raise HookError("file-oversized")
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise HookError("file-unreadable") from exc
    if len(data) > maximum:
        raise HookError("file-oversized")
    return data


def parse_meta(path: Path) -> dict[str, str]:
    raw = regular_file(path, MAX_META)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise HookError("metadata-invalid") from exc
    values: dict[str, str] = {}
    protected = {"pr", "pr_head", "worktree"}
    seen: set[str] = set()
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in protected and key in seen:
            raise HookError("metadata-ambiguous")
        seen.add(key)
        values[key] = value
    return values


def task_backlog_line(data_dir: Path, task_id: str) -> str | None:
    path = data_dir / "backlog.md"
    if not path.exists():
        return None
    raw = regular_file(path, MAX_BACKLOG)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise HookError("backlog-invalid") from exc
    marker = re.compile(rf"\]\s+{re.escape(task_id)}\s+-")
    matches = [line for line in text.splitlines() if marker.search(line)]
    if len(matches) > 1:
        raise HookError("backlog-ambiguous")
    return matches[0] if matches else None


def issue_from_backlog(data_dir: Path, task_id: str, preferred_repo: str | None) -> str | None:
    line = task_backlog_line(data_dir, task_id)
    if line is None:
        return None
    candidates: dict[str, str] = {}
    for raw_url in ISSUE_FIND_RE.findall(line):
        repo, url = parse_issue(raw_url)
        candidates[url] = repo
    if preferred_repo:
        preferred = [url for url, repo in candidates.items() if repo == preferred_repo]
        if len(preferred) == 1:
            return preferred[0]
        if len(preferred) > 1:
            raise HookError("issue-ambiguous")
    if len(candidates) == 1:
        return next(iter(candidates))
    if len(candidates) > 1:
        raise HookError("issue-ambiguous")
    return None


def repo_from_origin(worktree: str) -> str | None:
    if not worktree or "\x00" in worktree:
        return None
    path = Path(worktree)
    if not path.is_absolute() or not path.is_dir():
        return None
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "remote", "get-url", "origin"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    remote = result.stdout.strip()
    patterns = (
        r"^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$",
        r"^git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$",
        r"^ssh://git@github\.com/([^/]+)/([^/]+?)(?:\.git)?$",
    )
    for pattern in patterns:
        match = re.fullmatch(pattern, remote)
        if match:
            try:
                return canonical_repo(match.group(1), match.group(2))
            except HookError:
                return None
    return None


def identity_for_event(kind: str, task_id: str, argument: str | None) -> dict[str, Any]:
    validate_task(task_id)
    state_dir, data_dir, _ = operational_paths()
    meta_path = state_dir / f"{task_id}.meta"
    meta = parse_meta(meta_path)
    explicit_pr: str | None = None
    decision_id: str | None = None
    if kind == "needs-decision":
        decision_id = argument or "default"
        validate_decision(decision_id)
    elif kind == "iinvy-pr-ready":
        if argument is None:
            raise HookError("missing-pr-url", usage=True)
        _, explicit_pr = parse_pr(argument)
    else:
        raise HookError("unexpected-event-kind", usage=True)

    meta_pr = meta.get("pr") or None
    pr_url = explicit_pr or meta_pr
    pr_repo: str | None = None
    if pr_url:
        pr_repo, pr_url = parse_pr(pr_url)
    if explicit_pr and meta_pr and explicit_pr != meta_pr:
        raise HookError("pr-metadata-mismatch")

    pr_head = meta.get("pr_head") or None
    if pr_head and not SHA_RE.fullmatch(pr_head):
        raise HookError("invalid-pr-head")
    if kind == "iinvy-pr-ready" and not pr_head:
        raise HookError("missing-pr-head")

    origin_repo = repo_from_origin(meta.get("worktree", ""))
    if pr_repo and origin_repo and pr_repo != origin_repo:
        raise HookError("repository-mismatch")
    repo = pr_repo or origin_repo
    issue_url = issue_from_backlog(data_dir, task_id, repo)
    issue_repo = parse_issue(issue_url)[0] if issue_url else None
    repo = repo or issue_repo
    if not repo:
        raise HookError("repository-unknown")
    if kind == "iinvy-pr-ready" and repo not in gated_repos():
        raise HookError("repository-not-gated", usage=True)

    evidence = [
        {"kind": "task-metadata", "pointer": f"state/{task_id}.meta"},
        {"kind": "status-events", "pointer": f"state/{task_id}.status"},
    ]
    payload: dict[str, Any] = {
        "schema": SCHEMA,
        "event_type": kind,
        "task_id": task_id,
        "repository": repo,
        "issue_url": issue_url,
        "pr_url": pr_url,
        "pr_head_sha": pr_head,
        "decision_id": decision_id,
        "evidence": evidence,
    }
    payload["request_id"] = logical_request_id(payload)
    validate_payload(payload)
    return payload


def logical_request_id(payload: dict[str, Any]) -> str:
    if payload["event_type"] == "needs-decision":
        identity: dict[str, Any] = {
            key: payload[key]
            for key in ("schema", "event_type", "task_id", "repository", "decision_id")
        }
    else:
        identity = {key: value for key, value in payload.items() if key != "request_id"}
    logical = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return "fmch-v1-" + hashlib.sha256(logical).hexdigest()


def validate_payload(payload: dict[str, Any]) -> None:
    expected = {
        "schema",
        "event_type",
        "request_id",
        "task_id",
        "repository",
        "issue_url",
        "pr_url",
        "pr_head_sha",
        "decision_id",
        "evidence",
    }
    if set(payload) != expected or payload["schema"] != SCHEMA:
        raise HookError("payload-schema")
    if payload["event_type"] not in {"needs-decision", "iinvy-pr-ready"}:
        raise HookError("unexpected-event-kind")
    validate_task(payload["task_id"])
    if not REQUEST_RE.fullmatch(payload["request_id"]):
        raise HookError("invalid-request-id")
    repo = payload["repository"]
    if not isinstance(repo, str) or "/" not in repo:
        raise HookError("invalid-repository")
    owner, name = repo.split("/", 1)
    if canonical_repo(owner, name) != repo:
        raise HookError("invalid-repository")
    if payload["issue_url"] is not None and parse_issue(payload["issue_url"])[1] != payload["issue_url"]:
        raise HookError("invalid-issue-url")
    if payload["pr_url"] is not None and parse_pr(payload["pr_url"])[1] != payload["pr_url"]:
        raise HookError("invalid-pr-url")
    if payload["pr_head_sha"] is not None and not SHA_RE.fullmatch(payload["pr_head_sha"]):
        raise HookError("invalid-pr-head")
    if payload["decision_id"] is not None:
        validate_decision(payload["decision_id"])
    expected_evidence = [
        {"kind": "task-metadata", "pointer": f"state/{payload['task_id']}.meta"},
        {"kind": "status-events", "pointer": f"state/{payload['task_id']}.status"},
    ]
    if payload["evidence"] != expected_evidence:
        raise HookError("invalid-evidence")
    body = canonical_body(payload)
    if len(body) > MAX_BODY:
        raise HookError("payload-oversized")


def canonical_body(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def ensure_private_dir(path: Path) -> None:
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700:
            raise HookError("state-directory-unsafe")
        return
    path.mkdir(mode=0o700)


def record_dirs() -> dict[str, Path]:
    state_dir, _, _ = operational_paths()
    if not state_dir.exists() or not state_dir.is_dir() or state_dir.is_symlink():
        raise HookError("state-directory-unsafe")
    base = state_dir / "cipher-hooks"
    ensure_private_dir(base)
    dirs: dict[str, Path] = {}
    for name in ("requests", "sent", "acks", "holds", "diagnostics", "received"):
        path = base / name
        ensure_private_dir(path)
        dirs[name] = path
    return dirs


def safe_existing(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
        raise HookError("state-record-unsafe")


def atomic_write(path: Path, data: bytes) -> None:
    safe_existing(path)
    fd, temporary = tempfile.mkstemp(prefix=".cipher-hook.", dir=str(path.parent))
    tmp_path = Path(temporary)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        safe_existing(path)
        os.replace(tmp_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def read_json_record(path: Path) -> dict[str, Any] | None:
    if not path.exists() and not path.is_symlink():
        return None
    raw = regular_file(path, MAX_BODY, mode_600=True)
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HookError("state-record-invalid") from exc
    if not isinstance(value, dict):
        raise HookError("state-record-invalid")
    return value


def adopt_recorded_request(dirs: dict[str, Path], payload: dict[str, Any]) -> dict[str, Any]:
    recorded = read_json_record(dirs["requests"] / f"{payload['request_id']}.json")
    if recorded is None or canonical_body(recorded) == canonical_body(payload):
        return payload
    validate_payload(recorded)
    if (
        recorded["request_id"] != payload["request_id"]
        or logical_request_id(recorded) != payload["request_id"]
    ):
        raise HookError("request-identity-collision")
    return recorded


def store_request(dirs: dict[str, Path], payload: dict[str, Any]) -> bytes:
    request_id = payload["request_id"]
    body = canonical_body(payload)
    path = dirs["requests"] / f"{request_id}.json"
    if path.exists() or path.is_symlink():
        current = regular_file(path, MAX_BODY, mode_600=True)
        if current != body:
            raise HookError("request-identity-collision")
    else:
        atomic_write(path, body)
    return body


def parse_endpoint(endpoint: str) -> tuple[str, int, str, str]:
    if len(endpoint) > 300:
        raise HookError("configuration-invalid")
    parsed = urlsplit(endpoint)
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.username or parsed.password:
        raise HookError("configuration-invalid")
    if parsed.query or parsed.fragment or parsed.port is None:
        raise HookError("configuration-invalid")
    if not (1 <= parsed.port <= 65535):
        raise HookError("configuration-invalid")
    route = parsed.path
    match = re.fullmatch(
        r"/(?:webhooks|p/[A-Za-z0-9_-]+/webhooks)/([A-Za-z0-9_-]+)", route
    )
    if not match or len(route) > 200:
        raise HookError("configuration-invalid")
    return parsed.hostname, parsed.port, route, match.group(1)


def load_config(kind: str) -> dict[str, Any]:
    _, _, config_dir = operational_paths()
    path = config_dir / "cipher-hooks"
    if not path.exists() and not path.is_symlink():
        if kind == "needs-decision":
            raise RouteDisabled("route-disabled")
        raise HookError("configuration-missing")
    raw = regular_file(path, 4096, mode_600=True)
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise HookError("configuration-invalid") from exc
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise HookError("configuration-invalid")
        key, value = line.split("=", 1)
        if key in values or key not in {
            "version",
            "decision_route",
            "iinvy_pr_ready_route",
            "endpoint",
            "secret_file",
        }:
            raise HookError("configuration-invalid")
        values[key] = value
    if set(values) != {
        "version",
        "decision_route",
        "iinvy_pr_ready_route",
        "endpoint",
        "secret_file",
    } or values["version"] != "1":
        raise HookError("configuration-invalid")
    if values["decision_route"] not in {"enabled", "disabled"}:
        raise HookError("configuration-invalid")
    if values["iinvy_pr_ready_route"] not in {"enabled", "disabled"}:
        raise HookError("configuration-invalid")
    route_key = "decision_route" if kind == "needs-decision" else "iinvy_pr_ready_route"
    if values[route_key] != "enabled":
        if kind == "needs-decision":
            raise RouteDisabled("route-disabled")
        raise HookError("route-disabled")
    host, port, route, route_name = parse_endpoint(values["endpoint"])
    secret_path = Path(values["secret_file"])
    if not secret_path.is_absolute() or ".." in secret_path.parts:
        raise HookError("configuration-invalid")
    secret_raw = regular_file(secret_path, 256, mode_600=True)
    try:
        secret_text = secret_raw.decode("ascii").strip()
    except UnicodeDecodeError as exc:
        raise HookError("secret-invalid") from exc
    if not re.fullmatch(r"[0-9a-f]{64}", secret_text):
        raise HookError("secret-invalid")
    secret = secret_text.encode("ascii")
    fingerprint = hashlib.sha256(
        values["endpoint"].encode("ascii") + b"\0" + secret + b"\0" + route_key.encode("ascii")
    ).hexdigest()
    return {
        "endpoint": values["endpoint"],
        "host": host,
        "port": port,
        "route": route,
        "route_name": route_name,
        "secret": secret,
        "fingerprint": fingerprint,
    }


def transient_hold_reason(reason: str) -> bool:
    """True only for delivery failures expected to clear on gateway recovery."""
    if reason in {"unavailable", "timeout"}:
        return True
    match = re.fullmatch(r"http-([1-9][0-9]{2})", reason)
    if not match:
        return False
    code = int(match.group(1))
    return code in TRANSIENT_HTTP or 500 <= code <= 599


def read_hold(dirs: dict[str, Path], request_id: str) -> dict[str, Any] | None:
    record = read_json_record(dirs["holds"] / f"{request_id}.json")
    if record is None:
        return None
    if (
        set(record) != {"schema", "request_id", "event_type", "reason"}
        or record.get("schema") != HOLD_SCHEMA
        or record.get("request_id") != request_id
        or record.get("event_type") not in {"needs-decision", "iinvy-pr-ready"}
        or not isinstance(record.get("reason"), str)
    ):
        raise HookError("state-record-invalid")
    return record


def diagnostic_message(reason: str) -> str:
    messages = {
        "configuration-missing": "local Cipher route configuration is missing",
        "configuration-invalid": "local Cipher route configuration is invalid",
        "route-disabled": "the required Cipher route is disabled",
        "file-missing": "a required local Cipher file is missing",
        "file-mode": "a local Cipher configuration or secret file is not mode 0600",
        "file-unsafe": "a local Cipher configuration or secret file is unsafe",
        "file-unreadable": "a required local Cipher file cannot be read",
        "file-oversized": "a local Cipher file exceeds its size limit",
        "secret-invalid": "the local Cipher HMAC secret is invalid",
        "timeout": "the local Cipher gateway timed out",
        "unavailable": "the local Cipher gateway is unavailable",
        "invalid-response": "the local Cipher gateway returned an invalid acknowledgement",
        "missing-pr-head": "the checks-green PR head could not be bound",
        "decision-comment-missing": "no authenticated Cipher decision comment is recorded for this request",
        "repository-unknown": "the task's canonical GitHub repository could not be established",
        "repository-registration-unavailable": "the repository registration source is unavailable",
        "repository-mismatch": "the task repository does not match its pull request",
        "pr-metadata-mismatch": "the pull request does not match task metadata",
    }
    if reason.startswith(SUPERSEDED_PREFIX):
        return f"the held event was superseded ({reason.removeprefix(SUPERSEDED_PREFIX)})"
    if reason.startswith("http-"):
        return f"the local Cipher gateway rejected delivery ({reason})"
    return messages.get(reason, f"Cipher delivery is held ({reason})")


def write_hold(dirs: dict[str, Path], payload: dict[str, Any], reason: str) -> None:
    request_id = payload["request_id"]
    hold = {
        "schema": HOLD_SCHEMA,
        "request_id": request_id,
        "event_type": payload["event_type"],
        "reason": reason,
    }
    atomic_write(
        dirs["holds"] / f"{request_id}.json",
        json.dumps(hold, sort_keys=True, separators=(",", ":")).encode("utf-8"),
    )
    marker = dirs["diagnostics"] / request_id
    marker_data = reason.encode("ascii", "strict")
    existing: bytes | None = None
    if marker.exists() or marker.is_symlink():
        existing = regular_file(marker, 256, mode_600=True)
    if existing != marker_data:
        atomic_write(marker, marker_data)
        print(f"CIPHER_HOOK: {request_id} held: {diagnostic_message(reason)}.", file=sys.stderr)


def clear_hold(dirs: dict[str, Path], request_id: str) -> None:
    for directory, suffix in (("holds", ".json"), ("diagnostics", "")):
        path = dirs[directory] / f"{request_id}{suffix}"
        if path.exists() or path.is_symlink():
            safe_existing(path)
            path.unlink()


def sent_attempts(dirs: dict[str, Path], request_id: str) -> int:
    record = read_json_record(dirs["sent"] / f"{request_id}.json")
    if record is None:
        return 0
    if (
        set(record) != {"schema", "request_id", "attempts", "last_result"}
        or record.get("schema") != DELIVERY_SCHEMA
        or record.get("request_id") != request_id
        or not isinstance(record.get("attempts"), int)
        or record["attempts"] < 0
        or not isinstance(record.get("last_result"), str)
    ):
        raise HookError("state-record-invalid")
    return record["attempts"]


def write_sent(dirs: dict[str, Path], request_id: str, attempts: int, result: str) -> None:
    record = {
        "schema": DELIVERY_SCHEMA,
        "request_id": request_id,
        "attempts": attempts,
        "last_result": result,
    }
    atomic_write(
        dirs["sent"] / f"{request_id}.json",
        json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8"),
    )


def stored_ack_valid(record: dict[str, Any], payload: dict[str, Any]) -> bool:
    expected_keys = {
        "schema",
        "request_id",
        "event_type",
        "endpoint",
        "route_name",
        "config_fingerprint",
        "http_status",
        "gateway_ack",
    }
    if set(record) != expected_keys or record.get("schema") != DELIVERY_ACK_SCHEMA:
        return False
    request_id = payload["request_id"]
    if record.get("request_id") != request_id or record.get("event_type") != payload["event_type"]:
        return False
    endpoint = record.get("endpoint")
    route_name = record.get("route_name")
    fingerprint = record.get("config_fingerprint")
    if not isinstance(endpoint, str) or not isinstance(route_name, str):
        return False
    try:
        _, _, _, endpoint_route_name = parse_endpoint(endpoint)
    except HookError:
        return False
    if endpoint_route_name != route_name or not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
        return False
    gateway = record.get("gateway_ack")
    accepted = {
        "status": "accepted",
        "route": record.get("route_name"),
        "event": payload["event_type"],
        "delivery_id": request_id,
    }
    duplicate = {"status": "duplicate", "delivery_id": request_id}
    return (record.get("http_status") == 202 and gateway == accepted) or (
        record.get("http_status") == 200 and gateway == duplicate
    )


def valid_ack(dirs: dict[str, Path], payload: dict[str, Any], config: dict[str, Any]) -> bool:
    request_id = payload["request_id"]
    record = read_json_record(dirs["acks"] / f"{request_id}.json")
    if record is None:
        return False
    if not stored_ack_valid(record, payload):
        raise HookError("state-record-invalid")
    if (
        record.get("endpoint") != config["endpoint"]
        or record.get("route_name") != config["route_name"]
        or record.get("config_fingerprint") != config["fingerprint"]
    ):
        return False
    return True


def response_ack(
    raw: bytes,
    request_id: str,
    status_code: int,
    route_name: str,
    event_type: str,
) -> dict[str, str] | None:
    if len(raw) > MAX_RESPONSE:
        return None
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if status_code == 202:
        expected = {
            "status": "accepted",
            "route": route_name,
            "event": event_type,
            "delivery_id": request_id,
        }
    elif status_code == 200:
        expected = {"status": "duplicate", "delivery_id": request_id}
    else:
        return None
    return expected if value == expected else None


def post_once(
    config: dict[str, Any],
    body: bytes,
    request_id: str,
    event_type: str,
    timeout: float,
) -> tuple[str, dict[str, str] | None, int | None]:
    timestamp = str(int(time.time()))
    legacy_test = (
        os.environ.get("FM_CIPHER_SIGNATURE_VERSION") == "legacy-v1"
        and os.environ.get("FM_CIPHER_ALLOW_LEGACY_V1_TEST") == "1"
    )
    if legacy_test:
        signature = hmac.new(config["secret"], body, hashlib.sha256).hexdigest()
        signature_headers = {"X-Webhook-Signature": signature}
    else:
        signed = timestamp.encode("ascii") + b"." + body
        signature = hmac.new(config["secret"], signed, hashlib.sha256).hexdigest()
        signature_headers = {
            "X-Webhook-Signature-V2": signature,
            "X-Webhook-Timestamp": timestamp,
        }
    connection = http.client.HTTPConnection(config["host"], config["port"], timeout=timeout)
    headers = {
        "Content-Type": "application/json",
        "Content-Length": str(len(body)),
        "X-Request-ID": request_id,
        "Idempotency-Key": request_id,
        **signature_headers,
    }
    try:
        connection.request("POST", config["route"], body=body, headers=headers)
        response = connection.getresponse()
        raw = response.read(MAX_RESPONSE + 1)
        status_code = response.status
    # socket.timeout is an alias of TimeoutError only from Python 3.10 onward.
    # Stock macOS Apple Python 3.9 raises a distinct OSError subclass, so dropping
    # it here would misclassify a gateway timeout as "unavailable".
    except (TimeoutError, socket.timeout):
        return "timeout", None, None
    except OSError:
        return "unavailable", None, None
    finally:
        connection.close()
    if status_code in {200, 202}:
        ack = response_ack(raw, request_id, status_code, config["route_name"], event_type)
        return (ack["status"], ack, status_code) if ack else ("invalid-response", None, status_code)
    if 200 <= status_code <= 299:
        return "invalid-response", None, status_code
    if status_code in TRANSIENT_HTTP or 500 <= status_code <= 599:
        return f"transient-http-{status_code}", None, status_code
    return f"http-{status_code}", None, status_code


def retry_settings() -> tuple[int, float, float]:
    try:
        retries = int(os.environ.get("FM_CIPHER_RETRIES", "3"))
    except ValueError:
        retries = 3
    retries = min(max(retries, 1), 5)
    try:
        timeout = float(os.environ.get("FM_CIPHER_TIMEOUT_SECS", "3"))
    except ValueError:
        timeout = 3.0
    timeout = min(max(timeout, 0.1), 10.0)
    try:
        delay = float(os.environ.get("FM_CIPHER_RETRY_DELAY_SECS", "0.25"))
    except ValueError:
        delay = 0.25
    delay = min(max(delay, 0.0), 2.0)
    return retries, timeout, delay


def deliver(kind: str, task_id: str, argument: str | None) -> int:
    payload = identity_for_event(kind, task_id, argument)
    dirs = record_dirs()
    payload = adopt_recorded_request(dirs, payload)
    body = store_request(dirs, payload)
    try:
        config = load_config(kind)
    except RouteDisabled:
        return 3
    except HookError as exc:
        write_hold(dirs, payload, exc.reason)
        return 1
    try:
        if valid_ack(dirs, payload, config):
            clear_hold(dirs, payload["request_id"])
            return 0
    except HookError as exc:
        write_hold(dirs, payload, exc.reason)
        return 1

    retries, timeout, delay = retry_settings()
    total_attempts = sent_attempts(dirs, payload["request_id"])
    final_reason = "unavailable"
    for attempt in range(retries):
        result, ack, http_status = post_once(
            config, body, payload["request_id"], payload["event_type"], timeout
        )
        total_attempts += 1
        write_sent(dirs, payload["request_id"], total_attempts, result)
        if result in {"accepted", "duplicate"} and ack is not None and http_status is not None:
            record = {
                "schema": DELIVERY_ACK_SCHEMA,
                "request_id": payload["request_id"],
                "event_type": payload["event_type"],
                "endpoint": config["endpoint"],
                "route_name": config["route_name"],
                "config_fingerprint": config["fingerprint"],
                "http_status": http_status,
                "gateway_ack": ack,
            }
            atomic_write(
                dirs["acks"] / f"{payload['request_id']}.json",
                json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8"),
            )
            clear_hold(dirs, payload["request_id"])
            return 0
        final_reason = result
        if result not in {"timeout", "unavailable"} and not result.startswith("transient-http-"):
            break
        if attempt + 1 < retries:
            time.sleep(delay)
    if final_reason.startswith("transient-http-"):
        final_reason = final_reason.removeprefix("transient-")
    write_hold(dirs, payload, final_reason)
    return 1


def retry_plan() -> int:
    """Plan supervision retries for transiently held deliveries.

    A transient hold whose recorded event still matches the task's current
    identity prints one "retry" line for the shell entrypoint to redeliver
    through the ordinary preflighted trigger path, which adopts the recorded
    request so the exact body and request ID are retried. A transient hold
    whose task records are gone or whose identity has been replaced by a newer
    event is durably marked superseded instead and never retried again.
    Non-transient holds and unreadable records are left untouched.
    """
    dirs = record_dirs()
    for path in sorted(dirs["holds"].glob("*.json")):
        request_id = path.name.removesuffix(".json")
        if not REQUEST_RE.fullmatch(request_id):
            continue
        try:
            hold = read_hold(dirs, request_id)
            if hold is None or not transient_hold_reason(hold["reason"]):
                continue
            request = read_json_record(dirs["requests"] / f"{request_id}.json")
            if request is None:
                continue
            validate_payload(request)
            if request["request_id"] != request_id:
                continue
        except HookError:
            continue
        kind = request["event_type"]
        argument = request["decision_id"] if kind == "needs-decision" else request["pr_url"]
        if argument is None:
            continue
        try:
            current = identity_for_event(kind, request["task_id"], argument)
        except HookError as exc:
            write_hold(dirs, request, SUPERSEDED_PREFIX + exc.reason)
            print(f"superseded {request_id} ({exc.reason})")
            continue
        if current["request_id"] != request_id:
            write_hold(dirs, request, SUPERSEDED_PREFIX + "identity-advanced")
            print(f"superseded {request_id} (identity-advanced)")
            continue
        print(f"retry {request_id} {kind} {request['task_id']} {argument}")
    return 0


def supersede(request_id: str, why: str) -> None:
    if not REQUEST_RE.fullmatch(request_id):
        raise HookError("invalid-request-id", usage=True)
    if not SUPERSEDE_REASON_RE.fullmatch(why):
        raise HookError("invalid-supersede-reason", usage=True)
    dirs = record_dirs()
    hold = read_hold(dirs, request_id)
    if hold is None:
        raise HookError("hold-record-missing")
    if not transient_hold_reason(hold["reason"]):
        raise HookError("hold-not-transient")
    marker = {"request_id": request_id, "event_type": hold["event_type"]}
    write_hold(dirs, marker, SUPERSEDED_PREFIX + why)


def validated_request_record(dirs: dict[str, Path], request_id: str) -> dict[str, Any]:
    if not REQUEST_RE.fullmatch(request_id):
        raise HookError("invalid-request-id", usage=True)
    record = read_json_record(dirs["requests"] / f"{request_id}.json")
    if record is None:
        raise HookError("request-record-missing")
    validate_payload(record)
    if record["request_id"] != request_id or canonical_body(record) != regular_file(
        dirs["requests"] / f"{request_id}.json", MAX_BODY, mode_600=True
    ):
        raise HookError("state-record-invalid")
    ack = read_json_record(dirs["acks"] / f"{request_id}.json")
    if ack is None:
        raise HookError("merge-ack-missing")
    if not stored_ack_valid(ack, record):
        raise HookError("state-record-invalid")
    return record


def receive_identity(kind: str, task_id: str, request_id: str, comment_url: str) -> tuple[str, dict[str, Any]]:
    validate_task(task_id)
    if kind not in {"decision-comment", "pr-blocker"}:
        raise HookError("invalid-receive-kind", usage=True)
    match = COMMENT_RE.fullmatch(comment_url)
    if not match:
        raise HookError("invalid-comment-url", usage=True)
    comment_repo = canonical_repo(match.group(1), match.group(2))
    dirs = record_dirs()
    request = validated_request_record(dirs, request_id)
    if request["task_id"] != task_id:
        raise HookError("receive-task-mismatch")
    expected_event = "needs-decision" if kind == "decision-comment" else "iinvy-pr-ready"
    if request["event_type"] != expected_event:
        raise HookError("receive-event-mismatch")
    allowed_repos = {request["repository"]}
    for field, parser in (("issue_url", parse_issue), ("pr_url", parse_pr)):
        value = request.get(field)
        if value:
            allowed_repos.add(parser(value)[0])
    if comment_repo not in allowed_repos:
        raise HookError("receive-repository-mismatch")
    logical = f"{kind}\0{task_id}\0{request_id}\0{comment_url}".encode("ascii")
    receive_id = "fmcr-v1-" + hashlib.sha256(logical).hexdigest()
    record = {
        "schema": "firstmate.cipher-hook-receive.v1",
        "receive_id": receive_id,
        "kind": kind,
        "task_id": task_id,
        "request_id": request_id,
        "comment_url": comment_url,
    }
    return receive_id, record


def prepare_receive(kind: str, task_id: str, request_id: str, comment_url: str) -> tuple[str, bool]:
    receive_id, record = receive_identity(kind, task_id, request_id, comment_url)
    dirs = record_dirs()
    existing = read_json_record(dirs["received"] / f"{receive_id}.json")
    if existing is not None:
        if existing != record:
            raise HookError("state-record-invalid")
        return receive_id, True
    return receive_id, False


def commit_receive(kind: str, task_id: str, request_id: str, comment_url: str) -> str:
    receive_id, record = receive_identity(kind, task_id, request_id, comment_url)
    dirs = record_dirs()
    path = dirs["received"] / f"{receive_id}.json"
    existing = read_json_record(path)
    if existing is not None and existing != record:
        raise HookError("state-record-invalid")
    if existing is None:
        atomic_write(path, json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    return receive_id


def resolve_decision_plan(task_id: str, request_id: str) -> tuple[str, str]:
    """Plan the durable closure of a Cipher-answered keyed decision.

    Requires the acknowledged needs-decision request for this task plus the
    committed authenticated decision-comment receive record bound to it, so a
    keyed decision can never be closed as Cipher-answered unless the durable
    GitHub answer actually arrived. Returns the decision id and the exact
    comment URL Cipher wrote.
    """
    validate_task(task_id)
    dirs = record_dirs()
    request = validated_request_record(dirs, request_id)
    if request["task_id"] != task_id:
        raise HookError("receive-task-mismatch")
    if request["event_type"] != "needs-decision":
        raise HookError("receive-event-mismatch")
    decision_id = request["decision_id"]
    if not isinstance(decision_id, str) or not decision_id:
        raise HookError("state-record-invalid")
    for path in sorted(dirs["received"].glob("*.json")):
        record = read_json_record(path)
        if record is None:
            continue
        if (
            record.get("kind") == "decision-comment"
            and record.get("task_id") == task_id
            and record.get("request_id") == request_id
            and isinstance(record.get("comment_url"), str)
        ):
            return decision_id, record["comment_url"]
    raise HookError("decision-comment-missing")


def verify_merge(task_id: str, pr_url: str, request_id: str) -> str:
    if not REQUEST_RE.fullmatch(request_id):
        raise HookError("merge-authorization-missing")
    payload = identity_for_event("iinvy-pr-ready", task_id, pr_url)
    if payload["request_id"] != request_id:
        raise HookError("merge-authorization-mismatch")
    config = load_config("iinvy-pr-ready")
    dirs = record_dirs()
    store_request(dirs, payload)
    if not valid_ack(dirs, payload, config):
        raise HookError("merge-ack-missing")
    head = payload["pr_head_sha"]
    if not isinstance(head, str) or not SHA_RE.fullmatch(head):
        raise HookError("missing-pr-head")
    return head


def emit_error(exc: HookError) -> int:
    if exc.usage:
        print("error: invalid Cipher hook request", file=sys.stderr)
        return 2
    print(f"error: Cipher hook refused: {diagnostic_message(exc.reason)}", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print(
            "usage: fm-cipher-hook.py repo-gated <owner/repo> | "
            "deliver <needs-decision|iinvy-pr-ready> <task-id> [decision-id|pr-url] | "
            "retry-plan | "
            "supersede <request-id> <reason> | "
            "verify-merge <task-id> <pr-url> <request-id> | "
            "resolve-decision <task-id> <request-id> | "
            "prepare-receive <kind> <task-id> <request-id> <comment-url> | "
            "commit-receive <kind> <task-id> <request-id> <comment-url> | "
            "request-id <task-id> <pr-url>"
        )
        return 0 if argv else 2
    command = argv[0]
    try:
        if command == "repo-gated" and len(argv) == 2:
            raw = argv[1]
            if raw.count("/") != 1:
                return 1
            owner, repo = raw.split("/", 1)
            return 0 if canonical_repo(owner, repo) in gated_repos() else 1
        if command == "deliver" and len(argv) in {3, 4}:
            kind = argv[1]
            argument = argv[3] if len(argv) == 4 else None
            return deliver(kind, argv[2], argument)
        if command == "retry-plan" and len(argv) == 1:
            return retry_plan()
        if command == "supersede" and len(argv) == 3:
            supersede(argv[1], argv[2])
            return 0
        if command == "verify-merge" and len(argv) == 4:
            print(verify_merge(argv[1], argv[2], argv[3]))
            return 0
        if command == "resolve-decision" and len(argv) == 3:
            decision_id, comment_url = resolve_decision_plan(argv[1], argv[2])
            print(f"{decision_id} {comment_url}")
            return 0
        if command == "prepare-receive" and len(argv) == 5:
            receive_id, duplicate = prepare_receive(argv[1], argv[2], argv[3], argv[4])
            print(receive_id)
            return 3 if duplicate else 0
        if command == "commit-receive" and len(argv) == 5:
            print(commit_receive(argv[1], argv[2], argv[3], argv[4]))
            return 0
        if command == "request-id" and len(argv) == 3:
            payload = identity_for_event("iinvy-pr-ready", argv[1], argv[2])
            print(payload["request_id"])
            return 0
        raise HookError("invalid-command", usage=True)
    except RouteDisabled as exc:
        return emit_error(exc)
    except HookError as exc:
        return emit_error(exc)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
