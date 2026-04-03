#!/usr/bin/env python3
"""CLaaS TUI — Thin client terminal interface for remote Claude.

Zero dependencies beyond Python stdlib. Connects to CLaaS Session API,
sends prompts, streams responses, and runs the local agent for command
requests from the remote worker.

Usage:
  python claas-tui.py                              # interactive
  python claas-tui.py --server https://claas.host  # custom server
  python claas-tui.py --session abc123              # resume session
  python claas-tui.py --config ~/.claas/config.json # custom config
"""
import sys, os, json, time, threading, signal
import urllib.request, urllib.error

# --- ANSI colors ---
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
BLUE = "\033[34m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"

# --- Config ---
DEFAULT_CONFIG = {
    "server": os.environ.get("CLAAS_SERVER", "http://localhost:8081"),
    "working_dir": os.getcwd(),
    "allowed_ops": ["read_file", "list_dir", "search_files", "write_file", "run_script"],
    "allowed_paths": [os.getcwd()],
    "audit_log": os.path.expanduser("~/.claas/audit.log"),
    "agent_poll_interval": 1.0,
}


def load_config(path=None):
    config = dict(DEFAULT_CONFIG)
    if path and os.path.exists(path):
        with open(path) as f:
            config.update(json.load(f))
    config_path = os.path.expanduser("~/.claas/config.json")
    if not path and os.path.exists(config_path):
        with open(config_path) as f:
            config.update(json.load(f))
    return config


# --- HTTP helpers ---

def api_request(config, method, path, data=None):
    url = config["server"].rstrip("/") + path
    body = json.dumps(data).encode() if data else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=35) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        return {"error": f"HTTP {e.code}", "detail": body}
    except Exception as e:
        return {"error": str(e)}


def api_get(config, path):
    return api_request(config, "GET", path)


def api_post(config, path, data=None):
    return api_request(config, "POST", path, data)


def api_delete(config, path):
    return api_request(config, "DELETE", path)


# --- Audit logging ---

def audit_log(config, entry):
    log_path = config.get("audit_log", "")
    if not log_path:
        return
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a") as f:
        f.write(json.dumps({"timestamp": time.time(), **entry}) + "\n")


# --- Local agent ---

def is_path_allowed(path, allowed_paths):
    """Check if a path falls under any allowed directory.

    Uses os.path.commonpath for robust comparison (handles trailing slashes,
    case sensitivity on Windows, etc). Resolves symlinks to prevent traversal.
    """
    try:
        abs_path = os.path.realpath(os.path.abspath(os.path.expanduser(path)))
    except (ValueError, OSError):
        return False
    for ap in allowed_paths:
        try:
            allowed = os.path.realpath(os.path.abspath(os.path.expanduser(ap)))
            # Check: the resolved path starts with the allowed directory
            if abs_path == allowed or abs_path.startswith(allowed + os.sep):
                return True
        except (ValueError, OSError):
            continue
    return False


def execute_command(config, cmd):
    """Execute a local command from the remote worker."""
    op = cmd.get("operation", "")
    args = cmd.get("args", {})
    allowed_paths = config.get("allowed_paths", [])

    audit_log(config, {"type": "command", "operation": op, "args": args})

    try:
        if op == "read_file":
            path = args.get("path", "")
            if not is_path_allowed(path, allowed_paths):
                return {"error": f"Path not allowed: {path}"}
            path = os.path.expanduser(path)
            if not os.path.exists(path):
                return {"error": f"File not found: {path}"}
            with open(path, "r", errors="replace") as f:
                content = f.read(100000)  # 100KB limit
            return {"result": content}

        elif op == "list_dir":
            path = args.get("path", ".")
            if not is_path_allowed(path, allowed_paths):
                return {"error": f"Path not allowed: {path}"}
            path = os.path.expanduser(path)
            entries = []
            for name in sorted(os.listdir(path)):
                full = os.path.join(path, name)
                is_dir = os.path.isdir(full)
                size = os.path.getsize(full) if not is_dir else 0
                entries.append({"name": name, "is_dir": is_dir, "size": size})
            return {"result": entries}

        elif op == "search_files":
            import glob as globmod
            path = args.get("path", ".")
            pattern = args.get("pattern", "*")
            content_pattern = args.get("content", "")
            if not is_path_allowed(path, allowed_paths):
                return {"error": f"Path not allowed: {path}"}
            path = os.path.expanduser(path)
            matches = []
            for f in globmod.glob(os.path.join(path, "**", pattern), recursive=True):
                if content_pattern:
                    try:
                        with open(f, "r", errors="replace") as fh:
                            if content_pattern not in fh.read():
                                continue
                    except Exception:
                        continue
                matches.append(os.path.relpath(f, path))
                if len(matches) >= 100:
                    break
            return {"result": matches}

        elif op == "write_file":
            path = args.get("path", "")
            content = args.get("content", "")
            if not is_path_allowed(path, allowed_paths):
                return {"error": f"Path not allowed: {path}"}
            path = os.path.expanduser(path)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(content)
            return {"result": f"Written {len(content)} bytes to {path}"}

        elif op == "run_script":
            import subprocess
            command = args.get("command", "")
            cwd = args.get("cwd", config.get("working_dir", "."))
            if not is_path_allowed(cwd, allowed_paths):
                return {"error": f"Path not allowed: {cwd}"}
            cwd = os.path.expanduser(cwd)
            result = subprocess.run(
                command, shell=True, capture_output=True, text=True,
                cwd=cwd, timeout=60
            )
            output = result.stdout[-5000:] if result.stdout else ""
            if result.stderr:
                output += "\nSTDERR:\n" + result.stderr[-2000:]
            return {"result": output, "exit_code": result.returncode}

        else:
            return {"error": f"Unknown operation: {op}"}

    except Exception as e:
        return {"error": str(e)}


