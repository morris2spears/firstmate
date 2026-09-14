#!/usr/bin/env python3
"""Canonical per-home Cipher repository registration store and CLI implementation."""

from __future__ import annotations

import fcntl
import json
import os
import re
import stat
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

SCHEMA = "firstmate.cipher-repositories.v1"
DEFAULT_REPOSITORIES = (
    "morris2spears/iinvy",
    "morris2spears/iinvy-storefront",
    "morris2spears/iinvy-control-plane",
    "morris2spears/cutbot",
    "morris2spears/hermes-agent-cutbot",
)
OWNER_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
REPO_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,98}[A-Za-z0-9])?$")
PR_RE = re.compile(
    r"^https://github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/"
    r"([A-Za-z0-9._-]{1,100})/pull/[1-9][0-9]*$"
)
MAX_REGISTRATION_BYTES = 64 * 1024
MAX_META_BYTES = 64 * 1024


class RegistrationError(Exception):
    """A registration source or operation could not be validated safely."""


@dataclass(frozen=True)
class RegistrationState:
    repositories: tuple[str, ...]
    source: str
    degraded: bool


def code_root() -> Path:
    return Path(__file__).resolve().parent.parent


def operational_paths() -> tuple[Path, Path]:
    root = Path(os.environ.get("FM_ROOT_OVERRIDE", str(code_root()))).resolve()
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", str(root)))).resolve()
    config = Path(os.environ.get("FM_CONFIG_OVERRIDE", str(home / "config"))).resolve()
    state = Path(os.environ.get("FM_STATE_OVERRIDE", str(home / "state"))).resolve()
    return config, state


def registration_paths() -> tuple[Path, Path, Path, Path]:
    config, _ = operational_paths()
    return (
        config / "cipher-repositories.json",
        config / "cipher-repositories.last-good.json",
        config / "cipher-repositories.rollback.json",
        config / ".cipher-repositories.lock",
    )


def canonical_repository(raw: str) -> str:
    if not isinstance(raw, str) or raw.count("/") != 1:
        raise RegistrationError("repository must be an exact owner/repo name")
    owner, repo = raw.split("/", 1)
    if not OWNER_RE.fullmatch(owner) or "--" in owner:
        raise RegistrationError("repository owner is malformed")
    if not REPO_RE.fullmatch(repo) or repo in {".", ".."}:
        raise RegistrationError("repository name is malformed")
    return f"{owner}/{repo}".lower()


