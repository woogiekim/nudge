# nudge

Provider-agnostic push notifications for AI coding agents, via [ntfy](https://ntfy.sh).

Get a notification on your phone or desktop when **any** AI agent finishes a
response or is waiting for your input — regardless of which tool you're using.

The push is **self-identifying**: each notification shows which tool fired it,
which project it was running in, the current git branch, and either the AI's
session title or the user's last question — so you can tell at a glance which
of several concurrent AIs needs your attention.

## 🧩 How it works

The notification logic (the ntfy call) lives in **one shared script**,
`notify.sh`. Each AI tool calls a thin **per-tool context wrapper** that
parses the tool's hook payload (project dir, git branch, latest user prompt
or AI title) and then hands a context-rich title + message to `notify.sh`.

```
Claude Code (Stop hook) ─→ notify-claude.sh ┐
Codex CLI   (notify program, JSON argv) ─→ notify-codex.sh ├─→ notify.sh ─→ ntfy.sh/<topic> ─→ phone / desktop
Gemini CLI  (AfterAgent / Notification) ─→ notify-gemini.sh┘
```

Adding a new tool means writing one wrapper that extracts whatever context that
tool exposes; the core ntfy delivery never changes.

### Notification format

```
🤖 {Tool} · {project}            (title line)
{event} · {gitBranch}            (line 2)
Q: {question}                    (omitted when empty)
A: {assistant answer}            (omitted when empty)
```

- `{Tool}` is `Claude Code` / `Codex CLI` / `Gemini CLI`.
- `{project}` is the basename of the project directory the AI was running in.
- `{event}` is `Response complete`, `Waiting for your input`, `Task complete`, etc.
- `{gitBranch}` is omitted (no `· branch`) when the dir is not a git repo.
- `Q: {question}` carries the user's last question (or extracted AI title). It is omitted when empty and truncated to the `NUDGE_MAX_Q` codepoint cap (default `80`).
- `A: {assistant answer}` carries the assistant's most recent answer. It is omitted when empty and truncated to the `NUDGE_MAX_A` codepoint cap (default `120`).

## 📁 Project structure

```
nudge/
├── README.md                       # this file
├── notify.sh                       # shared ntfy sender (the core)
├── notify-claude.sh                # Claude Code context wrapper (stdin JSON)
├── notify-codex.sh                 # Codex CLI context wrapper (ARGV[1] JSON)
├── notify-gemini.sh                # Gemini CLI context wrapper (stdin JSON)
├── _nudge_lib.sh                   # shared helpers (truncate / format)
├── .env.example                    # topic/server config template
├── install.sh                      # copies everything + optional auto-wiring
├── test.sh                         # sends one test notification
├── tests/                          # fixture-only TDD test suite
└── examples/
    ├── claude-code.settings.json   # snippet for ~/.claude/settings.json
    ├── codex.config.toml           # snippet for ~/.codex/config.toml
    └── gemini.settings.json        # snippet for ~/.gemini/settings.json
```

## 🚀 Quick start

```bash
# 1. Install nudge (copies core + wrappers + shared lib to ~/.nudge, creates .env)
bash install.sh

# 2. Set your topic
#    Edit ~/.nudge/.env and set NTFY_TOPIC to a long random string

# 3. Subscribe to that topic in the ntfy app (iOS / Android / desktop / web)

# 4. Verify the path works
bash test.sh
```

`install.sh` deliberately does **not** edit your AI tools' config files by
default. Wire them up either manually (snippets in `examples/`) or opt-in to
the auto-wire flags below.

### Quick install (no clone)

