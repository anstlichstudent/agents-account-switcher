"""Check the account cache without calling 9Router or switching accounts."""

import json
from pathlib import Path
import runpy
from subprocess import CompletedProcess
from tempfile import TemporaryDirectory
from unittest.mock import patch

refresh = runpy.run_path(str(Path(__file__).with_name("account-cache.py")))["refresh"]
accounts = [{"id": "a", "name": "A", "active": True},
            {"id": "b", "name": "B", "active": False}]

with TemporaryDirectory() as directory, patch("subprocess.run") as fetch:
    path = Path(directory) / "agy.json"
    fetch.return_value = CompletedProcess([], 0, json.dumps({"accounts": accounts}))
    refresh(path, "agy", 60, None)
    refresh(path, "agy", 60, None)
    fetch.assert_called_once()

    refresh(path, "agy", 0, None)
    assert fetch.call_count == 2
    saved = json.loads(path.read_text())
    assert path.stat().st_mode & 0o777 == 0o600

    fetch.return_value = CompletedProcess([], 0, '{"accounts":[{"quotaError":true}]}')
    for active in (None, "b"):
        try:
            refresh(path, "agy", 0, active)
        except ValueError:
            data = json.loads(path.read_text())
            assert data["updatedAt"] == saved["updatedAt"]
            assert [a["id"] for a in data["accounts"] if a["active"]] == [active or "a"]
        else:
            raise AssertionError("Quota failure should leave the previous snapshot")

with TemporaryDirectory() as directory, patch("subprocess.run") as fetch:
    path = Path(directory) / "codex.json"
    fetch.return_value = CompletedProcess([], 0, '{"accounts":[{"name":"A"}]}')
    refresh(path, "codex", 60, None)
    fetch.return_value = CompletedProcess([], 0, '{"accounts":[{"id":"a","name":"A"}]}')
    refresh(path, "codex", 60, None)
    assert json.loads(path.read_text())["accounts"][0]["id"] == "a"
    assert fetch.call_count == 2


print("Account cache checks passed.")
