#!/usr/bin/env python3
"""CLaaS v2 API — Standalone Flask service for multi-worker dispatch.

Workers spec + implement inline (no pre-speccing bottleneck).
LRU assignment for even distribution across workers.
Heartbeat system for real-time visibility.
"""
import json, os, time, uuid, threading, subprocess
from pathlib import Path
from flask import Flask, request, jsonify, Response, send_from_directory

app = Flask(__name__)

# Unresponsive threshold (seconds without heartbeat)
UNRESPONSIVE_TIMEOUT = int(os.environ.get("CLAAS_UNRESPONSIVE_TIMEOUT", "120"))

# --- Config from environment ---
DATA_DIR = Path(os.environ.get("CLAAS_DATA_DIR", "/data"))
SSH_KEY_DIR = os.environ.get("CLAAS_SSH_KEY_DIR", "/tmp/ccc-keys")
TASKS_FILE = DATA_DIR / "claas-tasks.json"
EVENTS_FILE = DATA_DIR / "claas-events.jsonl"
HEARTBEATS_FILE = DATA_DIR / "claas-heartbeats.json"
WORKER_REGISTRY = DATA_DIR / "claas-workers.json"

# --- State ---
_tasks = {}
_workers = {}
_heartbeats = {}
_lock = threading.Lock()


def _load_state():
    global _tasks, _workers, _heartbeats
    if TASKS_FILE.exists():
        _tasks = json.loads(TASKS_FILE.read_text())
    if WORKER_REGISTRY.exists():
        _workers = json.loads(WORKER_REGISTRY.read_text())
    if HEARTBEATS_FILE.exists():
        _heartbeats = json.loads(HEARTBEATS_FILE.read_text())


def _save_tasks():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    TASKS_FILE.write_text(json.dumps(_tasks, indent=2))


def _save_workers():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    WORKER_REGISTRY.write_text(json.dumps(_workers, indent=2))


def _save_heartbeats():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    HEARTBEATS_FILE.write_text(json.dumps(_heartbeats, indent=2))


# Webhook URL for task completion notifications (Teams/Slack incoming webhook)
WEBHOOK_URL = os.environ.get("CLAAS_WEBHOOK_URL", "")
WEBHOOK_EVENTS = set(os.environ.get("CLAAS_WEBHOOK_EVENTS",
    "completed,failed,conflict,scale_up_needed").split(","))