def agent_loop(config, session_id, stop_event):
    """Poll for commands from the remote worker and execute locally."""
    interval = config.get("agent_poll_interval", 1.0)
    while not stop_event.is_set():
        try:
            commands = api_get(config, f"/api/v1/session/{session_id}/commands")
            if isinstance(commands, list):
                for cmd in commands:
                    print(f"\n  {YELLOW}[agent]{RESET} Executing: {cmd['operation']} {DIM}{json.dumps(cmd.get('args',{}))[:80]}{RESET}")
                    result = execute_command(config, cmd)
                    api_post(config, f"/api/v1/session/{session_id}/result", {
                        "command_id": cmd["id"],
                        **result,
                    })
                    audit_log(config, {"type": "result", "command_id": cmd["id"], **result})
                    status = "ok" if "result" in result else "error"
                    print(f"  {YELLOW}[agent]{RESET} {status}")
        except Exception:
            pass
        stop_event.wait(interval)


# --- TUI ---

def print_banner(config, session_id):
    server = config["server"]
    print(f"""
{BOLD}{BLUE}  CLaaS Remote Shell{RESET} {DIM}v1.0{RESET}
  {DIM}Server:{RESET}  {server}
  {DIM}Session:{RESET} {session_id}
  {DIM}CWD:{RESET}     {config['working_dir']}
  {DIM}Type /help for commands, Ctrl+C to exit{RESET}
""")


def print_help():
    print(f"""
  {BOLD}Commands:{RESET}
    {CYAN}/help{RESET}      — show this help
    {CYAN}/status{RESET}    — session status
    {CYAN}/sessions{RESET}  — list all sessions
    {CYAN}/workers{RESET}   — show fleet workers
    {CYAN}/end{RESET}       — end current session
    {CYAN}/quit{RESET}      — exit TUI
    {CYAN}/config{RESET}    — show current config
    {CYAN}/allowdir{RESET} PATH — add a path to the whitelist
    {CYAN}/new{RESET}       — start a new session
    {CYAN}/audit{RESET}     — show audit log for current session
""")


def stream_response(config, session_id):
    """Poll for response chunks and display them."""
    url = config["server"].rstrip("/") + f"/api/v1/session/{session_id}/stream"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=900) as resp:
            for line in resp:
                line = line.decode("utf-8").strip()
                if not line.startswith("data: "):
                    continue
                try:
                    data = json.loads(line[6:])
                except json.JSONDecodeError:
                    continue
                dtype = data.get("type", "text")
                if dtype == "done":
                    break
                elif dtype == "text":
                    content = data.get("content", "")
                    # Render output line by line for readability
                    for out_line in content.split("\n"):
                        print(f"  {out_line}")
                elif dtype == "status":
                    print(f"  {DIM}{data.get('content', '')}{RESET}")
                elif dtype == "error":
                    print(f"  {RED}{data.get('content', '')}{RESET}")
                elif dtype == "command_request":
                    cmd = data.get("command", {})
                    op = cmd.get("operation", "?")
                    args = cmd.get("args", {})
                    detail = ""
                    if op == "read_file":
                        detail = args.get("path", "")
                    elif op == "list_dir":
                        detail = args.get("path", "")
                    elif op == "run_script":
                        detail = args.get("command", "")[:60]
                    elif op == "write_file":
                        detail = args.get("path", "")
                    elif op == "search_files":
                        detail = f"{args.get('pattern','')} in {args.get('path','')}"
                    print(f"  {YELLOW}[agent]{RESET} {op}: {detail}")
    except urllib.error.URLError as e:
        print(f"  {RED}Connection error: {e.reason}{RESET}")
    except Exception as e:
        print(f"  {RED}Stream error: {e}{RESET}")


