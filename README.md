# Account Switcher for Omarchy

Switch Codex and Antigravity CLI (AGY) accounts from the Omarchy bar. The
panel lists OAuth accounts from 9Router and shows their 5-hour and weekly
quotas. The Codex tab also shows how many reset credits are available.

## Requirements

- Omarchy with the shell plugin system. The manifest was validated on Omarchy 4.5.0-3.
- Python 3.10 or later.
- A local 9Router instance at `127.0.0.1:20128`. It must use the SQLite database
  at `~/.9router/db/data.sqlite` and provide its CLI authentication files in
  `~/.9router`. Add the OAuth accounts you want to use in 9Router.
- For Codex, use file-based ChatGPT login. Set
  `cli_auth_credentials_store = "file"` in your Codex configuration.
  If you use a custom `CODEX_HOME`, make that variable available to the Omarchy shell.
- For AGY, install `libsecret` for `secret-tool`. Sign in to AGY once to
  create its credential in an unlocked Linux Secret Service keyring.

## Install

Replace the example URL with the plugin repository URL. Add and enable the plugin.

```sh
omarchy plugin add https://github.com/OWNER/REPOSITORY.git
omarchy plugin enable agent-tools.account-switcher right
```

From a local checkout, you can validate the package before you install it.

```sh
omarchy plugin validate .
```

## Switch accounts

1. Close all sessions of the CLI you want to switch. This includes Codex app servers.
2. Open **Account Switcher** from the bar.
3. Select **Codex** or **AGY**. Select an account and wait for the active label to move.
4. Open the CLI again.

Selecting an account replaces the active CLI credential. The Codex tab writes
`auth.json` in `CODEX_HOME`, which defaults to `~/.codex`. The AGY tab updates
the AGY entry in the Linux keyring. To return to a previous account, select
it again or sign in through the CLI. The reset badge only displays the
number of credits.

## Quotas and local data

The panel displays the last successful snapshot while it refreshes. The
default refresh interval is 60 seconds. Select **Refresh** to request data
immediately. To stop refreshes while the panel is closed, turn off
**Refresh when the panel is closed** in the widget settings.

The plugin reads the local 9Router database and contacts only the local
9Router quota endpoint. Cache files contain account names, plan labels, and
quota data. The plugin stores them in
`${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/account-switcher`.

**Tokens by model** appears when a collector such as the Omarchy Agents
widget has written the provider's usage file under
`${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage`. These totals
cover the provider, including all accounts.

## Remove

Run the following command to remove the plugin.

```sh
omarchy plugin remove agent-tools.account-switcher
```

If you want to remove the saved snapshots, delete the cache directory shown
above. The CLIs continue to use the credentials selected before removal.

## Develop

```sh
omarchy plugin validate .
python3 test-account-cache.py
python3 test-account-switch.py
```

The tests use temporary data.

## License

[MIT](LICENSE)