def _send_webhook(entry):
    """Send event to configured webhook (Teams/Slack)."""
    if not WEBHOOK_URL or entry.get("type") not in WEBHOOK_EVENTS:
        return
    try:
        import urllib.request
        etype = entry.get("type", "unknown")
        task_id = entry.get("task_id", "")
        worker = entry.get("worker", "")
        pr_url = entry.get("pr_url", "")
        text = f"**CLaaS {etype}** | task:{task_id} worker:{worker}"
        if pr_url:
            text += f" | [PR]({pr_url})"
        payload = json.dumps({"text": text}).encode()
        req = urllib.request.Request(WEBHOOK_URL, data=payload,
            headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        pass


def _emit_event(event_type, data):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    entry = {"type": event_type, "timestamp": time.time(), **data}
    with open(EVENTS_FILE, "a") as f:
        f.write(json.dumps(entry) + "\n")
    threading.Thread(target=_send_webhook, args=(entry,), daemon=True).start()


def _pick_worker():
    """LRU assignment: pick the worker idle longest, break ties by lowest completions."""
    idle = [(name, w) for name, w in _workers.items() if w.get("status") == "idle"]
    if not idle:
        return None
    idle.sort(key=lambda x: (x[1].get("last_completed_at", 0), x[1].get("completions", 0)))
    return idle[0][0]


import base64

# Worker-side script (deployed to workers via SCP)
WORKER_SCRIPT = os.environ.get("CLAAS_WORKER_SCRIPT",
    str(Path(__file__).parent / "claas-worker-run.sh"))
TARGET_REPO = os.environ.get("CLAAS_TARGET_REPO", "altarr/boothapp")
TARGET_BRANCH = os.environ.get("CLAAS_TARGET_BRANCH", "main")
DISPATCHER_PRIVATE_IP = os.environ.get("CLAAS_DISPATCHER_PRIVATE_IP", "localhost")


def _get_oauth_env():
    """Read fresh OAuth token from dispatcher's credentials file."""
    creds_path = Path.home() / ".claude" / ".credentials.json"
    if creds_path.exists():
        try:
            creds = json.loads(creds_path.read_text())
            token = creds.get("claudeAiOauth", {}).get("accessToken", "")
            if token:
                return token
        except Exception:
            pass
    return ""


def _dispatch_to_worker(task_id, worker_name):
    """SCP worker script + task prompt to worker, execute with env vars.

    Worker handles full lifecycle: pull → branch → claude -p with repo context →
    rebase → push → PR → report back via /api/v1/task/<id>/result.
    No spec generation on dispatcher — workers are self-sufficient.
    """
    task = _tasks[task_id]
    worker = _workers[worker_name]
    ip = worker.get("private_ip") or worker.get("public_ip", "")
    key_path = worker.get("ssh_key", os.path.join(SSH_KEY_DIR, f"{worker_name}.pem"))

    task["status"] = "dispatched"
    task["worker"] = worker_name
    task["dispatched_at"] = time.time()
    _workers[worker_name]["status"] = "busy"
    _workers[worker_name]["current_task"] = task_id
    _save_tasks()
    _save_workers()
    _emit_event("dispatched", {"task_id": task_id, "worker": worker_name})

    def _run():
        try:
            ssh_base = (f'ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 '
                        f'-i {key_path} ubuntu@{ip}')
            oauth_token = _get_oauth_env()

            # Step 1: SCP worker script to host, then into container
            subprocess.run(
                f'scp -o StrictHostKeyChecking=no -i {key_path} '
                f'{WORKER_SCRIPT} ubuntu@{ip}:/tmp/claas-worker-run.sh',
                shell=True, capture_output=True, timeout=30)
            subprocess.run(
                f'{ssh_base} "docker cp /tmp/claas-worker-run.sh '
                f'claude-portable:/tmp/claas-worker-run.sh"',
                shell=True, capture_output=True, timeout=30)

            # Step 2: Write task prompt to file via base64 (avoids quoting issues)
            prompt_b64 = base64.b64encode(task["prompt"].encode()).decode()
            subprocess.run(
                f'{ssh_base} "echo {prompt_b64} | base64 -d | '
                f'docker exec -i claude-portable tee /tmp/claas-task-prompt.txt > /dev/null"',
                shell=True, capture_output=True, timeout=30)

            # Step 3: Build env vars for worker script
            target_repo = task.get("repo") or TARGET_REPO
            target_branch = task.get("base_branch") or TARGET_BRANCH
            oauth_env = f'-e CLAUDE_OAUTH_ACCESS_TOKEN={oauth_token} ' if oauth_token else ''

            env_setup = (
                f'export TASK_ID={task_id} && '
                f'export TASK_PROMPT="$(cat /tmp/claas-task-prompt.txt)" && '
                f'export DISPATCHER_URL=http://{DISPATCHER_PRIVATE_IP}:8080 && '
                f'export TARGET_REPO={target_repo} && '
                f'export TARGET_BRANCH={target_branch} && '
                f'export WORKER_NAME={worker_name}'
            )
            # Base64-encode the full command to avoid SSH quoting hell
            full_cmd = f'{env_setup} && bash /tmp/claas-worker-run.sh'
            cmd_b64 = base64.b64encode(full_cmd.encode()).decode()

            # Step 4: Execute on worker
            result = subprocess.run(
                f'{ssh_base} "echo {cmd_b64} | base64 -d | '
                f'docker exec -i {oauth_env}claude-portable bash 2>&1 | tail -50"',
                shell=True, capture_output=True, text=True, timeout=720)
            output = result.stdout[-2000:] if result.stdout else result.stderr[-2000:]

            # Worker reports back via /task/<id>/result callback. Only update
            # if still "dispatched" (worker hasn't reported yet).
            with _lock:
                if task.get("status") == "dispatched":
                    task["status"] = "completed" if result.returncode == 0 else "failed"
                    task["completed_at"] = time.time()
                    task["output"] = output
                _workers[worker_name]["status"] = "idle"
                _workers[worker_name]["current_task"] = None
                _workers[worker_name]["last_completed_at"] = time.time()
                _workers[worker_name]["completions"] = _workers[worker_name].get("completions", 0) + 1
                _save_tasks()
                _save_workers()
                _emit_event("worker_finished", {
                    "task_id": task_id, "worker": worker_name,
                    "exit_code": result.returncode,
                    "final_status": task.get("status"),
                })
        except Exception as e:
            with _lock:
                if task.get("status") == "dispatched":
                    task["status"] = "failed"
                    task["completed_at"] = time.time()
                    task["output"] = str(e)
                _workers[worker_name]["status"] = "idle"
                _workers[worker_name]["current_task"] = None
                _save_tasks()
                _save_workers()
                _emit_event("failed", {
                    "task_id": task_id, "worker": worker_name,
                    "error": str(e),
                })

    threading.Thread(target=_run, daemon=True).start()


# --- API Routes ---

@app.route("/api/v1/health")
def health():
    idle = sum(1 for w in _workers.values() if w.get("status") == "idle")
    busy = sum(1 for w in _workers.values() if w.get("status") == "busy")
    pending = sum(1 for t in _tasks.values() if t.get("status") == "pending")
    return jsonify({
        "status": "running",
        "workers_idle": idle,
        "workers_busy": busy,
        "pending_tasks": pending,
        "total_workers": len(_workers),
    })


@app.route("/api/v1/submit", methods=["POST"])
def submit():
    data = request.json or {}
    prompt = data.get("prompt") or data.get("text", "")
    if not prompt:
        return jsonify({"error": "prompt is required"}), 400

    repo = data.get("repo", "")
    base_branch = data.get("base_branch", "main")

    task_id = str(uuid.uuid4())[:8]
    with _lock:
        _tasks[task_id] = {
            "id": task_id,
            "prompt": prompt,
            "repo": repo,
            "base_branch": base_branch,
            "status": "pending",
            "created_at": time.time(),
            "worker": None,
            "output": None,
        }
        _save_tasks()
        _emit_event("submitted", {"task_id": task_id, "prompt": prompt[:200]})

        worker = _pick_worker()
        if worker:
            _dispatch_to_worker(task_id, worker)

    return jsonify({"task_id": task_id, "status": _tasks[task_id]["status"]}), 201


@app.route("/api/v1/task/<task_id>")
def get_task(task_id):
    task = _tasks.get(task_id)
    if not task:
        return jsonify({"error": "not found"}), 404
    return jsonify(task)


@app.route("/api/v1/tasks")
def list_tasks():
    return jsonify(list(_tasks.values()))


@app.route("/api/v1/workers")
def list_workers():
    return jsonify(_workers)


@app.route("/api/v1/workers/register", methods=["POST"])
def register_worker():
    data = request.json or {}
    name = data.get("name", "")
    if not name:
        return jsonify({"error": "name is required"}), 400
    with _lock:
        _workers[name] = {
            "name": name,
            "private_ip": data.get("private_ip", ""),
            "public_ip": data.get("public_ip", ""),
            "ssh_key": data.get("ssh_key", ""),
            "status": "idle",
            "current_task": None,
            "completions": _workers.get(name, {}).get("completions", 0),
            "last_completed_at": _workers.get(name, {}).get("last_completed_at", 0),
            "registered_at": time.time(),
        }
        _save_workers()
    _emit_event("worker_registered", {"worker": name})
    return jsonify({"status": "registered", "worker": name}), 201


@app.route("/api/v1/task/<task_id>/result", methods=["POST"])
def receive_task_result(task_id):
    """Callback endpoint for workers to report task results."""
    task = _tasks.get(task_id)
    if not task:
        return jsonify({"error": "not found"}), 404
    data = request.json or {}
    with _lock:
        task["status"] = data.get("status", "completed")
        task["completed_at"] = time.time()
        task["output"] = data.get("output", "")
        if data.get("pr_url"):
            task["pr_url"] = data["pr_url"]
        _save_tasks()
        _emit_event("task_result", {
            "task_id": task_id,
            "status": task["status"],
            "worker": data.get("worker", ""),
            "pr_url": data.get("pr_url", ""),
        })
    return jsonify({"status": "ok"})


@app.route("/api/v1/task/<task_id>/retry", methods=["POST"])
def retry_task(task_id):
    """Re-queue a failed or conflicting task for retry."""
    task = _tasks.get(task_id)
    if not task:
        return jsonify({"error": "not found"}), 404
    if task.get("status") not in ("failed", "conflict"):
        return jsonify({"error": f"task status is {task.get('status')}, expected failed or conflict"}), 400
    retries = task.get("retries", 0)
    if retries >= 3:
        return jsonify({"error": "max retries (3) reached"}), 400
    with _lock:
        task["status"] = "pending"
        task["retries"] = retries + 1
        task["worker"] = None
        task["output"] = None
        task.pop("completed_at", None)
        task.pop("dispatched_at", None)
        _save_tasks()
        _emit_event("task_retried", {"task_id": task_id, "retry": retries + 1})
        worker = _pick_worker()
        if worker:
            _dispatch_to_worker(task_id, worker)
    return jsonify({"task_id": task_id, "status": task["status"], "retries": task["retries"]})


@app.route("/api/v1/heartbeat", methods=["POST"])
def receive_heartbeat():
    data = request.json or {}
    worker = data.get("worker", "")
    if not worker:
        return jsonify({"error": "worker is required"}), 400
    with _lock:
        _heartbeats[worker] = {**data, "received_at": time.time()}
        _save_heartbeats()
    return jsonify({"status": "ok"})


@app.route("/api/v1/heartbeats")
def get_heartbeats():
    return jsonify(_heartbeats)


@app.route("/api/v1/events")
def get_events():
    """Return last 100 events as JSON array."""
    if not EVENTS_FILE.exists():
        return jsonify([])
    lines = EVENTS_FILE.read_text().strip().split("\n")[-100:]
    events = [json.loads(line) for line in lines if line.strip()]
    return jsonify(events)


@app.route("/api/v1/events/stream")
def event_stream():
    """SSE stream of events for live dashboard."""
    def generate():
        last_pos = 0
        while True:
            if EVENTS_FILE.exists():
                with open(EVENTS_FILE) as f:
                    f.seek(last_pos)
                    new_lines = f.readlines()
                    last_pos = f.tell()
                for line in new_lines:
                    if line.strip():
                        yield f"data: {line.strip()}\n\n"
            time.sleep(2)
    return Response(generate(), mimetype="text/event-stream")


@app.route("/api/v1/costs")
def get_costs():
    """Enhanced cost tracking with uptime and budget info."""
    running = len([w for w in _workers.values() if w.get("status") in ("idle", "busy")])
    spot_rate = float(os.environ.get("CLAAS_SPOT_RATE", "0.025"))  # per hour
    hourly = running * spot_rate
    completed = sum(1 for t in _tasks.values() if t.get("status") == "completed")
    failed = sum(1 for t in _tasks.values() if t.get("status") == "failed")
    return jsonify({
        "running_workers": running,
        "total_workers": len(_workers),
        "spot_rate_usd": spot_rate,
        "hourly_cost_usd": round(hourly, 3),
        "daily_estimate_usd": round(hourly * 24, 2),
        "tasks_completed": completed,
        "tasks_failed": failed,
        "cost_per_task_usd": round(hourly / max(completed, 1), 3),
        "budget_daily_usd": float(os.environ.get("CLAAS_BUDGET_DAILY", "50")),
        "budget_hard_stop_usd": float(os.environ.get("CLAAS_BUDGET_HARD_STOP", "100")),
    })


# --- Auto-scale config ---
_autoscale_config = {
    "enabled": os.environ.get("CLAAS_AUTOSCALE", "false").lower() == "true",
    "min_workers": int(os.environ.get("CLAAS_MIN_WORKERS", "2")),
    "max_workers": int(os.environ.get("CLAAS_MAX_WORKERS", "10")),
    "idle_timeout_minutes": int(os.environ.get("CLAAS_IDLE_TIMEOUT_MIN", "15")),
    "scale_check_interval": int(os.environ.get("CLAAS_SCALE_INTERVAL", "60")),
}


@app.route("/api/v1/autoscale")
def get_autoscale():
    """Return current auto-scale configuration and state."""
    pending = sum(1 for t in _tasks.values() if t.get("status") == "pending")
    idle = sum(1 for w in _workers.values() if w.get("status") == "idle")
    busy = sum(1 for w in _workers.values() if w.get("status") == "busy")
    return jsonify({
        **_autoscale_config,
        "current_state": {
            "total": len(_workers),
            "idle": idle,
            "busy": busy,
            "pending_tasks": pending,
            "would_scale_up": pending > 0 and idle == 0 and len(_workers) < _autoscale_config["max_workers"],
            "would_scale_down": idle > _autoscale_config["min_workers"],
        }
    })


@app.route("/api/v1/autoscale", methods=["POST"])
def update_autoscale():
    """Update auto-scale configuration at runtime."""
    data = request.json or {}
    for key in ("enabled", "min_workers", "max_workers", "idle_timeout_minutes"):
        if key in data:
            _autoscale_config[key] = data[key]
    _emit_event("autoscale_config_updated", _autoscale_config)
    return jsonify(_autoscale_config)


# --- Dashboard route ---
DASHBOARD_DIR = os.environ.get("CLAAS_DASHBOARD_DIR", "/opt/claude-portable/dashboard")

@app.route("/dashboard")
@app.route("/dashboard/")
def dashboard():
    return send_from_directory(DASHBOARD_DIR, "claas-dashboard.html")


# --- Dispatch loop: check for pending tasks every 10s ---
MAX_RETRIES = int(os.environ.get("CLAAS_MAX_RETRIES", "3"))


def _dispatch_loop():
    while True:
        time.sleep(10)
        with _lock:
            # Dispatch pending tasks
            pending = [t for t in _tasks.values() if t.get("status") == "pending"]
            for task in pending:
                worker = _pick_worker()
                if worker:
                    _dispatch_to_worker(task["id"], worker)

            # Auto-retry conflict tasks (after a cooldown to let blocking PRs merge)
            conflicts = [t for t in _tasks.values()
                         if t.get("status") == "conflict"
                         and t.get("retries", 0) < MAX_RETRIES
                         and (time.time() - t.get("completed_at", 0)) > 60]
            for task in conflicts:
                task["status"] = "pending"
                task["retries"] = task.get("retries", 0) + 1
                task["worker"] = None
                task["output"] = None
                task.pop("completed_at", None)
                task.pop("dispatched_at", None)
                _save_tasks()
                _emit_event("auto_retry_conflict", {
                    "task_id": task["id"],
                    "retry": task["retries"],
                })


# --- Unresponsive detection: mark workers silent >120s ---
def _unresponsive_loop():
    while True:
        time.sleep(30)
        now = time.time()
        with _lock:
            for name, w in _workers.items():
                if w.get("status") != "busy":
                    continue
                hb = _heartbeats.get(name)
                last_seen = (hb or {}).get("received_at", 0)
                dispatched_at = 0
                if w.get("current_task"):
                    t = _tasks.get(w["current_task"], {})
                    dispatched_at = t.get("dispatched_at", 0)
                # Use the later of heartbeat or dispatch time
                last_activity = max(last_seen, dispatched_at)
                if last_activity > 0 and (now - last_activity) > UNRESPONSIVE_TIMEOUT:
                    w["status"] = "unresponsive"
                    _save_workers()
                    _emit_event("worker_unresponsive", {"worker": name, "silent_seconds": int(now - last_activity)})


# --- Auto-scale loop: check fleet sizing every 60s ---
def _autoscale_loop():
    while True:
        time.sleep(_autoscale_config.get("scale_check_interval", 60))
        if not _autoscale_config.get("enabled"):
            continue
        now = time.time()
        with _lock:
            pending = sum(1 for t in _tasks.values() if t.get("status") == "pending")
            idle_workers = [(n, w) for n, w in _workers.items() if w.get("status") == "idle"]
            busy = sum(1 for w in _workers.values() if w.get("status") == "busy")
            total = len(_workers)
            min_w = _autoscale_config["min_workers"]
            max_w = _autoscale_config["max_workers"]
            idle_timeout = _autoscale_config["idle_timeout_minutes"] * 60

            # Scale-down: mark long-idle workers for removal (above minimum)
            if len(idle_workers) > min_w:
                idle_workers.sort(key=lambda x: x[1].get("last_completed_at", 0))
                for name, w in idle_workers[min_w:]:
                    last_active = max(
                        w.get("last_completed_at", 0),
                        w.get("registered_at", 0)
                    )
                    if last_active > 0 and (now - last_active) > idle_timeout:
                        w["status"] = "scaled_down"
                        _save_workers()
                        _emit_event("scale_down", {
                            "worker": name,
                            "idle_minutes": int((now - last_active) / 60),
                            "reason": "idle_timeout",
                        })

            # Scale-up signal: emit event when tasks are queued but no workers available
            if pending > 0 and len(idle_workers) == 0 and total < max_w:
                _emit_event("scale_up_needed", {
                    "pending_tasks": pending,
                    "current_workers": total,
                    "max_workers": max_w,
                })


if __name__ == "__main__":
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    _load_state()
    threading.Thread(target=_dispatch_loop, daemon=True).start()
    threading.Thread(target=_unresponsive_loop, daemon=True).start()
    threading.Thread(target=_autoscale_loop, daemon=True).start()
    print(f"CLaaS v2 API starting on :8080 ({len(_workers)} workers, {len(_tasks)} tasks)")
    app.run(host="0.0.0.0", port=8080)
