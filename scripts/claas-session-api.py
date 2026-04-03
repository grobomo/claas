#!/usr/bin/env python3
"""CLaaS Thin Client — Session API extension.

Adds interactive session support to CLaaS API. Sessions maintain conversation
context between a remote TUI and a CCC worker. The command channel lets workers
request local operations (file reads, searches, script runs) from the user's
machine via a polling agent.

Mount this as a Flask blueprint on the CLaaS API, or run standalone on :8081.

Session endpoints:
  POST   /api/v1/session                  — create session
  POST   /api/v1/session/{id}/prompt      — send user prompt
  GET    /api/v1/session/{id}/stream      — SSE response stream
  GET    /api/v1/session/{id}/status      — session state
  DELETE /api/v1/session/{id}             — end session
  GET    /api/v1/sessions                 — list sessions

Command channel endpoints:
  POST   /api/v1/session/{id}/command     — worker requests local op
  GET    /api/v1/session/{id}/commands    — agent polls for pending commands
  POST   /api/v1/session/{id}/result      — agent returns command result
"""
import json, os, time, uuid, threading, base64, subprocess
from pathlib import Path

try:
    from flask import Flask, Blueprint, request, jsonify, Response
except ImportError:
    print("Flask required: pip install flask")
    raise

bp = Blueprint("sessions", __name__)

# --- State ---
_sessions = {}
_session_lock = threading.Lock()
DATA_DIR = Path(os.environ.get("CLAAS_DATA_DIR", "/data"))
SESSIONS_FILE = DATA_DIR / "claas-sessions.json"
COMMAND_TIMEOUT = int(os.environ.get("CLAAS_COMMAND_TIMEOUT", "30"))

# CLaaS v2 API URL (the main dispatcher API that manages workers)
CLAAS_API_URL = os.environ.get("CLAAS_API_URL", "http://localhost:8080")
# Public-facing URL for command channel (what workers can reach)
SESSION_API_URL = os.environ.get("CLAAS_SESSION_API_URL", "http://localhost:8081")
# SSH config for direct worker dispatch (fallback / interactive mode)
SSH_KEY_DIR = os.environ.get("CLAAS_SSH_KEY_DIR", "/tmp/ccc-keys")
# Dispatch mode: "api" (CLaaS v2 fleet) or "local" (subprocess claude -p)
DISPATCH_MODE = os.environ.get("CLAAS_DISPATCH_MODE", "api")


def _save_sessions():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    SESSIONS_FILE.write_text(json.dumps(_sessions, indent=2, default=str))


def _load_sessions():
    global _sessions
    if SESSIONS_FILE.exists():
        try:
            _sessions = json.loads(SESSIONS_FILE.read_text())
        except Exception:
            _sessions = {}


# --- Server-side audit logging ---
AUDIT_FILE = DATA_DIR / "claas-session-audit.jsonl"


