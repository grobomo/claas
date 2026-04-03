# CLaaS v2 -- Claude-as-a-Service

Multi-tenant HTTP API for managing a fleet of Claude Code workers on AWS EC2.
Workers are self-sufficient: they pull repos, branch, implement, rebase, push, and create PRs.

## What This Repo Is

Standalone CLaaS framework. Everything needed to deploy and operate a Claude Code worker fleet.

## Architecture

```
Client -> Nginx (HTTPS) -> Dispatcher (CLaaS API :8080) -> Workers (EC2, claude -p)
                                |                              |
                                |-- Dashboard (HTML, SSE)      |-- claas-worker-run.sh
                                |-- Auto-scale loop            |-- Pull, branch, implement
                                |-- Heartbeat monitor          |-- Rebase, push, create PR
                                |-- Merge bot                  |-- Report result back
```

### Key v2 improvements over v1:
- **Worker-side speccing**: Workers handle full lifecycle (no dispatcher bottleneck)
- **LRU assignment**: Even distribution across workers
- **Heartbeat system**: Real-time visibility into worker state
- **Auto-scale**: Queue-based scaling with cost guards
- **Conflict resolution**: Auto-retry after rebase conflicts, sequential merge bot
- **Webhooks**: Teams/Slack notifications for task events

## Directory Layout

```
dashboard/              -- Web UI (single-file HTML dashboard + Node.js admin)
client/                 -- Client libraries
  claas-client.py       -- Python SDK (submit, wait, status)
  claas-client.sh       -- Bash CLI wrapper
  thin-client/          -- Thin client TUI + local agent
    claas-tui.py        -- Terminal UI + agent (zero deps, single file)
cloudformation/         -- AWS infrastructure templates
scripts/                -- API, operational scripts, worker scripts
  claas-api-v2.py       -- Main CLaaS API (Flask)
  claas-session-api.py  -- Session API for thin client (Flask blueprint)
  claas-worker-run.sh   -- Worker-side task execution
  test/                 -- Test suites
docs/                   -- API reference, architecture, quick-start, AWS deploy
specs/                  -- Feature specs (SpecKit format)
```

## Architecture Split

CLaaS is the **user experience layer** — TUI, session API, client libs, dashboard, docs.
The compute layer (Dockerfiles, worker images, fleet management) lives in **claude-portable**.

## Key Scripts

| Script | What it does |
|--------|-------------|
| `scripts/claas-api-v2.py` | Flask API server (submit, dispatch, heartbeat, autoscale, SSE) |
| `scripts/claas-worker-run.sh` | Worker-side task execution (pull, branch, claude, rebase, PR) |
| `scripts/auto-scale.sh` | Scale workers based on queue depth with cost guards |
| `scripts/merge-bot.sh` | Sequential PR merge (oldest first, auto-rebase, retry) |
| `scripts/setup-billing-alarm.sh` | CloudWatch billing alarms ($50 warn, $100 stop) |
| `scripts/fleet-heal.sh` | Self-healing monitor (run in cron) |
| `scripts/api-submit.sh` | Submit a task via CLI |
| `scripts/api-status.sh` | Fleet/task status |
| `scripts/recover-dispatcher.sh` | Full dispatcher recovery |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/submit` | Submit task (accepts `repo`, `base_branch`) |
| GET | `/api/v1/task/:id` | Task status + output + PR URL |
| POST | `/api/v1/task/:id/result` | Worker reports result back |
| POST | `/api/v1/task/:id/retry` | Re-queue failed/conflict task |
| GET | `/api/v1/tasks` | List all tasks |
| GET | `/api/v1/health` | Fleet health summary |
| GET | `/api/v1/workers` | Worker registry with stats |
| POST | `/api/v1/workers/register` | Register a new worker |
| POST | `/api/v1/heartbeat` | Worker heartbeat |
| GET | `/api/v1/heartbeats` | Latest heartbeat per worker |
| GET | `/api/v1/events` | Last 100 events (JSON) |
| GET | `/api/v1/events/stream` | SSE event stream |
| GET | `/api/v1/costs` | Fleet cost estimate + budget |
| GET | `/api/v1/autoscale` | Auto-scale config + state |
| POST | `/api/v1/autoscale` | Update auto-scale config |
| GET | `/dashboard` | Live dashboard HTML |
| GET | `/metrics` | Prometheus metrics |

## Configuration (env vars)

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAAS_DATA_DIR` | `/data` | Persistent storage for tasks, workers, events |
| `CLAAS_SSH_KEY_DIR` | `/tmp/ccc-keys` | SSH keys for worker access |
| `CLAAS_TARGET_REPO` | `altarr/boothapp` | Default target repo for tasks |
| `CLAAS_TARGET_BRANCH` | `main` | Default base branch |
| `CLAAS_DISPATCHER_PRIVATE_IP` | `localhost` | Dispatcher IP for worker callbacks |
| `CLAAS_AUTOSCALE` | `false` | Enable auto-scale loop |
| `CLAAS_MIN_WORKERS` | `2` | Minimum workers (scale floor) |
| `CLAAS_MAX_WORKERS` | `10` | Maximum workers (scale ceiling) |
| `CLAAS_BUDGET_DAILY` | `50` | Daily budget warning threshold ($) |
| `CLAAS_BUDGET_HARD_STOP` | `100` | Daily hard-stop threshold ($) |
| `CLAAS_WEBHOOK_URL` | (none) | Teams/Slack webhook for notifications |
| `CLAAS_WEBHOOK_EVENTS` | `completed,failed,conflict,scale_up_needed` | Events to notify |
| `CLAAS_UNRESPONSIVE_TIMEOUT` | `120` | Seconds without heartbeat = unresponsive |

## Development

- No feature code in this repo -- infrastructure only
- Scripts source `scripts/fleet-config.sh` for shared config
- Workers are stateless -- rebuilt from golden image on any issue
- Dashboard is a single HTML file with SSE for real-time updates

## GitHub

- Account: grobomo (public, generic tooling)
- No customer data, PII, or internal infra references
