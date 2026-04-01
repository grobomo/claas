# CLaaS — Claude-as-a-Service

Multi-tenant HTTP API for managing a fleet of Claude Code workers on AWS EC2.

## What This Repo Is

Standalone CLaaS framework extracted from the hackathon26 coordination workspace.
Everything needed to deploy and operate a Claude Code worker fleet.

## Architecture

```
Client -> Nginx (HTTPS) -> Dispatcher (CLaaS API :8080) -> Workers (EC2, claude -p)
```

- **Dispatcher**: Python HTTP server with task queue, spec generator, SSH dispatch
- **Dashboard**: Node.js (central-server.js + auth.js) — submit UI, task list, sessions, tokens
- **Workers**: EC2 spot instances running Claude Code in Docker (golden image)
- **Clients**: Python library (zero deps) + Bash CLI

## Directory Layout

```
dashboard/         — Web UI (Node.js)
client/            — Python + Bash client libraries
cloudformation/    — AWS infrastructure templates
scripts/           — Operational scripts (deploy, heal, scale)
docs/              — API reference, architecture, quick-start, AWS deploy
specs/             — Feature specs (SpecKit format)
```

## Key Scripts

| Script | What it does |
|--------|-------------|
| `scripts/fleet-heal.sh` | Self-healing monitor (run in cron) |
| `scripts/auto-scale.sh` | Scale workers based on queue depth |
| `scripts/api-submit.sh` | Submit a task via CLI |
| `scripts/api-status.sh` | Fleet/task status |
| `scripts/recover-dispatcher.sh` | Full dispatcher recovery |

## API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/v1/submit` | Bearer | Submit task |
| GET | `/api/v1/task/:id` | Bearer | Task status |
| GET | `/api/v1/tasks` | Bearer | List tasks |
| GET | `/api/v1/health` | Bearer | Fleet health |
| GET | `/metrics` | None | Prometheus metrics |

## Development

- No feature code in this repo — it's infrastructure only
- Scripts source `scripts/fleet-config.sh` for shared config
- Dashboard runs on port 8082, proxied through nginx
- Workers are stateless — rebuilt from golden image on any issue

## GitHub

- Account: grobomo (public, generic tooling)
- No customer data, PII, or internal infra references