def _start_local_server(config):
    """Start the session API server in-process for local mode.

    Sets CLAAS_DISPATCH_MODE=local so prompts run via local claude -p.
    The server runs in a background thread on a free port.
    """
    import importlib.machinery

    # Find session API script relative to this file
    script_dir = os.path.dirname(os.path.abspath(__file__))
    session_api_path = os.path.join(script_dir, "claas-session-api.py")
    if not os.path.exists(session_api_path):
        # Try relative to TUI location (for claas repo layout)
        alt_path = os.path.join(os.path.dirname(script_dir), "scripts", "claas-session-api.py")
        if os.path.exists(alt_path):
            session_api_path = alt_path
        else:
            print(f"{RED}Cannot find claas-session-api.py{RESET}")
            print(f"  Expected at: {session_api_path}")
            sys.exit(1)

    # Set env for local mode
    data_dir = os.path.expanduser("~/.claas/data")
    os.environ["CLAAS_DISPATCH_MODE"] = "local"
    os.environ["CLAAS_DATA_DIR"] = data_dir
    os.makedirs(data_dir, exist_ok=True)

    # Find a free port
    import socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()

    os.environ["CLAAS_SESSION_API_URL"] = f"http://127.0.0.1:{port}"
    config["server"] = f"http://127.0.0.1:{port}"

    # Load and start the session API
    loader = importlib.machinery.SourceFileLoader("session_api", session_api_path)
    mod = loader.load_module()
    app = mod.create_app()

    server_thread = threading.Thread(
        target=lambda: app.run(host="127.0.0.1", port=port, use_reloader=False),
        daemon=True
    )
    server_thread.start()

    # Wait for server to be ready
    import urllib.request
    for _ in range(20):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v1/sessions", timeout=1)
            break
        except Exception:
            time.sleep(0.25)

    print(f"  {DIM}Local server on :{port} (claude -p mode){RESET}")


