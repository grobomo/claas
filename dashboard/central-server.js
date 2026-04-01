#!/usr/bin/env node
'use strict';
/**
 * Central Dashboard Server
 *
 * Receives stats from component collectors via POST /api/stats/:component
 * Serves a single-page HTML dashboard at GET /
 * Designed to run on the dispatcher EC2 (port 8082).
 *
 * Authentication:
 *   - All dashboard routes require login (cookie-based sessions)
 *   - POST /api/stats/:component is unauthenticated (collectors push data)
 *   - Default admin/admin — forced password change on first login
 *   - Admin panel at /admin for user management
 *
 * Usage:
 *   node dashboard/central-server.js
 *   PORT=8082 node dashboard/central-server.js
 */

const http = require('http');
const { execSync } = require('child_process');
const auth = require('./auth');

const PORT = parseInt(process.env.PORT || '8082', 10);
const DISPATCH_API_TOKEN = process.env.DISPATCH_API_TOKEN || '';

// Ensure default admin user exists on startup
auth.ensureUsersFile();

// In-memory store — one entry per component, overwritten on each push
const stats = {};

function handlePost(req, res) {
  const match = req.url.match(/^\/api\/stats\/(\w+)$/);
  if (!match) {
    res.writeHead(404);
    res.end('Not found');
    return;
  }
  const component = match[1];
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    try {
      const data = JSON.parse(body);
      data._received_at = new Date().toISOString();
      stats[component] = data;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, component }));
    } catch (e) {
      res.writeHead(400);
      res.end('Bad JSON');
    }
  });
}

function handleGetStats(req, res) {
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(JSON.stringify(stats, null, 2));
}

function ageClass(receivedAt, thresholdSec) {
  if (!receivedAt) return 'stale';
  const age = (Date.now() - new Date(receivedAt).getTime()) / 1000;
  if (age < thresholdSec) return 'fresh';
  if (age < thresholdSec * 3) return 'warn';
  return 'stale';
}

function escHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function renderDashboard(username) {
  const now = new Date().toISOString();
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="10">
<title>BoothApp Central Dashboard</title>
<style>
  :root {
    --bg: #0a0e14; --card: #12171f; --border: #1e2733;
    --text: #d4dae3; --muted: #6b7b8d; --accent: #4da6ff;
    --green: #3fb950; --red: #f85149; --yellow: #e3b341;
    --orange: #d18616;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: var(--bg); color: var(--text);
    padding: 32px; min-height: 100vh;
  }
  header {
    display: flex; justify-content: space-between; align-items: baseline;
    margin-bottom: 32px;
  }
  h1 { font-size: 2rem; color: #fff; font-weight: 700; }
  .header-right { display: flex; align-items: baseline; gap: 16px; }
  .clock { color: var(--muted); font-size: 0.9rem; }
  .user-info { color: var(--muted); font-size: 0.85rem; }
  .user-info a { color: var(--accent); text-decoration: none; }
  .user-info a:hover { text-decoration: underline; }
  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 24px;
  }
  .card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 24px; position: relative;
    overflow: hidden;
  }
  .card.full { grid-column: 1 / -1; }
  .card-header {
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 20px;
  }
  .card-header h2 { font-size: 1.1rem; color: #fff; font-weight: 600; }
  .dot {
    width: 12px; height: 12px; border-radius: 50%; display: inline-block;
  }
  .dot.fresh { background: var(--green); box-shadow: 0 0 8px var(--green); }
  .dot.warn { background: var(--yellow); box-shadow: 0 0 8px var(--yellow); }
  .dot.stale { background: var(--red); box-shadow: 0 0 8px var(--red); }
  .stat-row {
    display: flex; justify-content: space-between; align-items: baseline;
    padding: 8px 0; border-bottom: 1px solid var(--border);
  }
  .stat-row:last-child { border-bottom: none; }
  .stat-label { color: var(--muted); font-size: 0.9rem; }
  .stat-value { font-size: 1.1rem; font-weight: 600; font-variant-numeric: tabular-nums; }
  .stat-value.green { color: var(--green); }
  .stat-value.red { color: var(--red); }
  .stat-value.yellow { color: var(--yellow); }
  .big-number {
    font-size: 2.5rem; font-weight: 700; line-height: 1;
    font-variant-numeric: tabular-nums;
  }
  .big-label { font-size: 0.85rem; color: var(--muted); margin-top: 4px; }
  .worker-grid {
    display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px;
  }
  .worker-box {
    background: var(--bg); border: 1px solid var(--border);
    border-radius: 8px; padding: 12px; text-align: center;
  }
  .worker-box .name { font-size: 0.8rem; color: var(--muted); margin-bottom: 4px; }
  .worker-box .status { font-size: 1rem; font-weight: 600; }
  .worker-box .status.idle { color: var(--green); }
  .worker-box .status.busy { color: var(--yellow); }
  .worker-box .status.down { color: var(--red); }
  .pipeline {
    display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
    padding: 12px 0;
  }
  .pipeline-step {
    background: var(--bg); border: 1px solid var(--border);
    border-radius: 6px; padding: 8px 16px; font-size: 0.85rem;
    white-space: nowrap;
  }
  .pipeline-step.active { border-color: var(--green); color: var(--green); }
  .pipeline-arrow { color: var(--muted); font-size: 1.2rem; }
  .no-data {
    color: var(--muted); font-style: italic; padding: 20px;
    text-align: center;
  }
  footer {
    margin-top: 32px; text-align: center;
    color: var(--muted); font-size: 0.75rem;
  }
</style>
</head>
<body>
<header>
  <h1>BoothApp Central</h1>
  <div class="header-right">
    <div class="user-info">${escHtml(username)} | <a href="/admin">Admin</a> | <a href="/logout">Logout</a></div>
    <div class="clock">${now}</div>
  </div>
</header>

<div class="grid">
  ${renderRone(stats.rone)}
  ${renderCCC(stats.ccc)}
  ${renderBoothApp(stats.boothapp)}
  ${renderPipeline()}
</div>

<footer>Auto-refreshes every 10s &bull; Components push every 15s</footer>
</body>
</html>`;
}

function renderRone(d) {
  if (!d) return `<div class="card"><div class="card-header"><h2>RONE Teams Poller</h2><span class="dot stale"></span></div><div class="no-data">No data received</div></div>`;
  const age = ageClass(d._received_at, 30);
  const p = d.poller || {};
  const w = d.worker || {};
  const cache = d.cache || {};
  const bridge = d.bridge || {};
  const pending = p.pending_response || {};
  const pendingHtml = pending.pending
    ? `<div class="stat-row" style="background:#442200;border-radius:4px;padding:4px 8px;margin:4px 0">
        <span class="stat-label" style="color:#ffaa00">PENDING REPLY</span>
        <span class="stat-value yellow">${pending.sender || '?'} (${pending.minutes_waiting || '?'}m ago)</span>
      </div>
      <div class="stat-row" style="padding-left:16px"><span class="stat-label" style="font-size:12px;color:#999">${(pending.text || '').substring(0, 80)}</span></div>`
    : `<div class="stat-row"><span class="stat-label">Chat status</span><span class="stat-value green">No pending replies</span></div>`;
  return `<div class="card">
    <div class="card-header"><h2>RONE Teams Poller</h2><span class="dot ${age}"></span></div>
    ${pendingHtml}
    <div class="stat-row"><span class="stat-label">Last poll</span><span class="stat-value">${p.age_seconds != null ? p.age_seconds + 's ago' : '?'}</span></div>
    <div class="stat-row"><span class="stat-label">Messages cached</span><span class="stat-value">${cache.count || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Relayed to AWS</span><span class="stat-value">${p.relayed || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Replied in chat</span><span class="stat-value">${p.replied || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Worker tasks done</span><span class="stat-value">${w.processed || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Bridge pending</span><span class="stat-value ${(bridge.pending || 0) > 0 ? 'yellow' : ''}">${bridge.pending || 0}</span></div>
    <div class="stat-row"><span class="stat-label">API cost</span><span class="stat-value">$${((p.estimated_cost_usd || 0) + (w.estimated_cost_usd || 0)).toFixed(4)}</span></div>
  </div>`;
}

function renderCCC(d) {
  if (!d) return `<div class="card"><div class="card-header"><h2>AWS CCC Fleet</h2><span class="dot stale"></span></div><div class="no-data">No data received</div></div>`;
  const age = ageClass(d._received_at, 30);
  const workers = d.workers || [];
  const idle = workers.filter(w => w.status === 'idle').length;
  const busy = workers.filter(w => w.status === 'busy').length;
  const down = workers.filter(w => w.status === 'down' || w.status === 'unreachable').length;
  const relay = d.relay || {};
  return `<div class="card">
    <div class="card-header"><h2>AWS CCC Fleet</h2><span class="dot ${age}"></span></div>
    <div class="stat-row"><span class="stat-label">Dispatcher</span><span class="stat-value ${d.dispatcher_state === 'running' ? 'green' : 'yellow'}">${d.dispatcher_state || '?'} (${d.leader_role || '?'})</span></div>
    <div class="stat-row"><span class="stat-label">Workers</span><span class="stat-value"><span class="green">${idle} idle</span> / <span class="yellow">${busy} busy</span> / <span class="red">${down} down</span></span></div>
    <div class="stat-row"><span class="stat-label">Relay pending</span><span class="stat-value ${(relay.pending || 0) > 0 ? 'yellow' : ''}">${relay.pending || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Dispatched</span><span class="stat-value">${relay.dispatched || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Completed</span><span class="stat-value green">${relay.completed || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Failed</span><span class="stat-value ${(relay.failed || 0) > 0 ? 'red' : ''}">${relay.failed || 0}</span></div>
    <div style="margin-top:16px">
      <div class="worker-grid">
        ${workers.map(w => `<div class="worker-box"><div class="name">${w.name}</div><div class="status ${w.status}">${w.status}</div></div>`).join('')}
      </div>
    </div>
  </div>`;
}

function renderBoothApp(d) {
  if (!d) return `<div class="card"><div class="card-header"><h2>BoothApp Sessions</h2><span class="dot stale"></span></div><div class="no-data">No data received</div></div>`;
  const age = ageClass(d._received_at, 30);
  const sessions = d.sessions || {};
  return `<div class="card">
    <div class="card-header"><h2>BoothApp Sessions</h2><span class="dot ${age}"></span></div>
    <div class="stat-row"><span class="stat-label">Total sessions</span><span class="stat-value big-number">${sessions.total || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Active</span><span class="stat-value green">${sessions.active || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Analyzing</span><span class="stat-value yellow">${sessions.analyzing || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Complete</span><span class="stat-value">${sessions.complete || 0}</span></div>
    <div class="stat-row"><span class="stat-label">Lambda</span><span class="stat-value ${d.lambda_healthy ? 'green' : 'red'}">${d.lambda_healthy ? 'Healthy' : 'Unknown'}</span></div>
    <div class="stat-row"><span class="stat-label">Watcher</span><span class="stat-value ${d.watcher_running ? 'green' : 'red'}">${d.watcher_running ? 'Running' : 'Stopped'}</span></div>
    <div class="stat-row"><span class="stat-label">S3 objects</span><span class="stat-value">${d.s3_object_count || '?'}</span></div>
  </div>`;
}

function renderPipeline() {
  const steps = [
    ['Teams Chat', !!(stats.rone)],
    ['RONE Poller', !!(stats.rone?.poller)],
    ['Bridge', !!(stats.ccc?.relay)],
    ['CCC Workers', !!(stats.ccc?.workers?.length)],
    ['S3 Sessions', !!(stats.boothapp?.sessions)],
    ['Analysis', !!(stats.boothapp?.watcher_running)],
  ];
  const stepsHtml = steps.map(([name, active]) =>
    `<div class="pipeline-step ${active ? 'active' : ''}">${name}</div>`
  ).join('<span class="pipeline-arrow">&#x2192;</span>');

  return `<div class="card full">
    <div class="card-header"><h2>End-to-End Pipeline</h2></div>
    <div class="pipeline">${stepsHtml}</div>
  </div>`;
}

// --- mTLS Auto-Auth ---
// Nginx passes X-Client-CN and X-Client-Verified headers when client cert is valid.
// If cert is verified, auto-create a session — no login required.

function mtlsAutoAuth(req, res) {
  const cn = (req.headers['x-client-cn'] || '').trim();
  const verified = (req.headers['x-client-verified'] || '').trim();
  if (verified === 'SUCCESS' && cn) {
    const existing = auth.checkAuth(req);
    if (existing.authenticated) return existing;
    const token = auth.certAutoLogin(cn);
    if (token) {
      res.setHeader('Set-Cookie', auth.sessionCookie(token));
      return { authenticated: true, username: cn, user: { role: 'viewer' }, token };
    }
  }
  return null;
}

// --- Submit Page ---

function renderSubmitPage(username) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Submit Task - BoothApp</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {
    --bg: #0a0e14; --card: #12171f; --border: #1e2733;
    --text: #d4dae3; --muted: #6b7b8d; --accent: #4da6ff;
    --green: #3fb950; --red: #f85149; --yellow: #e3b341;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: var(--bg); color: var(--text);
    min-height: 100vh; padding: 24px;
  }
  .nav {
    display: flex; gap: 16px; align-items: center; margin-bottom: 32px; flex-wrap: wrap;
  }
  .nav a {
    color: var(--accent); text-decoration: none; font-size: 0.95rem;
    padding: 8px 16px; border: 1px solid var(--border); border-radius: 8px;
    background: var(--card);
  }
  .nav a:hover { border-color: var(--accent); }
  .nav a.active { border-color: var(--accent); background: rgba(77,166,255,0.1); }
  .nav .user { margin-left: auto; color: var(--muted); font-size: 0.85rem; }
  .container {
    max-width: 700px; margin: 0 auto;
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 32px;
  }
  h1 { color: #fff; font-size: 1.5rem; margin-bottom: 8px; }
  .subtitle { color: var(--muted); margin-bottom: 24px; font-size: 0.9rem; }
  label { display: block; color: var(--muted); font-size: 0.85rem; margin-bottom: 6px; margin-top: 16px; }
  textarea, input[type="text"] {
    width: 100%; padding: 12px; background: var(--bg); color: var(--text);
    border: 1px solid var(--border); border-radius: 8px; font-size: 1rem;
    font-family: inherit; outline: none; resize: vertical;
  }
  textarea { min-height: 120px; }
  textarea:focus, input:focus { border-color: var(--accent); }
  button {
    display: block; width: 100%; padding: 14px; margin-top: 24px;
    background: var(--accent); color: #fff; border: none;
    border-radius: 8px; font-size: 1.1rem; font-weight: 600; cursor: pointer;
  }
  button:hover { opacity: 0.9; }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  .result { margin-top: 20px; padding: 16px; border-radius: 8px; display: none; }
  .result.success { background: rgba(63,185,80,0.15); border: 1px solid var(--green); color: var(--green); display: block; }
  .result.error { background: rgba(248,81,73,0.15); border: 1px solid var(--red); color: var(--red); display: block; }
  .result.working { background: rgba(77,166,255,0.1); border: 1px solid var(--accent); color: var(--text); display: block; }
  .timeline { margin-top: 16px; }
  .timeline-item {
    display: flex; align-items: flex-start; gap: 12px; padding: 8px 0;
    border-left: 2px solid var(--border); margin-left: 8px; padding-left: 16px;
    position: relative;
  }
  .timeline-item::before {
    content: ''; position: absolute; left: -6px; top: 12px;
    width: 10px; height: 10px; border-radius: 50%; background: var(--border);
  }
  .timeline-item.done::before { background: var(--green); }
  .timeline-item.active::before { background: var(--accent); animation: pulse 1.5s infinite; }
  .timeline-item.error::before { background: var(--red); }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }
  .timeline-item .ts { color: var(--muted); font-size: 0.75rem; min-width: 80px; }
  .timeline-item .event { font-weight: 600; color: var(--accent); font-size: 0.85rem; }
  .timeline-item .detail { color: var(--muted); font-size: 0.85rem; }
  .worker-result { margin-top: 16px; padding: 16px; background: var(--bg); border: 1px solid var(--green);
    border-radius: 8px; font-family: 'Cascadia Code', 'Fira Code', monospace; font-size: 0.85rem;
    white-space: pre-wrap; max-height: 400px; overflow-y: auto; color: var(--text); line-height: 1.5; }
  .step-label { font-size: 1.1rem; font-weight: 600; margin-bottom: 4px; }
  .step-desc { color: var(--muted); font-size: 0.9rem; }
  .examples { margin-top: 24px; padding-top: 20px; border-top: 1px solid var(--border); }
  .examples h3 { color: var(--muted); font-size: 0.85rem; margin-bottom: 12px; text-transform: uppercase; }
  .example-btn {
    display: inline-block; padding: 6px 12px; margin: 4px;
    background: var(--bg); border: 1px solid var(--border); border-radius: 6px;
    color: var(--text); font-size: 0.85rem; cursor: pointer; text-decoration: none;
  }
  .example-btn:hover { border-color: var(--accent); color: var(--accent); }
</style>
</head>
<body>
<div class="nav">
  <a href="/">Dashboard</a>
  <a href="/submit" class="active">Submit Task</a>
  <a href="/tasks">Task History</a>
  <a href="/sessions">Sessions</a>
  <a href="/tokens">API Tokens</a>
  <a href="/admin">Admin</a>
  <span class="user">${escHtml(username)} | <a href="/logout" style="color:var(--muted)">Logout</a></span>
</div>
<div class="container">
  <h1>Submit a Task</h1>
  <div class="subtitle">Describe what you want built. A CCC worker will pick it up, create a branch, implement it, and open a PR.</div>
  <form id="submitForm" onsubmit="return submitTask(event)">
    <label for="taskText">Task Description</label>
    <textarea id="taskText" name="text" placeholder="e.g. Add a visitor badge scanner that uses OCR to extract name and company from the badge photo..." required></textarea>
    <label for="targetRepo">Target Repository (optional)</label>
    <input type="text" id="targetRepo" name="target_repo" placeholder="Default: altarr/boothapp" value="">
    <button type="submit" id="submitBtn">Submit Task</button>
  </form>
  <div id="result" class="result"></div>
  <div class="examples">
    <h3>Quick Tasks</h3>
    <a class="example-btn" onclick="fillTask('Add V1 endpoint protection policy that blocks malicious IPs detected in demo sessions')">V1 Protection</a>
    <a class="example-btn" onclick="fillTask('Fix the Chrome extension to auto-detect badge scan and start recording')">Fix Extension</a>
    <a class="example-btn" onclick="fillTask('Add a presenter dashboard showing live session progress with click timeline')">Presenter View</a>
    <a class="example-btn" onclick="fillTask('Generate a polished PDF follow-up report from the analysis output')">PDF Report</a>
    <a class="example-btn" onclick="fillTask('Add email notification when session analysis completes')">Email Notify</a>
  </div>
</div>
<script>
var _pollTimer = null;
var _taskId = null;
var _seenEvents = 0;
var CLAAS_TOKEN = '${escHtml(DISPATCH_API_TOKEN || 'default')}';

function fillTask(text) {
  document.getElementById('taskText').value = text;
  document.getElementById('taskText').focus();
}

function timeAgo(ts) {
  if (!ts) return '';
  var d = new Date(ts);
  return d.toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',second:'2-digit'});
}

var stepIcons = {
  submitted: '\u{1F4E8}', queued: '\u{1F4CB}', generating_spec: '\u{1F9E0}',
  spec_ready: '\u{1F4D1}', dispatched_to_worker: '\u{1F680}',
  worker_completed: '\u{2705}', completed: '\u{1F389}',
  failed: '\u{274C}', error: '\u{26A0}'
};
var stepLabels = {
  submitted: 'Task Received', queued: 'Queued for Dispatch',
  generating_spec: 'Generating Specification', spec_ready: 'Specification Ready',
  dispatched_to_worker: 'Sent to Worker', worker_completed: 'Worker Finished',
  completed: 'Task Complete', failed: 'Task Failed', error: 'Error'
};

function renderTimeline(events, current) {
  if (!events || !events.length) return '<div class="timeline-item active"><span class="event">Waiting for updates...</span></div>';
  var html = '';
  for (var i = 0; i < events.length; i++) {
    var ev = events[i];
    var isLast = (i === events.length - 1);
    var cls = isLast && !['completed','failed'].includes(ev.event) ? 'active' : (ev.event === 'failed' || ev.event === 'error' ? 'error' : 'done');
    var icon = stepIcons[ev.event] || '\u{25CF}';
    var label = stepLabels[ev.event] || ev.event;
    html += '<div class="timeline-item ' + cls + '">';
    html += '<span class="ts">' + timeAgo(ev.ts) + '</span>';
    html += '<div><span class="event">' + icon + ' ' + label + '</span>';
    if (ev.detail) html += '<div class="detail">' + ev.detail + '</div>';
    html += '</div></div>';
  }
  return html;
}

async function pollTask() {
  if (!_taskId) return;
  try {
    var resp = await fetch('/api/v1/task/' + _taskId, {
      headers: { 'Authorization': 'Bearer ' + CLAAS_TOKEN }
    });
    var data = await resp.json();
    var result = document.getElementById('result');
    var events = data.events || [];

    // Build current step display
    var step = data.current_step || data.state || 'pending';
    var stepIcon = stepIcons[step] || '\u{23F3}';
    var stepLabel = stepLabels[step] || step;

    if (data.state === 'COMPLETED' || data.state === 'completed') {
      clearInterval(_pollTimer);
      result.className = 'result success';
      result.innerHTML = '<div class="step-label">' + stepIcon + ' ' + stepLabel + '</div>' +
        '<div class="timeline">' + renderTimeline(events) + '</div>' +
        (data.result ? '<div class="worker-result">' + escapeHtml(data.result) + '</div>' : '') +
        (data.worker ? '<div class="detail" style="margin-top:8px">Worker: ' + data.worker + '</div>' : '') +
        '<div style="margin-top:12px"><a href="/submit" style="color:var(--accent)">Submit another task &rarr;</a></div>';
      document.getElementById('submitBtn').disabled = false;
      document.getElementById('submitBtn').textContent = 'Submit Another Task';
    } else if (data.state === 'FAILED' || data.state === 'failed') {
      clearInterval(_pollTimer);
      result.className = 'result error';
      result.innerHTML = '<div class="step-label">' + stepIcon + ' ' + stepLabel + '</div>' +
        '<div class="timeline">' + renderTimeline(events) + '</div>' +
        (data.error ? '<div class="worker-result" style="border-color:var(--red)">' + escapeHtml(data.error) + '</div>' : '') +
        '<div style="margin-top:12px"><button onclick="resetForm()" style="width:auto;padding:8px 16px">Try Again</button></div>';
      document.getElementById('submitBtn').disabled = false;
      document.getElementById('submitBtn').textContent = 'Submit Task';
    } else {
      result.className = 'result working';
      result.innerHTML = '<div class="step-label">' + stepIcon + ' ' + stepLabel + '</div>' +
        '<div class="step-desc">Task ID: ' + _taskId.slice(0,8) + '...</div>' +
        '<div class="timeline">' + renderTimeline(events, step) + '</div>';
    }
  } catch (err) {
    console.error('Poll error:', err);
  }
}

function escapeHtml(s) {
  if (!s) return '';
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function resetForm() {
  var result = document.getElementById('result');
  result.className = 'result';
  result.style.display = 'none';
  document.getElementById('submitBtn').disabled = false;
  document.getElementById('submitBtn').textContent = 'Submit Task';
  document.getElementById('taskText').value = '';
  _taskId = null;
  _seenEvents = 0;
}

async function submitTask(e) {
  e.preventDefault();
  var btn = document.getElementById('submitBtn');
  var result = document.getElementById('result');
  var text = document.getElementById('taskText').value.trim();
  if (!text) return;

  btn.disabled = true;
  btn.textContent = 'Submitting...';
  result.className = 'result working';
  result.innerHTML = '<div class="step-label">\u{1F4E8} Submitting task...</div>';

  try {
    var resp = await fetch('/api/v1/submit', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + CLAAS_TOKEN,
      },
      body: JSON.stringify({ text: text, sender: '${escHtml(username)}' })
    });
    var data = await resp.json();
    if (resp.ok && data.task_id) {
      _taskId = data.task_id;
      _seenEvents = 0;
      btn.textContent = 'Working...';
      result.innerHTML = '<div class="step-label">\u{1F4CB} Task Queued</div>' +
        '<div class="step-desc">ID: ' + _taskId.slice(0,8) + '... \u2014 polling for updates</div>' +
        '<div class="timeline"><div class="timeline-item active"><span class="ts">' + timeAgo(new Date().toISOString()) + '</span><div><span class="event">\u{1F4E8} Submitted</span><div class="detail">Task received by dispatcher</div></div></div></div>';
      // Start polling every 3 seconds
      _pollTimer = setInterval(pollTask, 3000);
      // First poll after 2s
      setTimeout(pollTask, 2000);
    } else {
      result.className = 'result error';
      result.textContent = 'Error: ' + (data.error || JSON.stringify(data));
      btn.disabled = false;
      btn.textContent = 'Submit Task';
    }
  } catch (err) {
    result.className = 'result error';
    result.textContent = 'Network error: ' + err.message;
    btn.disabled = false;
    btn.textContent = 'Submit Task';
  }
}
</script>
</body>
</html>`;
}

// --- Tasks Page ---

function renderTasksPage(username) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Task History - BoothApp</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="15">
<style>
  :root {
    --bg: #0a0e14; --card: #12171f; --border: #1e2733;
    --text: #d4dae3; --muted: #6b7b8d; --accent: #4da6ff;
    --green: #3fb950; --red: #f85149; --yellow: #e3b341;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: var(--bg); color: var(--text);
    min-height: 100vh; padding: 24px;
  }
  .nav {
    display: flex; gap: 16px; align-items: center; margin-bottom: 32px; flex-wrap: wrap;
  }
  .nav a {
    color: var(--accent); text-decoration: none; font-size: 0.95rem;
    padding: 8px 16px; border: 1px solid var(--border); border-radius: 8px;
    background: var(--card);
  }
  .nav a:hover { border-color: var(--accent); }
  .nav a.active { border-color: var(--accent); background: rgba(77,166,255,0.1); }
  .nav .user { margin-left: auto; color: var(--muted); font-size: 0.85rem; }
  h1 { color: #fff; font-size: 1.5rem; margin-bottom: 24px; }
  .task-list { max-width: 900px; margin: 0 auto; }
  .task-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 10px; padding: 20px; margin-bottom: 12px;
  }
  .task-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
  .task-id { font-family: monospace; font-size: 0.8rem; color: var(--muted); }
  .task-status {
    padding: 3px 10px; border-radius: 12px; font-size: 0.8rem; font-weight: 600;
    text-transform: uppercase;
  }
  .status-pending { background: rgba(227,179,65,0.2); color: var(--yellow); }
  .status-dispatched, .status-running { background: rgba(77,166,255,0.2); color: var(--accent); }
  .status-completed { background: rgba(63,185,80,0.2); color: var(--green); }
  .status-failed { background: rgba(248,81,73,0.2); color: var(--red); }
  .task-text { font-size: 0.95rem; line-height: 1.5; margin-bottom: 8px; }
  .task-meta { color: var(--muted); font-size: 0.8rem; }
  .loading { text-align: center; color: var(--muted); padding: 40px; }
  .empty { text-align: center; color: var(--muted); padding: 40px; font-style: italic; }
</style>
</head>
<body>
<div class="nav">
  <a href="/">Dashboard</a>
  <a href="/submit">Submit Task</a>
  <a href="/tasks" class="active">Task History</a>
  <a href="/tokens">API Tokens</a>
  <a href="/admin">Admin</a>
  <span class="user">${escHtml(username)} | <a href="/logout" style="color:var(--muted)">Logout</a></span>
</div>
<div class="task-list">
  <h1>Task History</h1>
  <div id="tasks" class="loading">Loading tasks...</div>
</div>
<script>
async function loadTasks() {
  var el = document.getElementById('tasks');
  try {
    var resp = await fetch('/api/tasks');
    if (!resp.ok) throw new Error('HTTP ' + resp.status);
    var data = await resp.json();
    var tasks = data.tasks || data || [];
    if (!tasks.length) {
      el.innerHTML = '<div class="empty">No tasks yet. <a href="/submit" style="color:var(--accent)">Submit one!</a></div>';
      return;
    }
    el.innerHTML = tasks.map(function(t) {
      var status = (t.status || 'unknown').toLowerCase();
      var statusClass = status.indexOf('complete') >= 0 ? 'completed' :
        status.indexOf('fail') >= 0 ? 'failed' :
        status.indexOf('dispatch') >= 0 || status.indexOf('running') >= 0 ? 'dispatched' : 'pending';
      var time = t.created_at || t.submitted_at || '';
      var sender = t.sender || '';
      var worker = t.worker || '';
      return '<div class="task-card">' +
        '<div class="task-header">' +
          '<span class="task-id">' + (t.task_id || t.id || '?').substring(0, 12) + '</span>' +
          '<span class="task-status status-' + statusClass + '">' + status + '</span>' +
        '</div>' +
        '<div class="task-text">' + escapeHtml(t.text || t.description || '') + '</div>' +
        '<div class="task-meta">' +
          (sender ? 'By: ' + escapeHtml(sender) + ' &bull; ' : '') +
          (worker ? 'Worker: ' + escapeHtml(worker) + ' &bull; ' : '') +
          (time ? 'Submitted: ' + new Date(time).toLocaleString() : '') +
        '</div>' +
      '</div>';
    }).join('');
  } catch (err) {
    el.innerHTML = '<div class="empty">Could not load tasks: ' + err.message + '</div>';
  }
}
function escapeHtml(s) {
  var d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}
loadTasks();
</script>
</body>
</html>`;
}

// --- Proxy handlers (dashboard to dispatcher API) ---

function renderTokensPage(username) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>API Tokens - BoothApp</title>
<style>
  :root { --bg: #0d1117; --card: #161b22; --border: #30363d; --text: #e6edf3; --muted: #8b949e; --accent: #4da6ff; --green: #3fb950; --red: #f85149; --yellow: #e3b341; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; }
  .nav { display: flex; align-items: center; gap: 16px; padding: 12px 24px; background: var(--card); border-bottom: 1px solid var(--border); }
  .nav a { color: var(--muted); text-decoration: none; font-size: 0.9rem; padding: 6px 12px; border-radius: 6px; }
  .nav a:hover { color: var(--text); background: rgba(255,255,255,0.05); }
  .nav a.active { color: var(--accent); background: rgba(77,166,255,0.1); }
  .nav .user { margin-left: auto; color: var(--muted); font-size: 0.85rem; }
  .container { max-width: 800px; margin: 32px auto; padding: 0 24px; }
  h1 { margin-bottom: 8px; font-size: 1.5rem; }
  .subtitle { color: var(--muted); margin-bottom: 24px; font-size: 0.9rem; }
  .token-table { width: 100%; border-collapse: collapse; margin-bottom: 24px; }
  .token-table th, .token-table td { text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--border); }
  .token-table th { color: var(--muted); font-weight: 600; font-size: 0.85rem; text-transform: uppercase; }
  .token-table td { font-family: monospace; font-size: 0.9rem; }
  .token-table tr:hover td { background: rgba(255,255,255,0.02); }
  .btn { display: inline-block; padding: 6px 14px; border-radius: 6px; border: none; cursor: pointer; font-size: 0.85rem; font-weight: 600; }
  .btn-danger { background: rgba(248,81,73,0.15); color: var(--red); }
  .btn-danger:hover { background: rgba(248,81,73,0.3); }
  .btn-primary { background: rgba(77,166,255,0.15); color: var(--accent); }
  .btn-primary:hover { background: rgba(77,166,255,0.3); }
  .add-form { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px; margin-bottom: 24px; }
  .add-form h3 { margin-bottom: 12px; font-size: 1rem; }
  .form-row { display: flex; gap: 12px; align-items: flex-end; }
  .form-row .field { flex: 1; }
  .form-row label { display: block; color: var(--muted); font-size: 0.8rem; margin-bottom: 4px; }
  .form-row input { width: 100%; padding: 8px 12px; background: var(--bg); border: 1px solid var(--border); border-radius: 6px; color: var(--text); font-family: monospace; font-size: 0.9rem; }
  .form-row input:focus { outline: none; border-color: var(--accent); }
  .msg { padding: 10px 14px; border-radius: 6px; margin-bottom: 16px; font-size: 0.9rem; }
  .msg-success { background: rgba(63,185,80,0.15); color: var(--green); }
  .msg-error { background: rgba(248,81,73,0.15); color: var(--red); }
  .loading { text-align: center; color: var(--muted); padding: 40px; }
  .admin-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; background: rgba(227,179,65,0.2); color: var(--yellow); margin-left: 8px; }
</style>
</head>
<body>
<div class="nav">
  <a href="/">Dashboard</a>
  <a href="/submit">Submit Task</a>
  <a href="/tasks">Task History</a>
  <a href="/tokens" class="active">API Tokens</a>
  <a href="/admin">Admin</a>
  <span class="user">\${escHtml(username)} | <a href="/logout" style="color:var(--muted)">Logout</a></span>
</div>
<div class="container">
  <h1>API Tokens</h1>
  <div class="subtitle">Manage bearer tokens for the CLaaS API. Each token maps to a project namespace.</div>
  <div id="msg"></div>
  <div class="add-form">
    <h3>Create New Token</h3>
    <div class="form-row">
      <div class="field">
        <label>Token</label>
        <input type="text" id="newToken" placeholder="e.g. team-gamma">
      </div>
      <div class="field">
        <label>Project</label>
        <input type="text" id="newProject" placeholder="e.g. team-gamma">
      </div>
      <button class="btn btn-primary" onclick="createToken()">Create</button>
    </div>
  </div>
  <table class="token-table">
    <thead><tr><th>Token</th><th>Project</th><th></th></tr></thead>
    <tbody id="tokenList"><tr><td colspan="3" class="loading">Loading...</td></tr></tbody>
  </table>
</div>
<script>
var CLAAS_TOKEN = '${escHtml(DISPATCH_API_TOKEN || 'default')}';

function showMsg(text, type) {
  var el = document.getElementById('msg');
  el.className = 'msg msg-' + type;
  el.textContent = text;
  setTimeout(function() { el.className = ''; el.textContent = ''; }, 4000);
}

async function loadTokens() {
  try {
    var resp = await fetch('/api/v1/tokens', { headers: { 'Authorization': 'Bearer ' + CLAAS_TOKEN } });
    var data = await resp.json();
    var tokens = data.tokens || [];
    var tbody = document.getElementById('tokenList');
    if (!tokens.length) {
      tbody.innerHTML = '<tr><td colspan="3" style="color:var(--muted);text-align:center">No tokens configured.</td></tr>';
      return;
    }
    tbody.innerHTML = tokens.map(function(t) {
      var isAdmin = t.token === CLAAS_TOKEN;
      return '<tr>' +
        '<td>' + escapeHtml(t.token) + (isAdmin ? '<span class="admin-badge">admin</span>' : '') + '</td>' +
        '<td>' + escapeHtml(t.project) + '</td>' +
        '<td style="text-align:right">' +
        (isAdmin ? '' : '<button class="btn btn-danger" onclick="revokeToken(\\'' + escapeHtml(t.token) + '\\')">Revoke</button>') +
        '</td></tr>';
    }).join('');
  } catch (err) {
    document.getElementById('tokenList').innerHTML = '<tr><td colspan="3" style="color:var(--red)">Error loading tokens: ' + err.message + '</td></tr>';
  }
}

async function createToken() {
  var token = document.getElementById('newToken').value.trim();
  var project = document.getElementById('newProject').value.trim();
  if (!token || !project) { showMsg('Token and project are required.', 'error'); return; }
  try {
    var resp = await fetch('/api/v1/tokens', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + CLAAS_TOKEN, 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: token, project: project })
    });
    var data = await resp.json();
    if (resp.ok) {
      showMsg('Token "' + token + '" created for project "' + project + '".', 'success');
      document.getElementById('newToken').value = '';
      document.getElementById('newProject').value = '';
      loadTokens();
    } else {
      showMsg(data.error || 'Failed to create token.', 'error');
    }
  } catch (err) {
    showMsg('Error: ' + err.message, 'error');
  }
}

async function revokeToken(token) {
  if (!confirm('Revoke token "' + token + '"? This cannot be undone.')) return;
  try {
    var resp = await fetch('/api/v1/tokens/revoke', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + CLAAS_TOKEN, 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: token })
    });
    var data = await resp.json();
    if (resp.ok) {
      showMsg('Token "' + token + '" revoked.', 'success');
      loadTokens();
    } else {
      showMsg(data.error || 'Failed to revoke.', 'error');
    }
  } catch (err) {
    showMsg('Error: ' + err.message, 'error');
  }
}

function escapeHtml(s) { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

loadTokens();
</script>
</body>
</html>`;
}

// --- S3 Session helpers ---

const S3_BUCKET = process.env.SESSION_BUCKET || 'boothapp-sessions-752266476357';
const S3_REGION = process.env.AWS_REGION || 'us-east-2';
const S3_PROFILE = process.env.AWS_PROFILE || 'default';

function s3Cmd(args) {
  try {
    const cmd = `aws s3 ${args} --region ${S3_REGION}`;
    return execSync(cmd, { encoding: 'utf-8', timeout: 10000 }).trim();
  } catch (e) {
    return '';
  }
}

function s3ApiCmd(args) {
  try {
    const cmd = `aws s3api ${args} --region ${S3_REGION}`;
    return execSync(cmd, { encoding: 'utf-8', timeout: 10000 }).trim();
  } catch (e) {
    return '';
  }
}

function listSessions() {
  const raw = s3Cmd(`ls s3://${S3_BUCKET}/sessions/`);
  if (!raw) return [];
  return raw.split('\n')
    .map(line => line.replace(/.*PRE\s+/, '').replace(/\/$/, '').trim())
    .filter(id => id.length > 0);
}

function getSessionDetail(sessionId) {
  // Sanitize session ID
  const safeId = sessionId.replace(/[^a-zA-Z0-9_-]/g, '');
  const result = { session_id: safeId, metadata: null, summary: null, files: [] };

  // List files
  const raw = s3Cmd(`ls s3://${S3_BUCKET}/sessions/${safeId}/ --recursive`);
  if (raw) {
    result.files = raw.split('\n').map(line => {
      const parts = line.trim().split(/\s+/);
      return { date: parts[0], time: parts[1], size: parseInt(parts[2]) || 0, key: parts[3] || '' };
    }).filter(f => f.key);
  }

  // Get metadata
  try {
    const meta = s3ApiCmd(`get-object --bucket ${S3_BUCKET} --key sessions/${safeId}/metadata.json /dev/stdout`);
    if (meta) result.metadata = JSON.parse(meta);
  } catch (e) { /* no metadata */ }

  // Get summary
  try {
    const summary = s3ApiCmd(`get-object --bucket ${S3_BUCKET} --key sessions/${safeId}/output/summary.txt /dev/stdout`);
    if (summary) result.summary = summary;
  } catch (e) { /* no summary */ }

  return result;
}

function handleApiSessions(req, res) {
  const sessions = listSessions();
  const details = sessions.map(id => {
    const detail = getSessionDetail(id);
    return {
      session_id: id,
      visitor_name: detail.metadata ? detail.metadata.visitor_name : null,
      visitor_company: detail.metadata ? detail.metadata.visitor_company : null,
      status: detail.metadata ? detail.metadata.status : 'unknown',
      started_at: detail.metadata ? detail.metadata.started_at : null,
      has_summary: !!detail.summary,
      file_count: detail.files.length,
    };
  });
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ sessions: details, count: details.length }));
}

function handleApiSessionDetail(req, res, sessionId) {
  const detail = getSessionDetail(sessionId);
  if (!detail.metadata && detail.files.length === 0) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Session not found' }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(detail));
}

function renderSessionsPage(username) {
  return `<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Sessions — BoothApp Dashboard</title>
<style>
  :root { --bg: #0d1117; --card: #161b22; --border: #30363d; --text: #c9d1d9; --muted: #8b949e; --accent: #58a6ff; --green: #3fb950; --red: #f85149; --yellow: #d29922; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, sans-serif; }
  .nav { display: flex; gap: 0; background: var(--card); border-bottom: 1px solid var(--border); padding: 0 16px; }
  .nav a { padding: 12px 16px; color: var(--muted); text-decoration: none; font-size: 0.9rem; border-bottom: 2px solid transparent; }
  .nav a:hover { color: var(--text); }
  .nav a.active { color: var(--accent); border-bottom-color: var(--accent); }
  .nav .user { margin-left: auto; padding: 12px 0; color: var(--muted); font-size: 0.85rem; }
  .nav .user a { padding: 0; display: inline; }
  .container { max-width: 960px; margin: 24px auto; padding: 0 16px; }
  h1 { margin-bottom: 8px; font-size: 1.5rem; }
  .subtitle { color: var(--muted); margin-bottom: 24px; font-size: 0.9rem; }
  .session-card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 12px; cursor: pointer; transition: border-color 0.2s; }
  .session-card:hover { border-color: var(--accent); }
  .session-header { display: flex; justify-content: space-between; align-items: center; }
  .session-name { font-weight: 600; font-size: 1.1rem; }
  .session-meta { color: var(--muted); font-size: 0.85rem; margin-top: 4px; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; }
  .badge-complete { background: rgba(63,185,80,0.15); color: var(--green); }
  .badge-pending { background: rgba(210,153,34,0.15); color: var(--yellow); }
  .session-detail { display: none; margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--border); }
  .session-detail.open { display: block; }
  .summary-box { background: var(--bg); border: 1px solid var(--border); border-radius: 6px; padding: 12px; white-space: pre-wrap; font-size: 0.85rem; line-height: 1.5; max-height: 400px; overflow-y: auto; }
  .file-list { margin-top: 8px; }
  .file-list div { font-size: 0.8rem; color: var(--muted); padding: 2px 0; }
  .loading { color: var(--muted); text-align: center; padding: 48px; }
  .empty { color: var(--muted); text-align: center; padding: 48px; }
</style>
</head>
<body>
<div class="nav">
  <a href="/">Dashboard</a>
  <a href="/submit">Submit Task</a>
  <a href="/tasks">Task History</a>
  <a href="/sessions" class="active">Sessions</a>
  <a href="/tokens">API Tokens</a>
  <a href="/admin">Admin</a>
  <span class="user">${escHtml(username)} | <a href="/logout" style="color:var(--muted)">Logout</a></span>
</div>
<div class="container">
  <h1>Demo Sessions</h1>
  <div class="subtitle">Booth demo sessions captured to S3. Click a session to see the analysis summary.</div>
  <div id="sessionList"><div class="loading">Loading sessions...</div></div>
</div>
<script>
async function loadSessions() {
  var el = document.getElementById('sessionList');
  try {
    var resp = await fetch('/api/sessions');
    var data = await resp.json();
    if (!data.sessions || data.sessions.length === 0) {
      el.innerHTML = '<div class="empty">No sessions found in S3.</div>';
      return;
    }
    el.innerHTML = data.sessions.map(function(s) {
      var name = s.visitor_name || 'Unknown Visitor';
      var company = s.visitor_company || '';
      var time = s.started_at ? new Date(s.started_at).toLocaleString() : 'Unknown time';
      var badge = s.status === 'completed'
        ? '<span class="badge badge-complete">completed</span>'
        : '<span class="badge badge-pending">' + (s.status || 'unknown') + '</span>';
      var summaryIcon = s.has_summary ? ' &bull; Summary available' : '';
      return '<div class="session-card" onclick="toggleSession(this, \\'' + s.session_id + '\\')">'
        + '<div class="session-header"><span class="session-name">' + escH(name) + (company ? ' &mdash; ' + escH(company) : '') + '</span>' + badge + '</div>'
        + '<div class="session-meta">ID: ' + s.session_id + ' &bull; ' + time + ' &bull; ' + s.file_count + ' files' + summaryIcon + '</div>'
        + '<div class="session-detail" id="detail-' + s.session_id + '"><div class="loading">Loading...</div></div>'
        + '</div>';
    }).join('');
  } catch (e) {
    el.innerHTML = '<div class="empty">Error loading sessions: ' + e.message + '</div>';
  }
}

async function toggleSession(card, sessionId) {
  var detail = document.getElementById('detail-' + sessionId);
  if (detail.classList.contains('open')) {
    detail.classList.remove('open');
    return;
  }
  detail.classList.add('open');
  if (detail.dataset.loaded) return;
  try {
    var resp = await fetch('/api/sessions/' + sessionId);
    var data = await resp.json();
    var html = '';
    if (data.summary) {
      html += '<h3 style="margin-bottom:8px;font-size:0.95rem">Analysis Summary</h3>';
      html += '<div class="summary-box">' + escH(data.summary) + '</div>';
    } else {
      html += '<div style="color:var(--muted)">No analysis summary available yet.</div>';
    }
    if (data.metadata) {
      html += '<h3 style="margin:12px 0 8px;font-size:0.95rem">Metadata</h3>';
      html += '<div class="summary-box">' + escH(JSON.stringify(data.metadata, null, 2)) + '</div>';
    }
    if (data.files && data.files.length > 0) {
      html += '<h3 style="margin:12px 0 8px;font-size:0.95rem">Files (' + data.files.length + ')</h3>';
      html += '<div class="file-list">' + data.files.map(function(f) {
        var size = f.size > 1048576 ? (f.size/1048576).toFixed(1) + ' MB' : f.size > 1024 ? (f.size/1024).toFixed(0) + ' KB' : f.size + ' B';
        return '<div>' + escH(f.key) + ' (' + size + ')</div>';
      }).join('') + '</div>';
    }
    detail.innerHTML = html;
    detail.dataset.loaded = '1';
  } catch (e) {
    detail.innerHTML = '<div style="color:var(--red)">Error: ' + e.message + '</div>';
  }
}

function escH(s) { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

loadSessions();
</script>
</body>
</html>`;
}

function handleProxySubmit(req, res) {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    const headers = {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    };
    if (DISPATCH_API_TOKEN) headers['Authorization'] = 'Bearer ' + DISPATCH_API_TOKEN;
    const proxyReq = http.request({
      hostname: '127.0.0.1',
      port: 8080,
      path: '/api/submit',
      method: 'POST',
      headers,
      timeout: 30000,
    }, proxyRes => {
      let data = '';
      proxyRes.on('data', c => { data += c; });
      proxyRes.on('end', () => {
        res.writeHead(proxyRes.statusCode, { 'Content-Type': 'application/json' });
        res.end(data);
      });
    });
    proxyReq.on('error', err => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Dispatcher unreachable', detail: err.message }));
    });
    proxyReq.end(body);
  });
}

function handleProxyTasks(req, res) {
  const proxyReq = http.request({
    hostname: '127.0.0.1',
    port: 8080,
    path: '/api/tasks',
    method: 'GET',
    timeout: 10000,
  }, proxyRes => {
    let data = '';
    proxyRes.on('data', c => { data += c; });
    proxyRes.on('end', () => {
      res.writeHead(proxyRes.statusCode, {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      });
      res.end(data);
    });
  });
  proxyReq.on('error', err => {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Dispatcher unreachable', detail: err.message }));
  });
  proxyReq.end();
}

// --- Request routing ---

const server = http.createServer((req, res) => {
  // CLaaS v1 API proxy — pass through to dispatcher with auth headers
  if (req.url.startsWith('/api/v1/')) {
    const proxyOpts = {
      hostname: '127.0.0.1', port: 8080,
      path: req.url, method: req.method,
      headers: { ...req.headers, host: '127.0.0.1:8080' },
      timeout: 300000, // 5min for long-running tasks
    };
    const proxyReq = http.request(proxyOpts, proxyRes => {
      const chunks = [];
      proxyRes.on('data', c => chunks.push(c));
      proxyRes.on('end', () => {
        res.writeHead(proxyRes.statusCode, {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Headers': 'Authorization, Content-Type',
        });
        res.end(Buffer.concat(chunks));
      });
    });
    proxyReq.on('error', err => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Dispatcher unreachable', detail: err.message }));
    });
    if (req.method === 'POST') {
      const bodyChunks = [];
      req.on('data', c => bodyChunks.push(c));
      req.on('end', () => { proxyReq.end(Buffer.concat(bodyChunks)); });
    } else if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type',
      });
      res.end();
      return;
    } else {
      proxyReq.end();
    }
    return;
  }

  // Unauthenticated routes: collector API + health proxy
  if (req.method === 'POST' && req.url.match(/^\/api\/stats\/\w+$/)) {
    return handlePost(req, res);
  }
  if (req.url === '/api/stats') {
    return handleGetStats(req, res);
  }
  if (req.url === '/health') {
    const proxy = http.get('http://127.0.0.1:8080/health', proxyRes => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    });
    proxy.on('error', () => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'dispatcher health unreachable' }));
    });
    proxy.setTimeout(5000, () => { proxy.destroy(); });
    return;
  }

  // Prometheus metrics endpoint (unauthenticated for scraping)
  if (req.url === '/metrics') {
    const proxy = http.get('http://127.0.0.1:8080/health', proxyRes => {
      let data = '';
      proxyRes.on('data', c => { data += c; });
      proxyRes.on('end', () => {
        try {
          const h = JSON.parse(data);
          const roster = h.fleet_roster || {};
          const workers = Object.values(roster);
          const idle = workers.filter(w => w.status === 'idle').length;
          const busy = workers.filter(w => w.status === 'busy').length;
          const stopping = workers.filter(w => w.status === 'stopping').length;
          const lines = [
            '# HELP claas_workers_total Total registered workers',
            '# TYPE claas_workers_total gauge',
            'claas_workers_total ' + workers.length,
            '# HELP claas_workers_idle Idle workers available for tasks',
            '# TYPE claas_workers_idle gauge',
            'claas_workers_idle ' + idle,
            '# HELP claas_workers_busy Workers currently executing tasks',
            '# TYPE claas_workers_busy gauge',
            'claas_workers_busy ' + busy,
            '# HELP claas_workers_stopping Workers being stopped',
            '# TYPE claas_workers_stopping gauge',
            'claas_workers_stopping ' + stopping,
            '# HELP claas_tasks_submitted_total Total tasks dispatched',
            '# TYPE claas_tasks_submitted_total counter',
            'claas_tasks_submitted_total ' + (h.total_dispatches || 0),
            '# HELP claas_tasks_completed_total Total tasks completed',
            '# TYPE claas_tasks_completed_total counter',
            'claas_tasks_completed_total ' + (h.total_completions || 0),
            '# HELP claas_tasks_pending Current pending tasks',
            '# TYPE claas_tasks_pending gauge',
            'claas_tasks_pending ' + (h.pending_tasks || 0),
            '# HELP claas_dispatcher_uptime_seconds Dispatcher uptime',
            '# TYPE claas_dispatcher_uptime_seconds gauge',
            'claas_dispatcher_uptime_seconds ' + (h.uptime_seconds || 0),
            '# HELP claas_errors_total Total dispatcher errors',
            '# TYPE claas_errors_total counter',
            'claas_errors_total ' + (h.errors || 0),
            '',
          ];
          res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4; charset=utf-8' });
          res.end(lines.join('\n'));
        } catch (e) {
          res.writeHead(502, { 'Content-Type': 'text/plain' });
          res.end('# Failed to parse dispatcher health\n');
        }
      });
    });
    proxy.on('error', () => {
      res.writeHead(502, { 'Content-Type': 'text/plain' });
      res.end('# Dispatcher unreachable\n');
    });
    proxy.setTimeout(5000, () => { proxy.destroy(); });
    return;
  }

  // Auth routes (no session required)
  if (req.url === '/login') return auth.handleLogin(req, res);
  if (req.url === '/logout') return auth.handleLogout(req, res);

  // mTLS auto-auth: check cert header before requiring login
  let check = mtlsAutoAuth(req, res);
  if (!check) {
    check = auth.checkAuth(req);
  }
  if (!check.authenticated) {
    res.writeHead(302, { 'Location': '/login' });
    res.end();
    return;
  }
  if (check.redirect) {
    res.writeHead(302, { 'Location': check.redirect });
    res.end();
    return;
  }

  // Authenticated routes
  if (req.url === '/change-password') return auth.handleChangePassword(req, res);
  if (req.url === '/admin' && req.method === 'GET') return auth.handleAdmin(req, res);
  if (req.url === '/admin/add-user' && req.method === 'POST') return auth.handleAdminAddUser(req, res);
  if (req.url === '/admin/reset-password' && req.method === 'POST') return auth.handleAdminResetPassword(req, res);
  if (req.url === '/admin/delete-user' && req.method === 'POST') return auth.handleAdminDeleteUser(req, res);

  // Submit page
  if (req.url === '/submit' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(renderSubmitPage(check.username));
    return;
  }

  // Tasks page
  if (req.url === '/tasks' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(renderTasksPage(check.username));
    return;
  }

  // Tokens management page
  if (req.url === '/tokens' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(renderTokensPage(check.username));
    return;
  }

  // Sessions page
  if (req.url === '/sessions' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(renderSessionsPage(check.username));
    return;
  }

  // Session API endpoints (authenticated)
  if (req.url === '/api/sessions' && req.method === 'GET') {
    return handleApiSessions(req, res);
  }
  const sessionMatch = req.url.match(/^\/api\/sessions\/([a-zA-Z0-9_-]+)$/);
  if (sessionMatch && req.method === 'GET') {
    return handleApiSessionDetail(req, res, sessionMatch[1]);
  }

  // API proxies (authenticated)
  if (req.url === '/api/proxy/submit' && req.method === 'POST') {
    return handleProxySubmit(req, res);
  }
  if (req.url === '/api/proxy/tasks') {
    return handleProxyTasks(req, res);
  }

  if (req.url === '/' || req.url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(renderDashboard(check.username));
    return;
  }

  res.writeHead(404);
  res.end('Not found');
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Central dashboard listening on http://0.0.0.0:${PORT}`);
});
