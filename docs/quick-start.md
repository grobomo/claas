# CLaaS Quick Start

Get a CLaaS instance running locally with docker in under 5 minutes.

## Prerequisites

- Docker and docker-compose installed
- Claude API credentials (OAuth token or API key)
- GitHub personal access token (for workers to create PRs)

## 1. Clone the repos

```bash
git clone https://github.com/grobomo/claas.git
git clone https://github.com/grobomo/claude-portable.git
```

## 2. Set up credentials

Create a `.env` file in the `claude-portable/` directory:

```bash
# Claude OAuth credentials (get from ~/.claude/.credentials.json)
CLAUDE_OAUTH_TOKEN=sk-ant-oat01-...

# GitHub token for workers to create branches/PRs
GITHUB_TOKEN=ghp_...

# Target repo for worker PRs (org/repo format)
TARGET_REPO=your-org/your-repo
```

## 3. Build the dispatcher image

```bash
cd claude-portable
docker build -t claas-dispatcher -f Dockerfile .
```

## 4. Start the dispatcher

```bash
docker run -d \
  --name claas-dispatcher \
  -p 8080:8080 \
  -v claas-data:/data \
  -e CONTINUOUS_CLAUDE_ENABLED=0 \
  -e DISPATCHER_DASHBOARD_PORT=8080 \
  -e GITHUB_TOKEN=$GITHUB_TOKEN \
  claas-dispatcher \
  python3 scripts/git-dispatch.py
```

## 5. Verify it's running

```bash
curl http://localhost:8080/api/v1/health \
  -H "Authorization: Bearer hackathon26"
```

Expected response:

```json
{
  "service": "Claude-as-a-Service (CLaaS)",
  "status": "running",
  "fleet_size": 0,
  "idle_workers": 0,
  "version": "1.0.0-hackathon"
}
```

## 6. Register a worker

For local testing, you can run a worker container on the same host:

```bash
# Build worker image
docker build -t claas-worker -f Dockerfile .

# Start worker
docker run -d \
  --name claas-worker-1 \
  -e GITHUB_TOKEN=$GITHUB_TOKEN \
  -e CLAUDE_OAUTH_TOKEN=$CLAUDE_OAUTH_TOKEN \
  claas-worker \
  sleep infinity
```

Register it with the dispatcher:

```bash
# Get the worker's IP
WORKER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' claas-worker-1)

# Register
curl -X POST http://localhost:8080/worker/register \
  -H "Content-Type: application/json" \
  -d "{\"worker_id\": \"worker-1\", \"ip\": \"$WORKER_IP\", \"role\": \"worker\"}"
```

## 7. Submit a task

```bash
curl -X POST http://localhost:8080/api/v1/submit \
  -H "Authorization: Bearer hackathon26" \
  -H "Content-Type: application/json" \
  -d '{"text": "Create a hello world Python script"}'
```

## 8. Poll for results

```bash
# Using the Python client
python3 hackathon26/scripts/fleet/claas-client.py status <task-id>

# Or wait for completion
python3 hackathon26/scripts/fleet/claas-client.py wait <task-id>
```

## Using the Python Client Library

```python
from claas_client import CLaaSClient

client = CLaaSClient("http://localhost:8080", token="hackathon26")

# Submit and wait
task = client.submit("Build a REST API that returns weather data")
result = client.wait(task["task_id"], timeout=300)
print(result["state"])   # COMPLETED
print(result["result"])  # Worker's output
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAAS_URL` | `https://<nginx-host>` | CLaaS API base URL |
| `CLAAS_TOKEN` | `hackathon26` | Bearer token for authentication |
| `CONTINUOUS_CLAUDE_ENABLED` | `0` | Set to `1` to enable continuous dispatch mode |
| `DISPATCHER_DASHBOARD_PORT` | `8080` | Port for the dispatcher HTTP server |
| `GITHUB_TOKEN` | — | GitHub PAT for worker PR creation |

## Next Steps

- [AWS Deployment Guide](aws-deploy.md) — deploy a fleet on EC2
- [API Reference](api-reference.md) — full endpoint documentation
- [Architecture](architecture.md) — system design and data flow
