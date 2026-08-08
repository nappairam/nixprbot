# nixprbot

Telegram bot that tracks [nixpkgs](https://github.com/NixOS/nixpkgs) PRs across
channel branches: `/track 312345` and it tells you when the PR is merged, then
again as the merge commit lands in `master`, `nixos-unstable-small`,
`nixos-unstable`, and friends. Auto-untracks once every configured branch is
reached (or the PR is closed).

Zig 0.16, SQLite ([zqlite](https://github.com/karlseguin/zqlite.zig)), no other
runtime dependencies. Single static-ish binary.

## Commands

| Command | Effect |
|---|---|
| `/track <PR#\|url>` | Subscribe this chat; replays already-reached stages |
| `/untrack <PR#>` | Unsubscribe (a later re-track replays the story) |
| `/list` | Tracked PRs with cached state and stages |
| `/status <PR#>` | Live refresh + per-branch checklist |
| `/help` | Help text |

## Configuration (environment)

| Variable | Default | Notes |
|---|---|---|
| `NIXPRBOT_TOKEN` | — | Bot API token, required |
| `NIXPRBOT_GITHUB_TOKEN` | — | Required; unauthenticated quota (60/h) is unusable |
| `NIXPRBOT_DB_PATH` | `nixprbot.sqlite` | |
| `NIXPRBOT_POLL_INTERVAL_SEC` | `900` | GitHub sweep cadence |
| `NIXPRBOT_BRANCHES` | `staging-next,master,nixpkgs-unstable,nixos-unstable-small,nixos-unstable` | |
| `NIXPRBOT_REPO` | `NixOS/nixpkgs` | |
| `NIXPRBOT_LOG` | `info` | `debug`/`info`/`warn`/`err` |
| `NIXPRBOT_HEARTBEAT_URL` | unset | Dead-man ping URL (healthchecks.io / Better Stack); secret — the token is in the URL |

## Failure policy

- The HTTP client is rebuilt whenever a request errors — a poisoned connection
  pool never survives one failure.
- Telegram poll failures back off exponentially (with jitter) and exhaust a
  budget of 15 consecutive failures, then the process exits; systemd restarts
  it with escalating `RestartSec`. A fatal condition (bad bot token, competing
  poller) exits immediately.
- `Type=notify` + `WatchdogSec` reap silent hangs; the loop pets the watchdog
  every iteration and between every tracked PR.
- GitHub 401 pauses tracking (hourly recheck) and **tells every subscribed
  chat**, then announces recovery; rate limiting pauses 15 minutes. Commands
  keep working while tracking is paused.
- The Telegram `getUpdates` offset is persisted in SQLite, so restarts neither
  drop nor replay commands.
- With `NIXPRBOT_HEARTBEAT_URL` set, the bot pings the URL while fully
  functional (Telegram polling up, last sweep clean) and POSTs `<url>/fail`
  with a reason when it knows it's degraded (GitHub 401/rate-limit, repeated
  sweep failures, Telegram failure streaks, pre-exit). Labeled incidents for
  what it can see; unlabeled silence means crash/hang/box-down.
- Notifications are sent before being marked, never after — a failed send
  retries next sweep (at-least-once).

## NixOS

```nix
inputs.nixprbot.url = "github:nappairam/nixprbot";

# configuration:
imports = [ inputs.nixprbot.nixosModules.default ];
services.nixprbot = {
  enable = true;
  environmentFile = "/run/secrets/nixprbot.env";
};
```

## Development

```console
$ nix develop
$ zig build test
$ NIXPRBOT_TOKEN=... NIXPRBOT_GITHUB_TOKEN=... zig build run
```