def _audit(event_type, session_id="", **kwargs):
    """Append an audit entry. Every API call is logged for security review."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    entry = {
        "timestamp": time.time(),
        "event": event_type,
        "session_id": session_id,
        **kwargs,
    }
    try:
        with open(AUDIT_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


# --- Session endpoints ---

@bp.route("/api/v1/session", methods=["POST"])
def create_session():
    """Create a new interactive session."""
    data = request.json or {}
    session_id = str(uuid.uuid4())[:8]
    working_dir = data.get("working_dir", "~")
    allowed_ops = data.get("allowed_ops", [
        "read_file", "list_dir", "search_files", "write_file", "run_script"
    ])

    with _session_lock:
        _sessions[session_id] = {
            "id": session_id,
            "created_at": time.time(),
            "status": "active",
            "working_dir": working_dir,
            "allowed_ops": allowed_ops,
            "messages": [],
            "pending_commands": [],
            "command_results": {},
            "response_chunks": [],
            "response_complete": False,
            "worker": None,
            "task_id": None,
        }
        _save_sessions()

    _audit("session_created", session_id, working_dir=working_dir, allowed_ops=allowed_ops)
    return jsonify({"session_id": session_id, "status": "active"}), 201


@bp.route("/api/v1/session/<session_id>/prompt", methods=["POST"])
def send_prompt(session_id):
    """Send a user prompt to the session. Dispatches to a worker."""
    session = _sessions.get(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404
    if session["status"] == "ended":
        return jsonify({"error": "session ended"}), 400

    data = request.json or {}
    prompt = data.get("prompt", "")
    if not prompt:
        return jsonify({"error": "prompt required"}), 400

    with _session_lock:
        session["messages"].append({
            "role": "user",
            "content": prompt,
            "timestamp": time.time(),
        })
        session["response_chunks"] = []
        session["response_complete"] = False
        session["status"] = "active"
        _save_sessions()

    _audit("prompt_sent", session_id, prompt_length=len(prompt))

    threading.Thread(
        target=_dispatch_session_prompt,
        args=(session_id, prompt),
        daemon=True
    ).start()

    return jsonify({"status": "dispatched", "session_id": session_id})


@bp.route("/api/v1/session/<session_id>/stream")
def stream_response(session_id):
    """SSE stream of response chunks for the TUI."""
    session = _sessions.get(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404

    def generate():
        last_idx = 0
        while True:
            chunks = session.get("response_chunks", [])
            while last_idx < len(chunks):
                chunk = chunks[last_idx]
                yield f"data: {json.dumps(chunk)}\n\n"
                last_idx += 1

            pending = session.get("pending_commands", [])
            for cmd in pending:
                if not cmd.get("_streamed"):
                    yield f"data: {json.dumps({'type': 'command_request', 'command': cmd})}\n\n"
                    cmd["_streamed"] = True

            if session.get("response_complete"):
                yield f"data: {json.dumps({'type': 'done'})}\n\n"
                break
            time.sleep(0.5)

    return Response(generate(), mimetype="text/event-stream")


@bp.route("/api/v1/session/<session_id>/status")
def session_status(session_id):
    session = _sessions.get(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404
    return jsonify({
        "id": session_id,
        "status": session["status"],
        "messages": len(session["messages"]),
        "pending_commands": len([c for c in session.get("pending_commands", [])
                                 if c.get("status") == "pending"]),
        "worker": session.get("worker"),
        "created_at": session["created_at"],
    })


@bp.route("/api/v1/session/<session_id>", methods=["DELETE"])
def end_session(session_id):
    session = _sessions.get(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404
    with _session_lock:
        session["status"] = "ended"
        _save_sessions()
    _audit("session_ended", session_id)
    return jsonify({"status": "ended"})


@bp.route("/api/v1/sessions")
def list_sessions():
    return jsonify([
        {"id": s["id"], "status": s["status"],
         "messages": len(s["messages"]), "created_at": s["created_at"]}
        for s in _sessions.values()
    ])


@bp.route("/api/v1/session/<session_id>/audit")
def session_audit(session_id):
    """Return audit log entries for a session. For security team review."""
    if not AUDIT_FILE.exists():
        return jsonify([])
    entries = []
    try:
        with open(AUDIT_FILE) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                entry = json.loads(line)
                if entry.get("session_id") == session_id:
                    entries.append(entry)
    except Exception:
        pass
    return jsonify(entries)


@bp.route("/api/v1/audit")
def full_audit():
    """Return full audit log (last 500 entries). For security team review."""
    if not AUDIT_FILE.exists():
        return jsonify([])
    entries = []
    try:
        with open(AUDIT_FILE) as f:
            for line in f:
                line = line.strip()
                if line:
                    entries.append(json.loads(line))
        return jsonify(entries[-500:])
    except Exception:
        return jsonify([])


# --- Command channel ---

@bp.route("/api/v1/session/<session_id>/command", methods=["POST"])
def request_command(session_id):
    """Worker requests a local operation from the agent.
    Blocks until the agent responds or timeout."""
    session = _sessions.get(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404

    data = request.json or {}
    op = data.get("operation", "")
    if op not in session.get("allowed_ops", []):
        _audit("command_blocked", session_id, operation=op, reason="not in allowed_ops")
        return jsonify({"error": f"operation '{op}' not allowed"}), 403

    cmd_id = str(uuid.uuid4())[:8]
    cmd = {
        "id": cmd_id,
        "operation": op,
        "args": data.get("args", {}),
        "status": "pending",
        "created_at": time.time(),
    }

    _audit("command_requested", session_id, operation=op, command_id=cmd_id,
           args_keys=list(data.get("args", {}).keys()))

    with _session_lock:
        session["pending_commands"].append(cmd)
        session["status"] = "waiting_command"
        _save_sessions()

    deadline = time.time() + COMMAND_TIMEOUT
    while time.time() < deadline:
        result = session.get("command_results", {}).get(cmd_id)
        if result:
            return jsonify({"command_id": cmd_id, "result": result})
        time.sleep(0.5)

    return jsonify({"command_id": cmd_id, "error": "timeout",
                     "message": f"Agent did not respond within {COMMAND_TIMEOUT}s"}), 408


@bp.route("/api/v1/session/<session_id>/commands")
def get_pending_commands(session_id):
    """Agent polls for pending commands."""
    session = _sessions.get(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404
    pending = [c for c in session.get("pending_commands", [])
               if c.get("status") == "pending"]
    return jsonify(pending)


@bp.route("/api/v1/session/<session_id>/result", methods=["POST"])
def submit_command_result(session_id):
    """Agent returns a command result."""
    session = _sessions.get(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404

    data = request.json or {}
    cmd_id = data.get("command_id", "")

    with _session_lock:
        for cmd in session.get("pending_commands", []):
            if cmd["id"] == cmd_id:
                cmd["status"] = "completed"
                cmd["completed_at"] = time.time()
                break

        session["command_results"][cmd_id] = {
            "result": data.get("result", ""),
            "error": data.get("error", ""),
            "completed_at": time.time(),
        }

        still_pending = [c for c in session.get("pending_commands", [])
                         if c.get("status") == "pending"]
        if not still_pending:
            session["status"] = "active"
        _save_sessions()

    _audit("command_result", session_id, command_id=cmd_id,
           has_error=bool(data.get("error")))
    return jsonify({"status": "ok"})


# --- Worker dispatch ---

def _build_system_prompt(session_id, session):
    """Build the system prompt that teaches the worker about the command channel.

    The worker runs as claude -p on an EC2 instance. It can't access the user's
    local files directly. Instead, it uses the command channel API: POST a command
    request, the session API holds the request, the user's local agent polls,
    executes, and returns the result. The curl call blocks until the agent responds.
    """
    api_url = SESSION_API_URL.rstrip("/")
    working_dir = session.get("working_dir", "~")
    allowed_ops = ", ".join(session.get("allowed_ops", []))

    return f"""You are Claude, running remotely via CLaaS (Claude-as-a-Service) thin client.
