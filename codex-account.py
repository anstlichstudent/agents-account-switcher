"""List and switch local Codex accounts from 9Router."""

import argparse
import base64
from contextlib import closing
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile

from router_usage import account_usage, quota_windows

ROOT_R = Path.home() / '.9router'
DATABASE = ROOT_R / 'db/data.sqlite'
CODEX_HOME = Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex').expanduser().resolve()
OPENAI_AUTH = 'https://api.openai.com/auth'


def decode(token):
    try:
        body = str(token or '').split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(body + '=' * (-len(body) % 4)))
        return claims if isinstance(claims, dict) else {}
    except (IndexError, ValueError):
        return {}


def moment(value):
    try:
        parsed = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def accounts():
    query = ('SELECT id, data FROM providerConnections WHERE provider = ? AND authType = ? '
             'ORDER BY priority, createdAt LIMIT 100')
    with closing(sqlite3.connect(f'{DATABASE.as_uri()}?mode=ro', uri=True)) as database:
        rows = [(json.loads(raw), identifier)
                for identifier, raw in database.execute(query, ('codex', 'oauth'))]
    result, seen = [], {}
    for data, identifier in rows:
        claims = decode(data.get('idToken'))
        auth = claims.get(OPENAI_AUTH) or {}
        metadata = data.get('providerSpecificData') or {}
        account_id = metadata.get('chatgptAccountId') or auth.get('chatgpt_account_id') or ''
        email = claims.get('email') or ''
        key = account_id or email
        if not key:
            print('Skipping a Codex connection without an account identity.', file=sys.stderr)
            continue
        seen[key] = seen.get(key, 0) + 1
        name = email or account_id
        audience = claims.get('aud')
        result.append({
            'id': account_id, 'identifier': identifier,
            'name': (f'{name[:180]} ({seen[key]})' if seen[key] > 1 else name[:180]),
            'plan': str(metadata.get('chatgptPlanType') or auth.get('chatgpt_plan_type') or 'unknown plan')[:40],
            'access': str(data.get('accessToken') or ''), 'refresh': str(data.get('refreshToken') or ''),
            'id_token': str(data.get('idToken') or ''), 'refreshed': data.get('lastRefreshAt'),
            'issuer': claims.get('iss') or 'https://auth.openai.com',
            'client': audience if isinstance(audience, str) else (audience or [''])[0]
        })
    return result


def auth_for(account, base):
    """The account's Codex auth.json, keeping whatever newer tokens ~/.codex already holds."""
    tokens = {'access_token': account['access'], 'refresh_token': account['refresh'],
              'id_token': account['id_token'], 'account_id': account['id'],
              'oauth_provenance': {'issuer': account['issuer'], 'client_id': account['client']}}
    stored = base / 'auth.json'
    try:
        old = json.loads(stored.read_text())
        if old.get('tokens', {}).get('account_id') == account['id']:
            stored_at = moment(old.get('last_refresh'))
            if stored_at and moment(account['refreshed']) and stored_at >= moment(account['refreshed']):
                # Codex refreshed this same account after 9Router did: keep that pair.
                tokens.update({key: value for key, value in old['tokens'].items()
                               if key in tokens and value})
    except (OSError, ValueError):
        pass
    return {'auth_mode': 'chatgpt', 'OPENAI_API_KEY': None, 'tokens': tokens,
            'last_refresh': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')}


def status():
    """Every Codex account 9Router holds, with its windows and whether ~/.codex uses it."""
    try:
        current = json.loads((CODEX_HOME / 'auth.json').read_text()).get('tokens', {}).get('account_id') or ''
    except (OSError, ValueError):
        current = ''
    listed = []
    for option in accounts():
        try:
            usage = account_usage(option['identifier'])
        except (OSError, ValueError, RuntimeError):
            return {'error': '9Router quota request failed.', 'accounts': []}
        windows = quota_windows(usage, (('session', 'session'), ('weekly', 'weekly')))
        credits = usage.get('resetCredits')
        available = credits.get('availableCount') if isinstance(credits, dict) else None
        listed.append({'id': option['identifier'], 'name': option['name'], 'plan': option['plan'],
                       'active': bool(current and option['id'] == current), 'quotas': windows,
                       'resetCreditsAvailable': available if type(available) is int and 0 <= available <= 1000000 else None})
    return {'accounts': listed}


def require_closed():
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            if (process / 'comm').read_text(errors='replace').strip() == 'codex':
                raise RuntimeError('Close all Codex sessions before switching accounts.')
            executable = Path(os.readlink(process / 'exe').removesuffix(' (deleted)')).name
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if executable == 'codex':
            raise RuntimeError('Close all Codex sessions before switching accounts.')


def swap(account):
    if not all(account[key] for key in ('id', 'access', 'refresh', 'id_token')):
        raise RuntimeError('The 9Router Codex connection has incomplete credentials.')
    require_closed()
    CODEX_HOME.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (CODEX_HOME / '.account-switcher.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        require_closed()
        value = auth_for(account, CODEX_HOME)
        with tempfile.NamedTemporaryFile('w', dir=CODEX_HOME, prefix='.auth-', delete=False) as stream:
            temporary = Path(stream.name)
            try:
                json.dump(value, stream)
                stream.close()
                temporary.replace(CODEX_HOME / 'auth.json')
            finally:
                temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument('--status', action='store_true')
    operation.add_argument('--swap', metavar='CONNECTION_ID')
    args = parser.parse_args()
    try:
        if args.status:
            print(json.dumps(status()))
        else:
            account = next((account for account in accounts() if account['identifier'] == args.swap), None)
            if account is None:
                raise RuntimeError('The Codex account is no longer available in 9Router.')
            swap(account)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    except (sqlite3.Error, OSError, ValueError, TypeError, KeyError):
        print('Could not read 9Router or update Codex credentials.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
