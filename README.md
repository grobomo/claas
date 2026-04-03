# CLaaS v2 -- Claude-as-a-Service

Multi-tenant HTTP API for managing a fleet of Claude Code workers on AWS EC2.

Submit a task -> worker pulls the repo, branches, implements with Claude, rebases, pushes, creates a PR.

## What's New in v2

- **Worker-side speccing**: Workers handle the full lifecycle (no dispatcher bottleneck)
- **LRU assignment**: Even distribution across workers by least-recently-used
- **Heartbeat system**: Real-time visibility into worker state
- **Live dashboard**: Single-file HTML with SSE streaming, cost tracking, auto-scale status
- **Auto-scale**: Queue-based scaling with cost guards and dry-run mode
- **Conflict resolution**: Auto-retry after rebase conflicts, sequential merge bot
- **Webhooks**: Teams/Slack notifications for task events

## Architecture

```
Client (curl / Python / Bash)
  |
  v
Dispatcher (CLaaS API on :8080)
  |-- Live Dashboard (HTML + SSE)
  |-- Auto-scale loop (scale up/down by queue depth)
  |-- Heartbeat monitor (mark unresponsive workers)
  |-- Conflict retry (auto-requeue after rebase failures)
  |
  +-- Worker 1 (EC2 spot)      +-- Worker 2      +-- Worker N
      |-- claas-worker-run.sh
      |-- Pull repo, create branch
      |-- claude -p with CLAUDE.md context
      |-- Rebase from main, push
      |-- Create PR via gh
      |-- Report result back to dispatcher
```

## Quick Start

```bash
# Start the API (requires Flask)
pip install flask
python scripts/claas-api-v2.py

# Register a worker
curl -X POST http://localhost:8080/api/v1/workers/register \
  -H "Content-Type: application/json" \
  -d '{"name": "worker-1", "private_ip": "10.0.1.10"}'

# Submit a task
curl -X POST http://localhost:8080/api/v1/submit \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Add a health check endpoint to the API", "repo": "owner/repo"}'

# Check status
curl http://localhost:8080/api/v1/task/<task-id>

# Open the dashboard
open http://localhost:8080/dashboard
```

## Thin Client (Remote Claude)

For users who can't install Claude locally. A lightweight TUI connects to CLaaS,
the worker runs Claude in AWS, and a local agent handles file operations.

```bash
# One-time setup
python client/thin-client/claas-tui.py --init    # creates ~/.claas/config.json
# Edit config: set server URL, allowed paths

# Start interactive session
python client/thin-client/claas-tui.py --server https://claas.example.com

# Resume a previous session
python client/thin-client/claas-tui.py --session abc12345
```

```
  CLaaS Remote Shell v1.0
  Server:  https://claas.example.com
  Session: a1b2c3d4

> Add error handling to src/api/routes.js

  [agent] read_file: /home/user/project/src/api/routes.js
  [agent] write_file: /home/user/project/src/api/routes.js

  Done. Added try-catch to 5 routes with proper error responses.

> /audit    # review what the agent executed
> /workers  # see fleet status
> /new      # start fresh session
```

**Security model:**
- No Claude on user machine -- only TUI + agent (Python, zero deps)
- Agent only executes whitelisted operations (`read_file`, `list_dir`, `search_files`, `write_file`, `run_script`)
- Path restrictions -- file ops limited to configured directories
- Path traversal protection (realpath resolution)
- Full audit log (local JSONL + server-side) for security team review