The user is on a remote machine. You CANNOT access their filesystem directly.
Instead, use the command channel API to request local operations.

IMPORTANT: The command channel is your ONLY way to interact with the user's machine.
Each command blocks (up to 30s) until the user's local agent executes it and returns the result.
The user's working directory is: {working_dir}
Allowed operations: {allowed_ops}

## Command Channel API

All commands use: POST {api_url}/api/v1/session/{session_id}/command
Content-Type: application/json

### Read a file
curl -s -X POST {api_url}/api/v1/session/{session_id}/command \\
  -H 'Content-Type: application/json' \\
  -d '{{"operation":"read_file","args":{{"path":"/absolute/path/to/file"}}}}'

### List directory
curl -s -X POST {api_url}/api/v1/session/{session_id}/command \\
  -H 'Content-Type: application/json' \\
  -d '{{"operation":"list_dir","args":{{"path":"/absolute/path/to/dir"}}}}'

### Search files (glob pattern + optional content grep)
curl -s -X POST {api_url}/api/v1/session/{session_id}/command \\
  -H 'Content-Type: application/json' \\
  -d '{{"operation":"search_files","args":{{"pattern":"*.py","path":"/dir","content":"search term"}}}}'

### Write a file
curl -s -X POST {api_url}/api/v1/session/{session_id}/command \\
  -H 'Content-Type: application/json' \\
  -d '{{"operation":"write_file","args":{{"path":"/absolute/path","content":"file contents here"}}}}'

### Run a command/script
curl -s -X POST {api_url}/api/v1/session/{session_id}/command \\
  -H 'Content-Type: application/json' \\
  -d '{{"operation":"run_script","args":{{"command":"npm test","cwd":"/project/dir"}}}}'

## Rules
- Always use absolute paths based on the user's working directory ({working_dir})
- Read files before modifying them
- The agent enforces path whitelist — requests outside allowed paths will be denied
- If a command times out, the agent may be offline — tell the user
- Show the user what you're doing (which files you're reading/writing, what commands you're running)
"""


def _build_full_prompt(session, prompt):
    """Build the full prompt with conversation history for the worker."""
    history = session.get("messages", [])
    if len(history) <= 1:
        return prompt

    # Include last 20 messages as context (skip the current one, it's the last)
    context_msgs = history[-21:-1] if len(history) > 1 else []
    if not context_msgs:
        return prompt

    context = "\n\n".join(
        f"{'User' if m['role'] == 'user' else 'Assistant'}: {m['content']}"
        for m in context_msgs
    )
    return f"""Previous conversation:
{context}