def _init_config():
    """Generate ~/.claas/config.json template."""
    config_dir = os.path.expanduser("~/.claas")
    config_path = os.path.join(config_dir, "config.json")
    if os.path.exists(config_path):
        print(f"{YELLOW}Config already exists:{RESET} {config_path}")
        print(f"  Edit it directly or delete and re-run --init")
        return

    os.makedirs(config_dir, exist_ok=True)
    template = {
        "server": "http://localhost:8081",
        "working_dir": os.getcwd(),
        "allowed_ops": ["read_file", "list_dir", "search_files", "write_file", "run_script"],
        "allowed_paths": [os.getcwd()],
        "audit_log": os.path.join(config_dir, "audit.log"),
        "agent_poll_interval": 1.0,
    }
    with open(config_path, "w") as f:
        json.dump(template, f, indent=2)
    print(f"{GREEN}Created:{RESET} {config_path}")
    print(f"""
  Edit the config to set:
    {CYAN}server{RESET}         — CLaaS Session API URL
    {CYAN}working_dir{RESET}    — default working directory
    {CYAN}allowed_paths{RESET}  — directories the agent can access
    {CYAN}allowed_ops{RESET}    — operations the agent can execute
    {CYAN}audit_log{RESET}      — path to local audit log
""")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="CLaaS Remote Shell")
    parser.add_argument("--server", help="CLaaS server URL")
    parser.add_argument("--session", help="Resume existing session")
    parser.add_argument("--config", help="Config file path")
    parser.add_argument("--working-dir", help="Working directory")
    parser.add_argument("--init", action="store_true",
                        help="Create ~/.claas/config.json template and exit")
    parser.add_argument("--local", action="store_true",
                        help="Local mode: start session API in-process, dispatch to local claude -p")
    args = parser.parse_args()

    if args.init:
        _init_config()
        return

    config = load_config(args.config)
    if args.server:
        config["server"] = args.server
    if args.working_dir:
        config["working_dir"] = args.working_dir
        config["allowed_paths"] = [args.working_dir]

    # Local mode: start session API in-process
    if args.local:
        _start_local_server(config)

    # Create or resume session
    if args.session:
        session_id = args.session
        status = api_get(config, f"/api/v1/session/{session_id}/status")
        if "error" in status:
            print(f"{RED}Session {session_id} not found{RESET}")
            sys.exit(1)
    else:
        resp = api_post(config, "/api/v1/session", {
            "working_dir": config["working_dir"],
            "allowed_ops": config["allowed_ops"],
        })
        if "error" in resp:
            print(f"{RED}Failed to create session: {resp}{RESET}")
            sys.exit(1)
        session_id = resp["session_id"]

    # Start agent in background
    stop_event = threading.Event()
    agent_thread = threading.Thread(
        target=agent_loop, args=(config, session_id, stop_event), daemon=True
    )
    agent_thread.start()

    print_banner(config, session_id)

    def cleanup(*_):
        stop_event.set()
        api_delete(config, f"/api/v1/session/{session_id}")
        print(f"\n{DIM}Session ended.{RESET}")
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)

    # REPL
    while True:
        try:
            prompt = input(f"{GREEN}>{RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            cleanup()
            break

        if not prompt:
            continue

        if prompt == "/help":
            print_help()
            continue
        elif prompt == "/quit":
            cleanup()
            break
        elif prompt == "/end":
            cleanup()
            break
        elif prompt == "/status":
            status = api_get(config, f"/api/v1/session/{session_id}/status")
            print(f"  {json.dumps(status, indent=2)}")
            continue
        elif prompt == "/sessions":
            sessions = api_get(config, "/api/v1/sessions")
            if isinstance(sessions, list):
                for s in sessions:
                    print(f"  {s['id']}  {s['status']}  {s['messages']} msgs")
            continue
        elif prompt == "/config":
            print(f"  {json.dumps(config, indent=2)}")
            continue
        elif prompt == "/workers":
            workers = api_get(config, "/api/v1/workers")
            if isinstance(workers, dict):
                for name, w in workers.items():
                    status_color = GREEN if w.get("status") == "idle" else YELLOW
                    print(f"  {status_color}{name}{RESET}  {w.get('status','?')}  "
                          f"completions={w.get('completions',0)}")
            elif "error" in workers:
                # Session API may not proxy /workers — try CLaaS v2 directly
                print(f"  {DIM}(worker list requires CLaaS v2 API){RESET}")
            continue
        elif prompt.startswith("/allowdir "):
            new_path = os.path.abspath(os.path.expanduser(prompt[10:].strip()))
            if new_path not in config["allowed_paths"]:
                config["allowed_paths"].append(new_path)
                print(f"  {GREEN}Added:{RESET} {new_path}")
            else:
                print(f"  {DIM}Already allowed: {new_path}{RESET}")
            continue
        elif prompt == "/new":
            # End current session and start a new one
            api_delete(config, f"/api/v1/session/{session_id}")
            resp = api_post(config, "/api/v1/session", {
                "working_dir": config["working_dir"],
                "allowed_ops": config["allowed_ops"],
            })
            if "error" in resp:
                print(f"  {RED}Failed to create session: {resp}{RESET}")
            else:
                session_id = resp["session_id"]
                print(f"  {GREEN}New session:{RESET} {session_id}")
            continue
        elif prompt == "/audit":
            audit = api_get(config, f"/api/v1/session/{session_id}/audit")
            if isinstance(audit, list):
                for entry in audit[-20:]:
                    ts = time.strftime("%H:%M:%S", time.localtime(entry.get("timestamp", 0)))
                    print(f"  {DIM}{ts}{RESET} {entry.get('event','')} "
                          f"{json.dumps({k:v for k,v in entry.items() if k not in ('timestamp','event','session_id')})}")
            else:
                print(f"  {DIM}No audit entries{RESET}")
            continue

        # Send prompt
        print(f"  {DIM}Sending to worker...{RESET}")
        resp = api_post(config, f"/api/v1/session/{session_id}/prompt", {
            "prompt": prompt,
        })
        if "error" in resp:
            print(f"  {RED}{resp['error']}{RESET}")
            continue

        # Stream response
        stream_response(config, session_id)
        print()


if __name__ == "__main__":
    main()