def _regular_bytes(path: Path, maximum: int) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except FileNotFoundError as exc:
        raise RegistrationError(f"registration file is missing: {path}") from exc
    except OSError as exc:
        raise RegistrationError(f"registration file is unreadable: {path}") from exc
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_size > maximum
        ):
            raise RegistrationError(f"registration file is unsafe: {path}")
        data = bytearray()
        while len(data) <= maximum:
            chunk = os.read(fd, min(65536, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
    finally:
        os.close(fd)
    if len(data) > maximum:
        raise RegistrationError(f"registration file is oversized: {path}")
    return bytes(data)


def _decode_document(path: Path) -> tuple[str, ...]:
    raw = _regular_bytes(path, MAX_REGISTRATION_BYTES)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RegistrationError(f"registration file is malformed: {path}") from exc
    if not isinstance(value, dict) or set(value) != {"schema", "repositories"}:
        raise RegistrationError(f"registration schema is invalid: {path}")
    if value["schema"] != SCHEMA or not isinstance(value["repositories"], list):
        raise RegistrationError(f"registration schema is unsupported: {path}")
    repositories: list[str] = []
    seen: set[str] = set()
    for raw_repo in value["repositories"]:
        if not isinstance(raw_repo, str):
            raise RegistrationError(f"registration entry is invalid: {path}")
        canonical = canonical_repository(raw_repo)
        if canonical != raw_repo:
            raise RegistrationError(f"registration entry is not normalized: {path}")
        if canonical in seen:
            raise RegistrationError(f"registration entry is duplicated: {path}")
        seen.add(canonical)
        repositories.append(canonical)
    if not repositories:
        raise RegistrationError(f"registration set must not be empty: {path}")
    return tuple(repositories)


def _path_present(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def _load_unlocked() -> RegistrationState:
    current, last_good, rollback, _ = registration_paths()
    current_present = _path_present(current)
    last_good_present = _path_present(last_good)
    if not current_present and not last_good_present:
        if _path_present(rollback):
            raise RegistrationError("managed repository registration files are missing")
        return RegistrationState(DEFAULT_REPOSITORIES, "built-in-defaults", False)
    if current_present:
        try:
            return RegistrationState(_decode_document(current), "primary", False)
        except RegistrationError as current_error:
            if not last_good_present:
                raise current_error
    try:
        return RegistrationState(_decode_document(last_good), "last-known-good", True)
    except RegistrationError as fallback_error:
        raise RegistrationError(
            "primary registration is unavailable and last-known-good recovery failed: "
            f"{fallback_error}"
        ) from fallback_error


def _config_directory() -> Path:
    config, _ = operational_paths()
    try:
        info = config.lstat()
    except FileNotFoundError as exc:
        raise RegistrationError(f"configuration directory is missing: {config}") from exc
    if not stat.S_ISDIR(info.st_mode) or config.is_symlink():
        raise RegistrationError(f"configuration directory is unsafe: {config}")
    return config


@contextmanager
def registration_lock(*, exclusive: bool, inheritable: bool = False) -> Iterator[None]:
    _config_directory()
    _, _, _, lock_path = registration_paths()
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(lock_path, flags, 0o600)
    except OSError as exc:
        raise RegistrationError("repository registration lock is unavailable") from exc
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            raise RegistrationError("repository registration lock is unsafe")
        fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        if inheritable:
            os.set_inheritable(fd, True)
        yield
    finally:
        os.close(fd)


def load_registration_state() -> RegistrationState:
    config, _ = operational_paths()
    if not config.exists() and not config.is_symlink():
        return RegistrationState(DEFAULT_REPOSITORIES, "built-in-defaults", False)
    with registration_lock(exclusive=False):
        return _load_unlocked()


def registered_repositories() -> frozenset[str]:
    return frozenset(load_registration_state().repositories)


def repository_registered(raw: str) -> bool:
    return canonical_repository(raw) in registered_repositories()


def _document(repositories: tuple[str, ...]) -> bytes:
    value = {"schema": SCHEMA, "repositories": list(repositories)}
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")


def _safe_destination(path: Path) -> None:
    if not _path_present(path):
        return
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
        raise RegistrationError(f"registration destination is unsafe: {path}")


def _atomic_write(path: Path, data: bytes) -> None:
    _safe_destination(path)
    fd, temporary = tempfile.mkstemp(prefix=".cipher-repositories.", dir=str(path.parent))
    temporary_path = Path(temporary)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        _safe_destination(path)
        os.replace(temporary_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def _commit(repositories: tuple[str, ...], previous: tuple[str, ...]) -> None:
    current, last_good, rollback, _ = registration_paths()
    protective = tuple(dict.fromkeys(previous + repositories))
    _atomic_write(rollback, _document(previous))
    # Publish the conservative recovery set before the new primary. A crash can
    # therefore over-protect a removed repository, but can never expose one
    # added by a completed primary write without a recovery registration.
    _atomic_write(last_good, _document(protective))
    _atomic_write(current, _document(repositories))


def add_repository(raw: str) -> tuple[str, bool]:
    repository = canonical_repository(raw)
    with registration_lock(exclusive=True):
        state = _load_unlocked()
        if repository in state.repositories:
            return repository, False
        updated = state.repositories + (repository,)
        _commit(updated, state.repositories)
    return repository, True


def _meta_repository(path: Path) -> str | None:
    raw = _regular_bytes(path, MAX_META_BYTES)
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise RegistrationError(f"task metadata is malformed: {path}") from exc
    pr_values = [line[3:] for line in lines if line.startswith("pr=")]
    if len(pr_values) != 1:
        return None
    match = PR_RE.fullmatch(pr_values[0])
    if not match:
        return None
    return canonical_repository(f"{match.group(1)}/{match.group(2)}")


def _inflight_tasks(repository: str) -> tuple[str, ...]:
    _, state_dir = operational_paths()
    if not state_dir.exists() or not state_dir.is_dir() or state_dir.is_symlink():
        raise RegistrationError(f"state directory is unavailable: {state_dir}")
    tasks: list[str] = []
    for path in state_dir.glob("*.meta"):
        if path.is_symlink():
            raise RegistrationError(f"task metadata is unsafe: {path}")
        if _meta_repository(path) == repository:
            tasks.append(path.stem)
    return tuple(sorted(tasks))


def remove_repository(raw: str) -> tuple[str, bool]:
    repository = canonical_repository(raw)
    with registration_lock(exclusive=True):
        state = _load_unlocked()
        if repository not in state.repositories:
            return repository, False
        inflight = _inflight_tasks(repository)
        if inflight:
            raise RegistrationError(
                f"repository has in-flight gated work ({', '.join(inflight)}); "
                "finish or clean it up before removal"
            )
        updated = tuple(item for item in state.repositories if item != repository)
        if not updated:
            raise RegistrationError("the final repository registration cannot be removed")
        _commit(updated, state.repositories)
    return repository, True


def rollback() -> tuple[str, ...]:
    with registration_lock(exclusive=True):
        state = _load_unlocked()
        _, _, rollback_path, _ = registration_paths()
        if not _path_present(rollback_path):
            raise RegistrationError("no repository registration rollback is available")
        previous = _decode_document(rollback_path)
        _commit(previous, state.repositories)
        return previous


def inspect_document() -> dict[str, object]:
    state = load_registration_state()
    current, last_good, rollback_path, _ = registration_paths()
    return {
        "schema": SCHEMA,
        "effective_source": state.source,
        "degraded": state.degraded,
        "repositories": list(state.repositories),
        "paths": {
            "primary": str(current),
            "last_known_good": str(last_good),
            "rollback": str(rollback_path),
        },
    }


def usage() -> str:
    return (
        "usage: fm-cipher-repositories.sh <list|inspect|validate> [--json] | "
        "fm-cipher-repositories.sh <add|remove|contains> <owner/repo> | "
        "fm-cipher-repositories.sh rollback | "
        "fm-cipher-repositories.sh hold-shared-exec -- <command> [args...]"
    )


def main(argv: list[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print(usage())
        return 0 if argv else 2
    command = argv[0]
    try:
        if command == "hold-shared-exec" and len(argv) >= 3 and argv[1] == "--":
            with registration_lock(exclusive=False, inheritable=True):
                os.execvp(argv[2], argv[2:])
            return 1
        if command == "contains" and len(argv) == 2:
            return 0 if repository_registered(argv[1]) else 1
        if command in {"list", "inspect", "validate"} and argv[1:] in ([], ["--json"]):
            document = inspect_document()
            if command == "list" and argv[1:] != ["--json"]:
                print("\n".join(document["repositories"]))
            elif command == "validate" and argv[1:] != ["--json"]:
                print(
                    f"valid: {len(document['repositories'])} repositories "
                    f"(source={document['effective_source']}, "
                    f"degraded={str(document['degraded']).lower()})"
                )
            else:
                print(json.dumps(document, sort_keys=True))
            return 0
        if command == "add" and len(argv) == 2:
            repository, changed = add_repository(argv[1])
            print(f"{'registered' if changed else 'already registered'}: {repository}")
            return 0
        if command == "remove" and len(argv) == 2:
            repository, changed = remove_repository(argv[1])
            print(f"{'removed' if changed else 'not registered'}: {repository}")
            return 0
        if command == "rollback" and len(argv) == 1:
            repositories = rollback()
            print(f"rolled back: {len(repositories)} repositories")
            return 0
        print(usage(), file=sys.stderr)
        return 2
    except RegistrationError as exc:
        print(f"error: Cipher repository registration refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
