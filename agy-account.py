#!/usr/bin/env python3
"""Switch the local AGY keyring entry using an Antigravity account from 9Router."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

from router_usage import account_usage, quota_windows

DATABASE = Path.home() / ".9router/db/data.sqlite"
KEYRING = ("service", "gemini", "username", "antigravity")
PROVIDER = "provider = 'antigravity' AND authType = 'oauth' AND isActive = 1"


class AccountError(Exception):
    pass


class AgyRunning(AccountError):
    pass


def keyring(command, *args, payload=None):
    return subprocess.run(
        ["/usr/bin/secret-tool", command, *args, *KEYRING],
        input=payload if payload is not None else b"",
        capture_output=True,
        timeout=10,
    )


def current():
    result = keyring("lookup")
    if result.returncode:
        raise AccountError("AGY keyring credential is unavailable. Unlock the keyring and sign in to AGY first.")
    try:
        credential = json.loads(result.stdout)
        if not isinstance(credential["token"]["access_token"], str):
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise AccountError("AGY keyring credential has an unsupported format.") from None
    return credential


def store(credential):
    result = keyring(
        "store", "--label=Password for 'antigravity' on 'gemini'",
        payload=json.dumps(credential).encode(),
    )
    if result.returncode or current() != credential:
        raise AccountError("Could not verify the AGY keyring credential.")


def gemini_quotas(identifier):
    try:
        usage = account_usage(identifier)
    except (OSError, ValueError):
        return None
    return quota_windows(usage, (("session", "gemini_session"), ("weekly", "gemini_weekly")))


def status(database):
    active_email = str(current().get("id_token_email") or "").casefold()
    rows = database.execute(
        f"SELECT id, name, email FROM providerConnections WHERE {PROVIDER} ORDER BY priority, createdAt LIMIT 100"
    ).fetchall()
    accounts = [
        {
            "id": identifier,
            "name": (email or name or identifier)[:200],
            "active": bool(email and email.casefold() == active_email),
        }
        for identifier, name, email in rows
    ]
    with ThreadPoolExecutor(max_workers=4) as pool:
        quotas = pool.map(lambda row: gemini_quotas(row["id"]), accounts)
        for account, windows in zip(accounts, quotas, strict=True):
            account["quotas"] = windows or {}
            if windows is None:
                account["quotaError"] = True
    return {"accounts": accounts}


def require_closed():
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            if (process / "comm").read_text(errors="replace").strip() == "agy":
                raise AgyRunning("Close all AGY sessions before switching accounts.")
            executable = os.readlink(process / "exe").removesuffix(" (deleted)")
            if Path(executable).name == "agy":
                raise AgyRunning("Close all AGY sessions before switching accounts.")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue


def swap(database, identifier):
    require_closed()
    row = database.execute(
        f"SELECT email, data FROM providerConnections WHERE {PROVIDER} AND id = ?",
        (identifier,),
    ).fetchone()
    if row is None:
        raise AccountError("Antigravity account is no longer available in 9Router.")
    email, raw = row
    data = json.loads(raw)
    access = data.get("accessToken")
    refresh = data.get("refreshToken")
    if not all(isinstance(value, str) and value.strip() for value in (email, access, refresh)):
        raise AccountError("The 9Router Antigravity connection has incomplete credentials.")
    try:
        expiry = datetime.fromisoformat(data["expiresAt"].replace("Z", "+00:00"))
        if expiry.tzinfo is None:
            raise ValueError()
    except (KeyError, AttributeError, TypeError, ValueError):
        raise AccountError("The 9Router Antigravity connection has an invalid expiry.") from None

    previous = current()
    credential = {
        "token": {
            "access_token": access,
            "refresh_token": refresh,
            "token_type": "Bearer",
            "expiry": expiry.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "expires_in": max(0, int((expiry - datetime.now(timezone.utc)).total_seconds())),
        },
        "auth_method": "consumer",
        "id_token_email": email,
    }
    require_closed()
    try:
        store(credential)
    except (AccountError, OSError, subprocess.SubprocessError):
        try:
            store(previous)
        except (AccountError, OSError, subprocess.SubprocessError):
            raise AccountError("AGY account switch failed. The previous keyring credential could not be verified.") from None
        raise AccountError("AGY account switch failed. The previous keyring credential was restored.") from None


def main():
    parser = argparse.ArgumentParser()
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--status", action="store_true")
    operation.add_argument("--swap")
    args = parser.parse_args()
    try:
        with closing(sqlite3.connect(f"{DATABASE.as_uri()}?mode=ro", uri=True, timeout=5)) as database:
            if args.status:
                print(json.dumps(status(database)))
            else:
                lock_path = Path(f"/run/user/{os.getuid()}/omarchy-agy-account.lock")
                with lock_path.open("a") as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        raise AccountError("Another AGY account switch is in progress.") from None
                    swap(database, args.swap)
    except AgyRunning as error:
        print(error, file=sys.stderr)
        return 3
    except AccountError as error:
        print(error, file=sys.stderr)
        return 1
    except (sqlite3.Error, OSError, ValueError, subprocess.SubprocessError):
        print("Could not read 9Router or access the AGY keyring.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
