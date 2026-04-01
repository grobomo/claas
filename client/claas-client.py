#!/usr/bin/env python3
"""CLaaS (Claude-as-a-Service) Python client library.

Usage as library:
    from claas_client import CLaaSClient
    client = CLaaSClient("https://your-claas-host", token="my-token")
    task = client.submit("Build a REST API")
    result = client.wait(task["task_id"], timeout=300)
    print(result["result"])

Usage as CLI:
    python claas-client.py submit "Build a REST API"
    python claas-client.py status <task-id>
    python claas-client.py wait <task-id> [--timeout 300]
    python claas-client.py list
    python claas-client.py health
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
import ssl

# Defaults
DEFAULT_URL = os.environ.get("CLAAS_URL", "https://your-claas-host")
DEFAULT_TOKEN = os.environ.get("CLAAS_TOKEN", "your-admin-token")


class CLaaSClient:
    """HTTP client for the CLaaS API."""

    def __init__(self, base_url=None, token=None, verify_ssl=False):
        self.base_url = (base_url or DEFAULT_URL).rstrip("/")
        self.token = token or DEFAULT_TOKEN
        self._ctx = ssl.create_default_context()
        if not verify_ssl:
            self._ctx.check_hostname = False
            self._ctx.verify_mode = ssl.CERT_NONE

    def _request(self, method, path, body=None):
        """Make an authenticated HTTP request to the CLaaS API."""
        url = self.base_url + path
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }
        data = json.dumps(body).encode() if body else None
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, context=self._ctx) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else ""
            try:
                return json.loads(error_body)
            except (json.JSONDecodeError, ValueError):
                return {"error": f"HTTP {e.code}: {error_body}"}

    def submit(self, text, sender=None, priority="normal"):
        """Submit a task to the fleet. Returns {"task_id", "status", "poll_url"}."""
        body = {"text": text, "priority": priority}
        if sender:
            body["sender"] = sender
        return self._request("POST", "/api/v1/submit", body)

    def status(self, task_id):
        """Get the status of a single task."""
        return self._request("GET", f"/api/v1/task/{task_id}")

    def list(self):
        """List all tasks for the authenticated project."""
        return self._request("GET", "/api/v1/tasks")

    def health(self):
        """Check fleet health."""
        return self._request("GET", "/api/v1/health")

    def wait(self, task_id, timeout=300, poll_interval=10):
        """Poll a task until it completes or times out. Returns the final task object."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            task = self.status(task_id)
            state = task.get("state", "")
            if state in ("COMPLETED", "FAILED"):
                return task
            time.sleep(poll_interval)
        return {"error": f"Timeout after {timeout}s", "last_state": task.get("state")}

    def create_token(self, token, project):
        """Create a new bearer token (requires admin token)."""
        return self._request("POST", "/api/v1/tokens", {"token": token, "project": project})

    def revoke_token(self, token):
        """Revoke a bearer token (requires admin token)."""
        return self._request("POST", "/api/v1/tokens/revoke", {"token": token})

    def list_tokens(self):
        """List all tokens (requires admin token)."""
        return self._request("GET", "/api/v1/tokens")


def _cli():
    """CLI entry point."""
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    client = CLaaSClient()

    if cmd == "submit":
        if len(sys.argv) < 3:
            print("Usage: claas-client.py submit <text>")
            sys.exit(1)
        result = client.submit(" ".join(sys.argv[2:]))
        print(json.dumps(result, indent=2))

    elif cmd == "status":
        if len(sys.argv) < 3:
            print("Usage: claas-client.py status <task-id>")
            sys.exit(1)
        result = client.status(sys.argv[2])
        print(json.dumps(result, indent=2))

    elif cmd == "wait":
        if len(sys.argv) < 3:
            print("Usage: claas-client.py wait <task-id> [--timeout N]")
            sys.exit(1)
        timeout = 300
        if "--timeout" in sys.argv:
            idx = sys.argv.index("--timeout")
            timeout = int(sys.argv[idx + 1])
        result = client.wait(sys.argv[2], timeout=timeout)
        print(json.dumps(result, indent=2))

    elif cmd == "list":
        result = client.list()
        print(json.dumps(result, indent=2))

    elif cmd == "health":
        result = client.health()
        print(json.dumps(result, indent=2))

    elif cmd == "tokens":
        result = client.list_tokens()
        print(json.dumps(result, indent=2))

    else:
        print(f"Unknown command: {cmd}")
        print("Commands: submit, status, wait, list, health, tokens")
        sys.exit(1)


if __name__ == "__main__":
    _cli()
