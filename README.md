# nixprbot

Telegram bot that tracks nixpkgs PRs across channel branches. Per-chat
subscriptions, one notification per stage, auto-untracks once a PR has
propagated to every configured branch. Written in Zig 0.16.

## Features

- `/track <PR#|url>` — subscribe to a PR
- `/untrack <PR#>` — unsubscribe
- `/list` — list tracked PRs with current stage progress
- `/status <PR#>` — refresh + show full branch checklist
- 🟣 merged · ⚫ closed · 🟢 stage reached
- Auto-untrack when PR reaches every configured branch (default:
  `staging-next, master, nixpkgs-unstable, nixos-unstable-small, nixos-unstable`)
- SQLite-backed (subscriptions, pr_meta, pr_stage, notified)
- Multi-chat, dedup per `(chat, pr, stage)`
- Cached fast-path on `/track` of a previously-tracked PR — no GitHub
  round-trip if state already complete in cache
- HTML-formatted Telegram messages with clickable PR links
- Custom `std.log` formatter: HH:MM:SS.ms timestamps + ANSI colors
  (auto-detects TTY)

## Configuration

| Env var | Required | Default | Description |
| --- | --- | --- | --- |
| `NIXPRBOT_TOKEN` | yes | — | Telegram bot token |
| `NIXPRBOT_GITHUB_TOKEN` | no | — | GitHub PAT (raises rate limit 60→5000/hr) |
| `NIXPRBOT_DB_PATH` | no | `nixprbot.sqlite` | SQLite database path |
| `NIXPRBOT_POLL_INTERVAL_SEC` | no | `900` | Status poll interval |
| `NIXPRBOT_REPO` | no | `NixOS/nixpkgs` | `owner/repo` to track |
| `NIXPRBOT_BRANCHES` | no | see above | Comma-separated branch list, in display order |

## Build & run

```sh
nix develop --command zig build run
```

Or via the flake package:

```sh
nix build .#nixprbot
NIXPRBOT_TOKEN=... NIXPRBOT_GITHUB_TOKEN=... ./result/bin/nixprbot
```

Tests:

```sh
nix develop --command zig build test
```

## NixOS deployment

The flake exposes `nixosModules.default`. Reference it from your system
configuration:

```nix
{
  inputs.nixprbot.url = "github:nappairam/nixprbot";

  outputs = { self, nixpkgs, nixprbot, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        nixprbot.nixosModules.default
        ({ ... }: {
          services.nixprbot = {
            enable = true;
            environmentFile = "/run/secrets/nixprbot.env";
            # optional overrides:
            # pollIntervalSeconds = 600;
            # branches = [ "master" "nixos-unstable" ];
            # repo = "NixOS/nixpkgs";
          };
        })
      ];
    };
  };
}
```

`environmentFile` is read by systemd via `EnvironmentFile=` so secrets
never enter the Nix store. Format:

```
NIXPRBOT_TOKEN=123456:ABC...
NIXPRBOT_GITHUB_TOKEN=ghp_...
```

The service runs as system user `nixprbot`, state directory
`/var/lib/nixprbot` (configurable). Hardened with `NoNewPrivileges`,
`ProtectSystem=strict`, `PrivateTmp`, `MemoryDenyWriteExecute`, etc.

## Architecture

| File | Role |
| --- | --- |
| `src/config.zig` | Env-driven `Config` |
| `src/db.zig` | SQLite schema + CRUD (zqlite) |
| `src/http.zig` | Wrapper over `std.http.Client.fetch` |
| `src/telegram.zig` | `getUpdates`, `sendMessage`, `setMyCommands` |
| `src/github.zig` | `getPr`, `commitInBranch` (compare API) |
| `src/commands.zig` | `/track /untrack /list /status /help` dispatch |
| `src/poller.zig` | `Tracker.refreshPr`, `runOnce`, `backfillSubscriber`, `pruneIfComplete` |
| `src/main.zig` | Single-thread loop: long-poll Telegram interleaved with status poll, SIGINT/SIGTERM graceful shutdown |
| `nix/package.nix` | Reproducible build with `zig_0_16` + vendored deps |
| `nix/deps.nix` | Generated via `zon2nix` from `build.zig.zon` |
| `nix/module.nix` | NixOS systemd service module |

### Tables

- `subscriptions(chat_id, pr_number)` — who tracks what
- `pr_meta(pr_number, title, state, merged, merge_commit_sha, last_checked_at)` — cached PR snapshot
- `pr_stage(pr_number, stage, reached_at)` — global record of branches a PR's commit has reached
- `notified(chat_id, pr_number, stage)` — per-chat dedup ledger

### Notification flow

1. Poll cycle (every `pollIntervalSeconds`) iterates `allTrackedPrs`.
2. For each PR, `refreshPr` fetches GitHub state, upserts `pr_meta`, fires:
   - `🟣 merged` once on `merged=false → true`
   - `⚫ closed` once on `state≠closed → closed` (without merge)
   - For each configured branch not yet in `pr_stage`, calls
     `compare(branch ... merge_commit_sha)`. If `status ∈ {behind, identical}`,
     records the stage globally and fires `🟢 reached <branch>`.
3. Each event fans out to subscribers, deduped via `notified`.
4. After refresh, if every configured branch is in `pr_stage`,
   `pruneIfComplete` deletes the subscriptions and sends each subscriber a
   `✅ … auto-untracked` notice. `pr_meta`/`pr_stage` are kept so re-tracks
   serve from cache.

`/track` adds the subscription, then either does the same refresh or — if
the PR's cached state is already complete — replays merged + each stage
message to that one chat (`backfillSubscriber`), then auto-untracks.

## Regenerate deps after changing build.zig.zon

```sh
nix run nixpkgs#zon2nix -- build.zig.zon > nix/deps.nix
sed -i 's|?ref=[^"]*||' nix/deps.nix
```

The `sed` strips the `?ref=…` query that breaks `fetchgit`.

## Inspiration

Behavior modeled on [nixpr-bot](https://github.com/nappairam/nixpr-bot) (the
Python implementation) and [nixpk.gs/pr-tracker](https://nixpk.gs/pr-tracker.html)
(Alyssa Ross). Channel-containment check uses the same compare-API trick.
