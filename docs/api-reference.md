# CLaaS API Reference

Claude-as-a-Service (CLaaS) — multi-tenant HTTP API for submitting tasks to a Claude Code worker fleet.

**Base URL:** `https://<nginx-host>/` (proxied to dispatcher:8080)

## Authentication

All `/api/v1/` endpoints require a Bearer token in the `Authorization` header:

```
Authorization: Bearer <token>
```

Tokens are scoped to a **project**. Each token can only see tasks belonging to its project. The admin token (`hackathon26`) can manage tokens and see fleet health.

---

## Endpoints

### POST /api/v1/submit

Submit a task to the fleet. The dispatcher generates a spec, picks an idle worker, and dispatches.

**Request:**

```json
{
  "text": "Build a REST API that returns weather data",
  "sender": "optional-sender-name",
  "priority": "normal"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | yes | Task description. Be specific — this becomes the Claude prompt. |
| `sender` | string | no | Sender identifier (defaults to project name). |
| `priority` | string | no | `normal` (default) or `high`. |

**Response (201):**

```json
{
  "task_id": "dcc29556-20c9-420a-af98-385dee70750d",
  "status": "pending",
  "poll_url": "/api/v1/task/dcc29556-20c9-420a-af98-385dee70750d",
  "project": "my-project"
}
```

**Example:**

```bash
curl -X POST https://<nginx-host>/api/v1/submit \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"text": "What is the capital of France?"}'
```

---

### GET /api/v1/task/{id}

Poll a single task's status. Returns the full task object including result when completed.

**Response (200):**

```json
{
  "id": "dcc29556-20c9-420a-af98-385dee70750d",
  "text": "What is the capital of France?",
  "state": "COMPLETED",
  "result": "Paris",
  "worker": "hackathon26-worker-4",
  "project": "my-project",
  "created_at": "2026-04-01T09:35:58Z",
  "completed_at": "2026-04-01T09:38:12Z",
  "error": null,
  "current_step": "worker_completed",
  "events": [
    {"ts": "2026-04-01T09:35:58Z", "event": "submitted", "detail": "Task received by dispatcher"},
    {"ts": "2026-04-01T09:35:58Z", "event": "queued", "detail": "Written to dispatch queue"},
    {"ts": "2026-04-01T09:36:02Z", "event": "generating_spec", "detail": "Generating spec..."},
    {"ts": "2026-04-01T09:36:15Z", "event": "spec_ready", "detail": "Spec generated"},
    {"ts": "2026-04-01T09:36:16Z", "event": "dispatched", "detail": "Dispatched to worker-4"},
    {"ts": "2026-04-01T09:38:12Z", "event": "worker_completed", "detail": "Worker completed task"}
  ]
}
```

**Task States:**

| State | Description |
|-------|-------------|
| `PENDING` | Task received, waiting for dispatch |
| `DISPATCHED` | Sent to a worker, in progress |
| `COMPLETED` | Worker finished, result available |
| `FAILED` | Worker encountered an error |

**Example:**

```bash
curl https://<nginx-host>/api/v1/task/dcc29556-20c9-420a-af98-385dee70750d \
  -H "Authorization: Bearer <token>"
```

---

### GET /api/v1/tasks

List all tasks for the authenticated project.

**Response (200):**

```json
{
  "project": "my-project",
  "tasks": [
    {
      "id": "dcc29556-...",
      "state": "COMPLETED",
      "text": "What is the capital of France?",
      "result": "Paris",
      "worker": "hackathon26-worker-4",
      "project": "my-project"
    }
  ],
  "count": 1
}
```

**Example:**

```bash
curl https://<nginx-host>/api/v1/tasks \
  -H "Authorization: Bearer <token>"
```

---

### GET /api/v1/health

Fleet health check. Returns service status and worker availability.

**Response (200):**

```json
{
  "service": "Claude-as-a-Service (CLaaS)",
  "status": "running",
  "fleet_size": 10,
  "idle_workers": 8,
  "version": "1.0.0-hackathon"
}
```

**Example:**

```bash
curl https://<nginx-host>/api/v1/health \
  -H "Authorization: Bearer <token>"
```

---

### GET /api/v1/tokens

List all registered tokens. **Requires admin token.**

**Response (200):**

```json
{
  "tokens": [
    {"token": "hackathon26", "project": "hackathon26"},
    {"token": "abc123", "project": "team-alpha"}
  ]
}
```

**Example:**

```bash
curl https://<nginx-host>/api/v1/tokens \
  -H "Authorization: Bearer hackathon26"
```

---

### POST /api/v1/tokens

Create a new bearer token for a project. **Requires admin token.**

**Request:**

```json
{
  "token": "my-secret-token",
  "project": "team-alpha"
}
```

**Response (201):**

```json
{
  "ok": true,
  "token": "my-secret-token",
  "project": "team-alpha"
}
```

**Example:**

```bash
curl -X POST https://<nginx-host>/api/v1/tokens \
  -H "Authorization: Bearer hackathon26" \
  -H "Content-Type: application/json" \
  -d '{"token": "my-secret-token", "project": "team-alpha"}'
```

---

### POST /api/v1/tokens/revoke

Revoke a bearer token. **Requires admin token.** Cannot revoke the admin token itself.

**Request:**

```json
{
  "token": "my-secret-token"
}
```

**Response (200):**

```json
{
  "ok": true,
  "revoked": "my-secret-token"
}
```

**Example:**

```bash
curl -X POST https://<nginx-host>/api/v1/tokens/revoke \
  -H "Authorization: Bearer hackathon26" \
  -H "Content-Type: application/json" \
  -d '{"token": "my-secret-token"}'
```

---

## Error Responses

All errors return JSON with an `error` field:

```json
{"error": "Missing Authorization: Bearer <token>"}
```

| HTTP Code | Meaning |
|-----------|---------|
| 400 | Bad request (missing required fields) |
| 401 | Missing or malformed Authorization header |
| 403 | Invalid token or insufficient permissions |
| 404 | Task not found |

## CORS

All `/api/v1/` endpoints support CORS with `Access-Control-Allow-Origin: *`. Preflight `OPTIONS` requests are handled automatically.

## Rate Limits

No rate limits currently enforced. Fleet throughput is limited by worker availability (check `/api/v1/health` for `idle_workers`).

## Task Lifecycle

```
Submit (POST /api/v1/submit)
  → PENDING (queued for dispatch)
  → generating_spec (dispatcher creates spec with Claude)
  → spec_ready (spec generated)
  → DISPATCHED (sent to idle worker via SSH)
  → worker_completed / worker_failed
  → COMPLETED or FAILED (result available via GET /api/v1/task/{id})
```

Typical turnaround: 2-5 minutes depending on task complexity.
