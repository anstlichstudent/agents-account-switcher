"""Read quota data from the local 9Router service."""

from datetime import datetime
import hashlib
from http.client import HTTPConnection, HTTPException
import json
import math
from pathlib import Path
import re

ROOT = Path.home() / '.9router'
MAX_RESPONSE = 1024 * 1024


def account_usage(identifier):
    if not isinstance(identifier, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', identifier):
        raise ValueError('Invalid 9Router connection ID.')
    seed = (ROOT / 'machine-id').read_text().strip() + '9r-cli-auth'
    seed += (ROOT / 'auth/cli-secret').read_text().strip()
    token = hashlib.sha256(seed.encode()).hexdigest()[:16]
    connection = HTTPConnection('127.0.0.1', 20128, timeout=25)
    try:
        connection.request('GET', '/api/usage/' + identifier, headers={'x-9r-cli-token': token})
        with connection.getresponse() as response:
            if response.status != 200:
                raise ValueError('9Router returned an error.')
            data = response.read(MAX_RESPONSE + 1)
    except HTTPException:
        raise ValueError('Could not read the 9Router response.') from None
    finally:
        connection.close()
    if len(data) > MAX_RESPONSE:
        raise ValueError('9Router response exceeds the size limit.')
    value = json.loads(data)
    if not isinstance(value, dict) or not isinstance(value.get('quotas'), dict):
        raise ValueError('9Router response has no quota data.')
    return value


def quota_windows(usage, keys):
    windows = {}
    for window, key in keys:
        quota = usage['quotas'].get(key)
        if not isinstance(quota, dict):
            continue
        if quota.get('unlimited') is True:
            windows[window] = {'unlimited': True}
            continue
        used, total = quota.get('used'), quota.get('total')
        if not all(type(value) in (int, float) and 0 <= value <= 10**18 and math.isfinite(value)
                   for value in (used, total)) or total == 0:
            continue
        limit = {'used': used, 'total': total}
        reset = quota.get('resetAt')
        if isinstance(reset, str) and len(reset) <= 40:
            try:
                datetime.fromisoformat(reset.replace('Z', '+00:00'))
                limit['resetAt'] = reset
            except ValueError:
                pass
        windows[window] = limit
    return windows
