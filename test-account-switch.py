"""Check the packaged account helpers with temporary data."""

import base64
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
from unittest.mock import patch

from router_usage import account_usage, quota_windows

PLUGIN = Path(__file__).resolve().parent
codex = runpy.run_path(str(PLUGIN / 'codex-account.py'))
agy = runpy.run_path(str(PLUGIN / 'agy-account.py'))

with TemporaryDirectory() as directory:
    home = Path(directory)
    database = home / '.9router/db/data.sqlite'
    database.parent.mkdir(parents=True)
    connection = sqlite3.connect(database)
    connection.execute('CREATE TABLE providerConnections '
                       '(id, provider, authType, data, priority, createdAt)')
    claims = {'email': '<img src="https://example.invalid/logo">',
              'iss': 'https://auth.openai.com', 'aud': 'test-client'}
    encoded = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode()
    credential = {'idToken': f'test.{encoded}.signature', 'accessToken': 'test-access',
                  'refreshToken': 'test-refresh',
                  'providerSpecificData': {'chatgptAccountId': 'test-account'}}
    connection.execute('INSERT INTO providerConnections VALUES (?, ?, ?, ?, ?, ?)',
                       ('test-id', 'codex', 'oauth', json.dumps(credential), 1, ''))
    connection.commit()
    connection.close()

    swap = codex['swap']
    profile = home / 'test-profile'
    with patch.dict(swap.__globals__, {'CODEX_HOME': profile,
                                       'require_closed': lambda: None}), \
         patch.dict(codex['accounts'].__globals__, {'DATABASE': database}):
        account, = codex['accounts']()
        assert account['client'] == 'test-client'
        swap(account)
        stored = profile / 'auth.json'
        assert stored.stat().st_mode & 0o777 == 0o600
        before = stored.read_bytes()
        assert json.loads(before)['tokens']['account_id'] == 'test-account'

        def busy():
            raise RuntimeError('Codex is running.')

        with patch.dict(swap.__globals__, {'require_closed': busy}):
            try:
                swap(account)
            except RuntimeError:
                assert stored.read_bytes() == before
            else:
                raise AssertionError('A live session must prevent a switch')

        usage = {'quotas': {'session': {'used': 2, 'total': 3, 'secret': 'omit-me'}},
                 'resetCredits': {'availableCount': 2}}
        with patch.dict(codex['status'].__globals__, {'account_usage': lambda _: usage}):
            row, = codex['status']()['accounts']
            assert row['id'] == 'test-id' and row['active']
            assert row['name'] == claims['email']
            assert row['resetCreditsAvailable'] == 2
            assert row['quotas'] == {'session': {'used': 2, 'total': 3}}
            assert 'test-access' not in json.dumps(row)

    connection = sqlite3.connect(database)
    connection.execute('DELETE FROM providerConnections')
    connection.commit()
    connection.close()
    env = {**os.environ, 'HOME': str(home), 'CODEX_HOME': str(profile),
           'XDG_CACHE_HOME': str(home / 'cache')}
    subprocess.run([sys.executable, str(PLUGIN / 'account-cache.py'), 'codex'],
                   cwd=home, env=env, check=True)
    snapshot = home / 'cache/omarchy/account-switcher/codex.json'
    assert json.loads(snapshot.read_text())['accounts'] == []

    router = home / '.9router'
    (router / 'auth').mkdir()
    (router / 'machine-id').write_text('test-machine')
    (router / 'auth/cli-secret').write_text('test-cli-secret')
    with patch('router_usage.ROOT', router), patch('router_usage.HTTPConnection') as http:
        client = http.return_value
        response = client.getresponse.return_value
        response.__enter__.return_value.status = 200
        response.__enter__.return_value.read.return_value = b'{"quotas":{}}'
        assert account_usage('test-id') == {'quotas': {}}
        http.assert_called_once_with('127.0.0.1', 20128, timeout=25)
        assert client.request.call_args.args == ('GET', '/api/usage/test-id')
        for invalid in ('../other', 'test?foo=bar'):
            try:
                account_usage(invalid)
            except ValueError:
                pass
            else:
                raise AssertionError('Use only valid connection identifiers')
        response.__enter__.return_value.status = 302
        try:
            account_usage('test-id')
        except ValueError:
            assert http.call_count == 2
        else:
            raise AssertionError('Never follow a 9Router redirect')

assert quota_windows({'quotas': {'weekly': {'used': float('nan'), 'total': 1}}},
                     [('weekly', 'weekly')]) == {}
with patch.dict(agy['gemini_quotas'].__globals__, {
        'account_usage': lambda _: {'quotas': {'gemini_weekly': {'used': 1, 'total': 5}}}}):
    assert agy['gemini_quotas']('test-id') == {'weekly': {'used': 1, 'total': 5}}

print('Packaged account helper checks passed.')
