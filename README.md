# CLaaS — Claude-as-a-Service

Multi-tenant HTTP API for managing a fleet of Claude Code workers on AWS EC2.

Submit a task → Claude generates a spec → dispatches to an idle worker → worker codes, branches, PRs.

## Architecture

```
Client (curl / Python / Bash)
  │
  ▼
Nginx Proxy (HTTPS + cookie auth)
  │
  ▼
Dispatcher (CLaaS API on :8080)
  ├── Spec Generator (claude -p)
  ├── Worker Router (SSH dispatch)
  ├── Task Persistence (/data/)
  └── Token Auth (Bearer tokens)
       │
       ├── Worker 1 (EC2 spot, claude -p)
       ├── Worker 2
       └── Worker N
```

## Quick Start

```bash
# Submit a task
curl -k -X POST https://<your-host>/api/v1/submit \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"text": "Build a REST API that returns weather data"}'

# Check status
curl -k https://<your-host>/api/v1/task/<task-id> \
  -H "Authorization: Bearer <token>"
```

## Client Libraries

### Python (zero dependencies)

```python
from client.claas_client import CLaaSClient

client = CLaaSClient("https://your-host", token="my-token")
task = client.submit("Build a REST API")
result = client.wait(task["task_id"], timeout=300)
print(result["result"])
```

### Bash CLI

```bash
CLAAS_URL=https://your-host CLAAS_TOKEN=my-token \
  bash client/claas-client.sh "Build a REST API"
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/submit` | Submit a task |
| GET | `/api/v1/task/:id` | Get task status |
| GET | `/api/v1/tasks` | List all tasks |
| GET | `/api/v1/health` | Fleet health check |
| GET | `/metrics` | Prometheus metrics |
| GET/POST | `/api/v1/tokens` | Token management (admin) |
| POST | `/api/v1/tokens/revoke` | Revoke a token (admin) |

See [docs/api-reference.md](docs/api-reference.md) for full details.

## Dashboard

Web UI at the nginx host with:
- **Submit page** — type a task, see real-time progress
- **Tasks page** — view all tasks with status and results
- **Sessions page** — browse S3 session data with analysis summaries
- **Tokens page** — admin token management (create/revoke)

## Monitoring

### Prometheus Metrics

The `/metrics` endpoint exposes:
- `claas_workers_total`, `claas_workers_idle`, `claas_workers_busy`
- `claas_tasks_submitted_total`, `claas_tasks_completed_total`, `claas_tasks_pending`
- `claas_dispatcher_uptime_seconds`, `claas_errors_total`

### Grafana Dashboard

Import `dashboard/grafana-dashboard.json` — includes worker status gauges, task throughput graphs, utilization gauge, and completion rate chart.

## Deployment

### AWS (CloudFormation)

Templates in `cloudformation/`:
- `claas-network.yaml` — VPC, subnets, security groups
- `claas-storage.yaml` — S3 bucket, EBS volumes
- `claas-worker.yaml` — EC2 spot instances (workers)
- `claas-nginx.yaml` — Nginx proxy with TLS

Docker images:
- `Dockerfile.dispatcher` — dispatcher with CLaaS API
- `Dockerfile.golden` — worker golden image with Claude Code

See [docs/aws-deploy.md](docs/aws-deploy.md) for step-by-step instructions.

## Operational Scripts

| Script | Purpose |
|--------|---------|
| `scripts/fleet-heal.sh` | Self-healing fleet monitor (cron) |
| `scripts/auto-scale.sh` | Scale workers based on queue depth |
| `scripts/reregister-workers.sh` | Re-register all workers |
| `scripts/refresh-worker-creds.sh` | Push fresh OAuth tokens |
| `scripts/recover-dispatcher.sh` | Full dispatcher recovery |
| `scripts/deploy-dashboard.sh` | Deploy/update dashboard |
| `scripts/api-submit.sh` | Submit task via CLI |
| `scripts/api-status.sh` | Check fleet/task status |

## Project Structure

```
claas/
  README.md
  dashboard/          # Web dashboard (Node.js)
    central-server.js
    auth.js
    grafana-dashboard.json
  client/             # Client libraries
    claas-client.py   # Python client + CLI
    claas-client.sh   # Bash client
  cloudformation/     # AWS infrastructure
  scripts/            # Operational scripts
  docs/               # Detailed documentation
    api-reference.md
    architecture.md
    aws-deploy.md
    quick-start.md
```

## License

MIT