Current request:
{prompt}"""


def _http_post(url, data):
    """POST JSON to a URL, return parsed response."""
    import urllib.request, urllib.error
    body = json.dumps(data).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {"error": str(e)}


def _http_get(url):
    """GET a URL, return parsed response."""
    import urllib.request, urllib.error
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {"error": str(e)}


def _dispatch_session_prompt(session_id, prompt):
    """Dispatch a session prompt to a worker.

    Two modes:
    - "api": Submit to CLaaS v2 fleet (EC2 workers)
    - "local": Run claude -p as a local subprocess (no fleet needed)
    """
    session = _sessions.get(session_id)
    if not session:
        return

    if DISPATCH_MODE == "local":
        _dispatch_local(session_id, prompt)
    else:
        _dispatch_api(session_id, prompt)


def _dispatch_local(session_id, prompt):
    """Run claude -p locally as a subprocess. No fleet required.

    The system prompt teaches Claude about the command channel API,
    so it can request local file operations via curl to this server.
    This mode is ideal for development, demos, and single-user setups.
    """
    session = _sessions.get(session_id)
    if not session:
        return

    system_prompt = _build_system_prompt(session_id, session)
    full_prompt = _build_full_prompt(session, prompt)
    combined_prompt = f"{system_prompt}\n\n---\n\n{full_prompt}"

    with _session_lock:
        session["status"] = "dispatched"
        session["worker"] = "local"
        session["response_chunks"].append({
            "type": "status",
            "content": "Running locally (claude -p)...",
            "timestamp": time.time(),
        })

    _audit("dispatch_local", session_id, prompt_length=len(prompt))

    try:
        # Write prompt to temp file to avoid shell quoting issues
        import tempfile
        prompt_file = tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", delete=False, prefix="claas-prompt-"
        )
        prompt_file.write(combined_prompt)
        prompt_file.close()

        # Run claude -p with the prompt file as stdin
        result = subprocess.run(
            ["claude", "-p"],
            stdin=open(prompt_file.name),
            capture_output=True, text=True,
            timeout=600,  # 10 minute timeout
        )

        os.unlink(prompt_file.name)

        output = result.stdout or ""
        if result.stderr:
            output += "\n" + result.stderr[-1000:]

        with _session_lock:
            if output:
                session["response_chunks"].append({
                    "type": "text",
                    "content": output,
                    "timestamp": time.time(),
                })
            if result.returncode != 0:
                session["response_chunks"].append({
                    "type": "error",
                    "content": f"claude -p exited with code {result.returncode}",
                    "timestamp": time.time(),
                })
            session["messages"].append({
                "role": "assistant",
                "content": output or "(no output)",
                "timestamp": time.time(),
            })
            session["response_complete"] = True
            session["status"] = "active"
            _save_sessions()

    except subprocess.TimeoutExpired:
        with _session_lock:
            session["response_chunks"].append({
                "type": "error",
                "content": "Local claude -p timed out after 10 minutes",
                "timestamp": time.time(),
            })
            session["response_complete"] = True
            session["status"] = "active"
            _save_sessions()
    except FileNotFoundError:
        with _session_lock:
            session["response_chunks"].append({
                "type": "error",
                "content": "claude command not found. Install Claude Code: npm install -g @anthropic-ai/claude-code",
                "timestamp": time.time(),
            })
            session["response_complete"] = True
            session["status"] = "active"
            _save_sessions()
    except Exception as e:
        with _session_lock:
            session["response_chunks"].append({
                "type": "error",
                "content": f"Local dispatch error: {e}",
                "timestamp": time.time(),
            })
            session["response_complete"] = True
            session["status"] = "active"
            _save_sessions()


def _dispatch_api(session_id, prompt):
    """Dispatch via CLaaS v2 fleet API (original mode)."""
    session = _sessions.get(session_id)
    if not session:
        return

    system_prompt = _build_system_prompt(session_id, session)
    full_prompt = _build_full_prompt(session, prompt)
    combined_prompt = f"{system_prompt}\n\n---\n\n{full_prompt}"

    with _session_lock:
        session["response_chunks"].append({
            "type": "status",
            "content": "Finding available worker...",
            "timestamp": time.time(),
        })

    # Submit to CLaaS v2 API
    api_url = CLAAS_API_URL.rstrip("/")
    submit_resp = _http_post(f"{api_url}/api/v1/submit", {
        "prompt": combined_prompt,
        "session_id": session_id,
    })

    if "error" in submit_resp:
        with _session_lock:
            session["response_chunks"].append({
                "type": "error",
                "content": f"Dispatch failed: {submit_resp['error']}",
                "timestamp": time.time(),
            })
            session["response_complete"] = True
            _save_sessions()
        return

    task_id = submit_resp.get("task_id", "")
    task_status = submit_resp.get("status", "pending")

    with _session_lock:
        session["task_id"] = task_id
        session["status"] = "dispatched"
        session["response_chunks"].append({
            "type": "status",
            "content": f"Dispatched as task {task_id} (status: {task_status})",
            "timestamp": time.time(),
        })
        _save_sessions()

    # Poll for task completion, streaming output chunks
    _poll_task_output(session_id, task_id)


def _poll_task_output(session_id, task_id):
    """Poll CLaaS v2 API for task status until complete.

    Streams output back to the session's response_chunks for the TUI to pick up.
    """
    session = _sessions.get(session_id)
    if not session:
        return

    api_url = CLAAS_API_URL.rstrip("/")
    last_output_len = 0
    poll_count = 0
    max_polls = 720  # 12 minutes at 1s intervals

    while poll_count < max_polls:
        poll_count += 1
        time.sleep(1)

        task_resp = _http_get(f"{api_url}/api/v1/task/{task_id}")
        if "error" in task_resp:
            continue

        status = task_resp.get("status", "")
        output = task_resp.get("output", "") or ""

        # Stream new output incrementally
        if len(output) > last_output_len:
            new_text = output[last_output_len:]
            last_output_len = len(output)
            with _session_lock:
                session["response_chunks"].append({
                    "type": "text",
                    "content": new_text,
                    "timestamp": time.time(),
                })

        # Emit status changes
        if status == "dispatched" and poll_count == 5:
            with _session_lock:
                worker = task_resp.get("worker", "unknown")
                session["worker"] = worker
                session["response_chunks"].append({
                    "type": "status",
                    "content": f"Running on worker {worker}...",
                    "timestamp": time.time(),
                })

        # Check for terminal states
        if status in ("completed", "failed"):
            # Get final output
            if output and len(output) > last_output_len:
                with _session_lock:
                    session["response_chunks"].append({
                        "type": "text",
                        "content": output[last_output_len:],
                        "timestamp": time.time(),
                    })

            with _session_lock:
                if status == "failed":
                    session["response_chunks"].append({
                        "type": "error",
                        "content": f"Worker failed: {output[-500:] if output else 'no output'}",
                        "timestamp": time.time(),
                    })
                session["messages"].append({
                    "role": "assistant",
                    "content": output or "(no output)",
                    "timestamp": time.time(),
                })
                session["response_complete"] = True
                session["status"] = "active"
                _save_sessions()
            return

    # Timeout
    with _session_lock:
        session["response_chunks"].append({
            "type": "error",
            "content": "Task timed out after 12 minutes",
            "timestamp": time.time(),
        })
        session["response_complete"] = True
        session["status"] = "active"
        _save_sessions()


# --- Standalone / Integrated modes ---

def create_app():
    """Create standalone Flask app for session API."""
    app = Flask(__name__)
    app.register_blueprint(bp)
    _load_sessions()
    return app


def register_with_claas(claas_app):
    """Register session blueprint with the main CLaaS v2 Flask app.

    This allows running session API on the same port as CLaaS v2 (:8080)
    instead of requiring a separate :8081 service.
    """
    claas_app.register_blueprint(bp)
    _load_sessions()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="CLaaS Session API")
    parser.add_argument("--local", action="store_true",
                        help="Local mode: run claude -p as subprocess instead of fleet dispatch")
    parser.add_argument("--port", type=int, default=8081, help="Port (default: 8081)")
    parser.add_argument("--data-dir", help="Data directory for persistence")
    args = parser.parse_args()

    if args.local:
        DISPATCH_MODE = "local"
    if args.data_dir:
        DATA_DIR = Path(args.data_dir)
        SESSIONS_FILE = DATA_DIR / "claas-sessions.json"
        AUDIT_FILE = DATA_DIR / "claas-session-audit.jsonl"

    app = create_app()
    mode_label = "LOCAL (claude -p)" if DISPATCH_MODE == "local" else f"FLEET ({CLAAS_API_URL})"
    print(f"CLaaS Session API on :{args.port} ({len(_sessions)} sessions)")
    print(f"  Mode: {mode_label}")
    print(f"  Session API URL (for workers): {SESSION_API_URL}")
    print(f"  Data: {DATA_DIR}")
    app.run(host="0.0.0.0", port=args.port)