See [Session API endpoints](#session-api) for the full API.

## Client Libraries

### Python (zero dependencies)

```python
from client.claas_client import CLaaSClient

client = CLaaSClient("http://localhost:8080")
task = client.submit("Add error handling to the parser")
result = client.wait(task["task_id"], timeout=300)
print(result["pr_url"])
```

### Bash CLI

```bash
bash scripts/claas-submit.sh "Add error handling to the parser"
bash scripts/claas-task-status.sh <task-id>
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/submit` | Submit task (`prompt`, `repo`, `base_branch`) |
| GET | `/api/v1/task/:id` | Task status + output + PR URL |
| POST | `/api/v1/task/:id/result` | Worker reports result back |
| POST | `/api/v1/task/:id/retry` | Re-queue failed/conflict task |
| GET | `/api/v1/tasks` | List all tasks |
| GET | `/api/v1/health` | Fleet health summary |
| GET | `/api/v1/workers` | Worker registry with stats |
| POST | `/api/v1/workers/register` | Register a worker |
| POST | `/api/v1/heartbeat` | Worker heartbeat |
| GET | `/api/v1/heartbeats` | Latest heartbeat per worker |
| GET | `/api/v1/events` | Last 100 events (JSON) |
| GET | `/api/v1/events/stream` | SSE event stream (live dashboard) |
| GET | `/api/v1/costs` | Fleet cost estimate + budget |
| GET | `/api/v1/autoscale` | Auto-scale config + state |
| POST | `/api/v1/autoscale` | Update auto-scale config |
| GET | `/dashboard` | Live web dashboard |
| GET | `/metrics` | Prometheus metrics |

### Session API

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/session` | Create interactive session |
| POST | `/api/v1/session/:id/prompt` | Send user prompt to worker |
| GET | `/api/v1/session/:id/stream` | SSE stream of response chunks |
| GET | `/api/v1/session/:id/status` | Session state |
| DELETE | `/api/v1/session/:id` | End session |
| GET | `/api/v1/sessions` | List all sessions |
| POST | `/api/v1/session/:id/command` | Worker requests local op (blocks until agent responds) |
| GET | `/api/v1/session/:id/commands` | Agent polls for pending commands |
| POST | `/api/v1/session/:id/result` | Agent returns command result |
| GET | `/api/v1/session/:id/audit` | Audit log for session |
| GET | `/api/v1/audit` | Full audit log (last 500) |

See [docs/api-reference.md](docs/api-reference.md) for full details with curl examples.

## Dashboard

Single-file HTML dashboard at `/dashboard` with real-time SSE updates:
- **Worker grid**: idle/busy/unresponsive status with completion stats
- **Task table**: full lifecycle view with prompt, worker, duration, output, PR URL
- **Heartbeat timeline**: visual bars per worker showing recency
- **Event feed**: color-coded scrolling log of all fleet events
- **Cost panel**: hourly/daily cost, budget tracking, cost-per-task, auto-scale status

## Fleet Operations

| Script | Purpose |
|--------|---------|
| `scripts/claas-api-v2.py` | Flask API server |
| `scripts/claas-worker-run.sh` | Worker-side task execution |
| `scripts/auto-scale.sh` | Scale workers by queue depth (with cost guards) |
| `scripts/merge-bot.sh` | Sequential PR merge (auto-rebase, retry) |
| `scripts/setup-billing-alarm.sh` | CloudWatch billing alarms |
| `scripts/fleet-heal.sh` | Self-healing fleet monitor (cron) |
| `scripts/recover-dispatcher.sh` | Full dispatcher recovery |
| `scripts/reregister-workers.sh` | Re-register all workers |
| `scripts/refresh-worker-creds.sh` | Push fresh OAuth tokens |

## Configuration

All via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAAS_DATA_DIR` | `/data` | Persistent storage |
| `CLAAS_TARGET_REPO` | `altarr/boothapp` | Default target repo |
| `CLAAS_TARGET_BRANCH` | `main` | Default base branch |
| `CLAAS_AUTOSCALE` | `false` | Enable auto-scale loop |
| `CLAAS_MIN_WORKERS` | `2` | Scale floor |
| `CLAAS_MAX_WORKERS` | `10` | Scale ceiling |
| `CLAAS_BUDGET_DAILY` | `50` | Daily budget warning ($) |
| `CLAAS_BUDGET_HARD_STOP` | `100` | Daily hard stop ($) |
| `CLAAS_WEBHOOK_URL` | (none) | Teams/Slack webhook URL |
| `CLAAS_UNRESPONSIVE_TIMEOUT` | `120` | Seconds without heartbeat |

## AWS Deployment

Templates in `cloudformation/`:
- `claas-network.yaml` -- VPC, subnets, security groups
- `claas-storage.yaml` -- S3 bucket, EBS volumes
- `claas-worker.yaml` -- EC2 spot instances
- `claas-nginx.yaml` -- Nginx proxy with TLS

See [docs/aws-deploy.md](docs/aws-deploy.md) for step-by-step instructions.

## Monitoring

### Prometheus

`/metrics` exposes: `claas_workers_total`, `claas_workers_idle`, `claas_workers_busy`, `claas_tasks_submitted_total`, `claas_tasks_completed_total`, `claas_tasks_pending`, `claas_dispatcher_uptime_seconds`, `claas_errors_total`.

### Grafana

Import `dashboard/grafana-dashboard.json` for worker gauges, task throughput, utilization, and completion rate.

## License

MIT