If you'd rather not `git clone` first, pipe `install.sh` straight from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/woogiekim/nudge/main/install.sh | bash -s -- --wire-all
```

macOS variant (also provisions the headless ntfy receiver):

```bash
curl -fsSL https://raw.githubusercontent.com/woogiekim/nudge/main/install.sh | bash -s -- --wire-all --setup-receiver-macos
```

The script auto-detects that no checkout sits next to it and self-fetches the
seven nudge scripts plus `.env.example` from the same raw base URL into
`~/.nudge/`. After install you still need to:

1. Set `NTFY_TOPIC` to a long random string in `~/.nudge/.env`.
2. Subscribe to that same topic in the ntfy app (iOS / Android / desktop / web).

The existing `git clone` + `bash install.sh` flow remains fully supported and
is recommended for contributors. To target a fork or branch (e.g. for a
self-hosted mirror or a feature branch), point the one-liner at a different
raw base URL:

```bash
NUDGE_RAW_BASE_URL=https://raw.githubusercontent.com/<fork>/nudge/<ref> \
  curl -fsSL "${NUDGE_RAW_BASE_URL}/install.sh" | bash -s -- --wire-all
```

### Opt-in auto-wiring

```bash
bash install.sh --wire-claude     # ~/.claude/settings.json   (jq-merge)
bash install.sh --wire-codex      # ~/.codex/config.toml      (refuses to clobber)
bash install.sh --wire-gemini     # ~/.gemini/settings.json   (jq-merge)
bash install.sh --wire-all        # all three at once
```

Each wiring:

- writes a **timestamped backup** of the target file before any edit
  (`settings.json.bak.YYYYMMDDHHMMSS` / `config.toml.bak.YYYYMMDDHHMMSS`);
- is **idempotent** — re-running it is a no-op and no extra backup is made;
- **preserves existing hooks / config** (mnemos, agent-crew, your own scripts
  all keep working);
- **degrades gracefully** if `jq` is missing — the installer prints the
  manual snippet and exits without touching anything;
- uses **absolute `${HOME}/.nudge/...` paths** in the wired commands, so tools
  that don't expand `~` still find the wrappers.

**Codex safety (important).** `notify` in `config.toml` is a single value, not
array-mergeable. If you already have a `notify = [...]` set (e.g. for a
Computer Use client), `--wire-codex` will **refuse to overwrite** it. It prints
the exact line you can paste manually and exits 0, leaving your file
byte-identical. To wire Codex while keeping another tool's notify, replace the
existing `notify` line with the printed one or chain the other tool's command
into the wrapper yourself.

**Codex detach (why the wired notify looks unusual).** The generated `notify`
line wraps the wrapper in a backgrounded subshell with `nohup`
(`( nohup ~/.nudge/notify-codex.sh "$1" >/dev/null 2>&1 & )`). Codex runs
`notify` **fire-and-forget** and tears down the process tree right after the
turn (especially under `codex exec`), so a plain synchronous `curl` would be
killed mid-flight and the push would never reach ntfy. Detaching the wrapper
lets the POST complete after Codex exits. Claude Code and Gemini CLI are not
affected — their hosts wait for the hook to finish before tearing down.

**Gemini safety.** If `~/.gemini` does not exist, `--wire-gemini` (and
`--wire-all`) skip with a notice — they will not create the directory.

**Session restart.** Claude Code and Gemini CLI read their settings files at
session start, so **restart the affected CLI session** after wiring for the
hooks to load.

## 🍎 macOS headless receiver (opt-in)

On macOS you can opt in to a fully **headless** ntfy receiver that delivers
each notification natively to Notification Center — without running the ntfy
GUI / desktop app.

```bash
# 1. Make sure NTFY_TOPIC is set in ~/.nudge/.env (run `bash install.sh` first
#    if .env does not yet exist).
# 2. Provision the receiver:
bash install.sh --setup-receiver-macos
```

This flag is **macOS only**; on Linux/Windows it is a clean no-op. It:

- `brew install`s `ntfy` and `terminal-notifier` (idempotent).
- Copies `notify-mac.sh` into `~/.nudge/` (the per-message notifier).
- Writes `~/Library/LaunchAgents/sh.ntfy.subscribe.plist`, a launchd agent
  that runs `ntfy subscribe <NTFY_TOPIC> ~/.nudge/notify-mac.sh` with
  `RunAtLoad` + `KeepAlive`. An existing plist is preserved as
  `sh.ntfy.subscribe.plist.bak.YYYYMMDDHHMMSS`.
- Loads the agent via `launchctl bootout` → `bootstrap`.
- Publishes a self-test message (`"nudge receiver installed"`) so you can
  confirm delivery.

### One manual permission step (required by macOS)

macOS does not let installers grant Notification Center permission
programmatically. After the flag finishes, the installer opens
**System Settings → Notifications** for you. Do this once:

1. Find **terminal-notifier** in the app list.
2. Allow notifications and set the alert style to **Alerts**.
3. Disable **Focus / Do Not Disturb** if you want notifications during
   quiet hours.

### Duplicate-notifications advisory

If you still have the ntfy **GUI / desktop app** running while the headless
receiver is also subscribed to the same topic, you will get **two**
notifications per message. The installer prints this reminder; nudge does
**not** auto-quit the GUI app — quit it manually if you no longer need it.

### Logs

- Per-message log: `~/.nudge/ntfy-mac-notify.log`
- launchd stdout / stderr: `~/Library/Logs/ntfy-subscribe.log` and
  `~/Library/Logs/ntfy-subscribe.err`

## 🔌 Wiring up each tool

Each tool stores config differently, but all of them ultimately call
`notify.sh` via a thin per-tool wrapper. Merge the matching `examples/` file
into the tool's own config (or use the auto-wire flags above).

| Tool        | Config file                  | Mechanism                          | "Done" event          | "Waiting" event       |
| ----------- | ---------------------------- | ---------------------------------- | --------------------- | --------------------- |
| Claude Code | `~/.claude/settings.json`    | hooks                              | `Stop`                | (no waiting event)    |
| Codex CLI   | `~/.codex/config.toml`       | `notify` + `[tui] notifications`   | `agent-turn-complete` | (no waiting event)    |
| Gemini CLI  | `~/.gemini/settings.json`    | hooks                              | `AfterAgent`          | `Notification`        |

### Path note

The examples use `~/.nudge/notify-*.sh`. If a tool does not expand `~` in its
command, use the absolute path instead (e.g. `/home/you/.nudge/notify-codex.sh`).
The auto-wire installers already write absolute paths.

## 🔐 Security

- ntfy.sh topics are **public**: anyone who knows the topic name can read or
  send to it. Use a long, random topic name (the `.env.example` explains this).
- Notifications carry the user's last question on the `Q:` line **and** the
  assistant's most recent answer on the `A:` line. Either may contain
  secrets. If that is a concern, configure the wrappers to skip both lines
  (e.g. by clearing `$QUESTION` and `$ANSWER` in your own fork of
  `notify-claude.sh` / `notify-codex.sh`), or self-host ntfy behind a
  private network such as Tailscale.
- For full privacy, self-host ntfy and set `NTFY_SERVER` to your own instance.

## ⚠️ Caveats and uncertainty

- **Gemini `AfterAgent` noise:** `AfterAgent` may fire on intermediate steps,
  not only on true completion. To reduce false positives, extend
  `notify-gemini.sh` to inspect `.prompt_response` / pending tool-call markers
  before forwarding to `notify.sh`.
- **Tool config schemas change:** hook/notify formats evolve across releases.
  If notifications stop after an update, re-check the tool's current docs and
  refresh the wrappers.
- **Wrappers fail soft.** Any extraction error (missing transcript file, bad
  JSON, no `jq` on PATH) still sends a basic `🤖 {Tool} · {project}` push
  rather than erroring out — the wrappers never break the calling AI.

## 🧪 Manual tests

```bash
# 1. Bypass everything: confirm ntfy delivery directly
~/.nudge/notify.sh "Manual test" "ntfy delivery OK" high

# 2. Run the full TDD suite (fixtures only — never touches real config)
bash tests/test-notify-claude.sh
bash tests/test-notify-codex.sh
bash tests/test-notify-gemini.sh
bash tests/test-wire-claude.sh
bash tests/test-wire-codex.sh
bash tests/test-wire-gemini.sh
bash tests/test-setup-receiver-macos.sh
bash tests/test-notify-mac.sh
```
