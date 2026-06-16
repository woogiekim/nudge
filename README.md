# nudge

Provider-agnostic push notifications for AI coding agents, via [ntfy](https://ntfy.sh).

Get a notification on your phone or desktop when **any** AI agent finishes a
response or is waiting for your input — regardless of which tool you're using.

## 🧩 How it works

The notification logic (the ntfy call) lives in **one shared script**,
`notify.sh`. Each AI tool calls that script from its own hook/notify
mechanism, so everything lands on a single ntfy topic that you subscribe to
once. Adding a new tool means pointing its hook at the same script — nothing
else changes.

```
Claude Code (Stop / Notification hook) ┐
Codex CLI   (notify command)           ├─→  notify.sh  ─→  ntfy.sh/<topic>  ─→  phone / desktop
Gemini CLI  (Notification hook)        ┘
```

## 📁 Project structure

```
nudge/
├── README.md                       # this file
├── notify.sh                       # shared ntfy sender (the core)
├── .env.example                    # topic/server config template
├── install.sh                      # copies notify.sh + creates .env (non-destructive)
├── test.sh                         # sends one test notification
└── examples/
    ├── claude-code.settings.json   # snippet for ~/.claude/settings.json
    ├── codex.config.toml           # snippet for ~/.codex/config.toml
    └── gemini.settings.json        # snippet for ~/.gemini/settings.json
```

## 🚀 Quick start

```bash
# 1. Install the core script (copies to ~/.nudge, creates .env)
bash install.sh

# 2. Set your topic
#    Edit ~/.nudge/.env and set NTFY_TOPIC to a long random string

# 3. Subscribe to that topic in the ntfy app (iOS / Android / desktop / web)

# 4. Verify the path works
bash test.sh
```

`install.sh` deliberately does **not** edit your AI tools' config files, so
your existing settings are never overwritten. Tool wiring is manual (below).

## 🔌 Wiring up each tool

Each tool stores config differently, so the trigger differs — but all of them
just call `notify.sh`. Merge the matching `examples/` file into the tool's own
config (don't replace the whole file; add the `hooks` / `notify` keys).

| Tool        | Config file                  | Mechanism                          | "Done" event          | "Waiting" event       |
| ----------- | ---------------------------- | ---------------------------------- | --------------------- | --------------------- |
| Claude Code | `~/.claude/settings.json`    | hooks                              | `Stop`                | `Notification`        |
| Codex CLI   | `~/.codex/config.toml`       | `notify` + `[tui] notifications`   | `agent-turn-complete` | `approval-requested`  |
| Gemini CLI  | `~/.gemini/settings.json`    | hooks                              | `AfterAgent`          | `Notification`        |

### Path note

The examples use `~/.nudge/notify.sh`. If a tool does not expand `~` in its
command, use the absolute path instead, e.g. `/home/you/.nudge/notify.sh`.

## 🔐 Security

- ntfy.sh topics are **public**: anyone who knows the topic name can read or
  send to it. Use a long, random topic name (the `.env.example` explains this).
- For full privacy, self-host ntfy and set `NTFY_SERVER` to your own instance
  (optionally behind a private network such as Tailscale).
- Keep notification messages free of secrets — treat them as "the agent needs
  you" pings, not data transport.

## ⚠️ Caveats and uncertainty

- **Codex payload (Unverified):** Codex passes a JSON payload to the `notify`
  command, but the exact field schema varies by version. The provided config
  ignores the payload and sends a fixed message. For event-specific text, wrap
  `notify.sh` in a script that parses the JSON with `jq`.
- **Gemini `AfterAgent` noise:** `AfterAgent` may fire on intermediate steps,
  not only on true completion. To reduce false positives, use a wrapper that
  checks for pending tool calls in the hook's stdin JSON before notifying.
  (The exact field name should be confirmed against the current Gemini CLI
  hooks reference.)
- **Tool config schemas change:** hook/notify formats evolve across releases.
  If notifications stop after an update, re-check the tool's current docs.

## 🧪 Manual test (any tool, bypassing hooks)

```bash
# Confirms ntfy delivery independently of any tool's configuration
~/.nudge/notify.sh "Manual test" "ntfy delivery OK" high
```
