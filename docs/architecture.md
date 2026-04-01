# CLaaS Architecture

Claude-as-a-Service (CLaaS) is a multi-tenant HTTP API that manages a fleet of Claude Code workers on EC2.

## System Diagram

```
                          ┌─────────────────┐
                          │   Nginx Proxy    │
                          │  (HTTPS + Auth)  │
                          │  <nginx-host>    │
                          └────────┬────────┘
                                   │
                          ┌────────▼────────┐
                          │   Dispatcher     │
                          │  (git-dispatch)  │
                          │  :8080 internal  │
                          ├─────────────────┤
                          │ CLaaS API Layer  │
                          │ Spec Generator   │
                          │ Worker Router    │
                          │ Task Persistence │
                          │ Token Auth       │
                          └────────┬────────┘
                                   │ SSH
               ┌───────────────────┼───────────────────┐
               │                   │                   │
        ┌──────▼──────┐    ┌──────▼──────┐    ┌──────▼──────┐
        │  Worker 1   │    │  Worker 2   │    │  Worker N   │
        │  (EC2 spot) │    │  (EC2 spot) │    │  (EC2 spot) │
        │  claude -p  │    │  claude -p  │    │  claude -p  │
        └─────────────┘    └─────────────┘    └─────────────┘
```

## Components

### Nginx Proxy

- Public-facing HTTPS endpoint
- Cookie-based auth for dashboard UI
- Proxies `/api/` requests to dispatcher:8080
- TLS termination

### Dispatcher

Single EC2 instance running `git-dispatch.py` — a Python HTTP server with:

- **CLaaS API Layer** — `/api/v1/*` endpoints for task submission, status polling, token management
- **Spec Generator** — takes task text, runs `claude -p` to generate a structured spec (feature description, implementation plan, branch name)
- **Worker Router** — selects an idle worker, SCPs spec artifacts, SSHs to start `claude -p` on the worker
- **Task Persistence** — tasks stored in `/data/claas-tasks.json` (survives container restarts)
- **Token Auth** — multi-tenant bearer tokens, each scoped to a project. Tokens persisted to `/data/claas-tokens.json`
- **Fleet Monitor** — background thread that tracks worker health, detects stale workers, issues stop commands for cost savings

### Workers

EC2 spot instances running the golden Docker image (`hackathon26/worker:latest` from ECR). Each worker:

- Runs Claude Code 2.1.77 in headless mode (`claude -p`)
- Has GitHub credentials (grobomo token) for creating branches and PRs
- Has Claude OAuth credentials for API access
- Reports status to dispatcher via `/worker/done`, `/worker/idle`, `/worker/heartbeat`
- Is stateless — can be terminated and replaced at any time from the golden image

### Dashboard

Node.js web UI (`central-server.js` + `auth.js`) on port 8082:

- `/submit` — web form for submitting tasks with live progress tracking
- `/tasks` — task list with status
- `/tokens` — admin token management
- Authentication via scrypt-hashed passwords with timing-safe comparison

## Data Flow

### Task Submission

```
1. Client → POST /api/v1/submit {text, token}
2. Dispatcher validates token, creates task record (PENDING)
3. Dispatcher writes relay file to /data/relay-repo/requests/pending/{id}.json
4. Relay poll loop picks up pending file
5. Dispatcher runs `claude -p` to generate spec from task text
6. Dispatcher picks idle worker from fleet roster
7. Dispatcher SCPs spec files to worker via SSH
8. Dispatcher SSHs to worker, starts `claude -p` with spec context
9. Worker creates branch, implements task, creates PR
10. Worker reports completion to dispatcher (POST /worker/done)
11. Dispatcher updates task state to COMPLETED with result
12. Client polls GET /api/v1/task/{id} → sees COMPLETED + result
```

### Worker Lifecycle

```
1. EC2 instance launches from golden AMI / Docker image
2. Container starts with baked credentials + config
3. Worker registers with dispatcher (POST /worker/register)
4. Worker enters idle state, waits for tasks
5. Dispatcher SSHs in with task spec
6. Worker runs `claude -p`, creates PR
7. Worker reports /worker/done → back to idle
8. If idle too long, fleet monitor marks "stopping"
9. Re-registration resets to idle (patched)
```

## Infrastructure

| Component | Instance | IP | Port |
|-----------|----------|-----|------|
| Nginx | EC2 | <nginx-host> | 443 (HTTPS) |
| Dispatcher | EC2 | <dispatcher-host> | 8080 (internal) |
| Dashboard | Container | (dispatcher) | 8082 (internal) |
| Workers | EC2 spot ×10 | Private IPs | SSH only |

- **AWS Account:** 752266476357 (us-east-2)
- **ECR:** `752266476357.dkr.ecr.us-east-2.amazonaws.com/hackathon26/worker`
- **Secrets Manager:** `hackathon26/claude-oauth`, `hackathon26/github-token`
- **S3:** `hackathon26-state-752266476357` (state), `boothapp-sessions-752266476357` (sessions)

## Multi-Tenancy

Each bearer token maps to a project name. Tasks are tagged with their project and isolated:

- Token A (project: "team-alpha") can only see team-alpha tasks
- Token B (project: "team-beta") can only see team-beta tasks
- Admin token can see all tokens but not all tasks
- Workers are shared across projects (first available dispatched)
