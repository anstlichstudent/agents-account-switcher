"""Refresh one provider's last successful account snapshot."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

PLUGIN = Path(__file__).resolve().parent
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "omarchy/account-switcher"
COMMANDS = {
    "codex": [sys.executable, str(PLUGIN / "codex-account.py"), "--status"],
    "agy": [sys.executable, str(PLUGIN / "agy-account.py"), "--status"],
}


def read_snapshot(path):
    try:
        value = json.loads(path.read_text())
        if (isinstance(value["accounts"], list)
                and all(isinstance(account, dict) for account in value["accounts"])
                and type(value["updatedAt"]) is int):
            return value
    except (OSError, ValueError, TypeError, KeyError):
        pass
    return {"accounts": [], "updatedAt": 0}


def write_snapshot(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        pending = Path(stream.name)
        try:
            json.dump(value, stream)
            stream.close()
            pending.replace(path)
        finally:
            pending.unlink(missing_ok=True)


def refresh(path, provider, max_age, active):
    previous = read_snapshot(path)
    if active is not None and previous["accounts"]:
        for account in previous["accounts"]:
            account["active"] = account.get("id") == active
        write_snapshot(path, previous)
    age = time.time() * 1000 - previous["updatedAt"]
    if (active is None and 0 <= age < max_age * 1000
            and all(isinstance(account.get("id"), str) for account in previous["accounts"])):
        return
    result = subprocess.run(COMMANDS[provider], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ValueError("Account status command failed.")
    data = json.loads(result.stdout)
    if not isinstance(data, dict) or data.get("error") or not isinstance(data.get("accounts"), list):
        raise ValueError("Account status unavailable.")
    accounts = data["accounts"]
    if any(not isinstance(account, dict) or account.get("quotaError") for account in accounts):
        raise ValueError("One or more account quotas are unavailable.")
    write_snapshot(path, {"accounts": accounts, "updatedAt": int(time.time() * 1000)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("provider", choices=COMMANDS)
    parser.add_argument("--max-age", type=int, default=0)
    parser.add_argument("--active")
    args = parser.parse_args()
    try:
        CACHE.mkdir(parents=True, exist_ok=True)
        path = CACHE / (args.provider + ".json")
        with path.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            refresh(path, args.provider, args.max_age, args.active)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
