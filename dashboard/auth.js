#!/usr/bin/env node
'use strict';
/**
 * Dashboard Authentication Module
 *
 * - User store persisted to dashboard/users.json
 * - Passwords hashed with crypto.scryptSync
 * - Session tokens in memory (cookie-based)
 * - Default admin/admin with forced password change
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const USERS_FILE = path.join(__dirname, 'users.json');
const SESSION_TTL_MS = 8 * 60 * 60 * 1000; // 8 hours

// In-memory session store: { token: { username, created_at } }
const sessions = {};

// --- Password hashing ---

function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 64).toString('hex');
  return salt + ':' + hash;
}

function verifyPassword(password, stored) {
  const [salt, hash] = stored.split(':');
  const check = crypto.scryptSync(password, salt, 64).toString('hex');
  return crypto.timingSafeEqual(Buffer.from(hash, 'hex'), Buffer.from(check, 'hex'));
}

// --- User store ---

function loadUsers() {
  try {
    return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
  } catch {
    return null;
  }
}

function saveUsers(users) {
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2), 'utf8');
}

function ensureUsersFile() {
  const users = loadUsers();
  if (!users) {
    const defaultUsers = {
      admin: {
        password_hash: hashPassword('admin'),
        role: 'admin',
        force_password_change: true,
        created_at: new Date().toISOString(),
      },
    };
    saveUsers(defaultUsers);
    console.log('Created default admin user (admin/admin, password change required)');
  }
}

// --- Session management ---

function createSession(username) {
  const token = crypto.randomUUID();
  sessions[token] = { username, created_at: Date.now() };
  return token;
}

function getSession(token) {
  const s = sessions[token];
  if (!s) return null;
  if (Date.now() - s.created_at > SESSION_TTL_MS) {
    delete sessions[token];
    return null;
  }
  return s;
}

function destroySession(token) {
  delete sessions[token];
}

function getSessionFromReq(req) {
  const cookies = parseCookies(req.headers.cookie || '');
  const token = cookies.session;
  if (!token) return null;
  return { token, session: getSession(token) };
}

function parseCookies(cookieHeader) {
  const out = {};
  cookieHeader.split(';').forEach(pair => {
    const [k, ...v] = pair.trim().split('=');
    if (k) out[k.trim()] = v.join('=').trim();
  });
  return out;
}

function sessionCookie(token, clear) {
  if (clear) {
    return 'session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0';
  }
  return `session=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${SESSION_TTL_MS / 1000}`;
}

// --- Auth check (middleware-style) ---
// Returns { authenticated, username, user, redirect } or null

function checkAuth(req) {
  const info = getSessionFromReq(req);
  if (!info || !info.session) {
    return { authenticated: false, redirect: '/login' };
  }
  const users = loadUsers();
  const user = users[info.session.username];
  if (!user) {
    destroySession(info.token);
    return { authenticated: false, redirect: '/login' };
  }
  if (user.force_password_change && req.url !== '/change-password' && req.url !== '/logout') {
    return { authenticated: true, username: info.session.username, user, redirect: '/change-password' };
  }
  return { authenticated: true, username: info.session.username, user, token: info.token };
}

// --- Route handlers ---

function handleLogin(req, res) {
  if (req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(loginPage());
    return;
  }
  if (req.method === 'POST') {
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => {
      const params = new URLSearchParams(body);
      const username = (params.get('username') || '').trim();
      const password = params.get('password') || '';
      const users = loadUsers();
      const user = users[username];
      if (!user || !verifyPassword(password, user.password_hash)) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(loginPage('Invalid username or password'));
        return;
      }
      const token = createSession(username);
      if (user.force_password_change) {
        res.writeHead(302, {
          'Set-Cookie': sessionCookie(token),
          'Location': '/change-password',
        });
        res.end();
      } else {
        res.writeHead(302, {
          'Set-Cookie': sessionCookie(token),
          'Location': '/',
        });
        res.end();
      }
    });
    return;
  }
  res.writeHead(405); res.end();
}

function handleChangePassword(req, res) {
  const auth = checkAuth(req);
  if (!auth.authenticated) {
    res.writeHead(302, { 'Location': '/login' }); res.end(); return;
  }
  if (req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(changePasswordPage(auth.user.force_password_change));
    return;
  }
  if (req.method === 'POST') {
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => {
      const params = new URLSearchParams(body);
      const newPass = params.get('new_password') || '';
      const confirm = params.get('confirm_password') || '';
      if (newPass.length < 4) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(changePasswordPage(auth.user.force_password_change, 'Password must be at least 4 characters'));
        return;
      }
      if (newPass !== confirm) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(changePasswordPage(auth.user.force_password_change, 'Passwords do not match'));
        return;
      }
      const users = loadUsers();
      users[auth.username].password_hash = hashPassword(newPass);
      users[auth.username].force_password_change = false;
      saveUsers(users);
      res.writeHead(302, { 'Location': '/' }); res.end();
    });
    return;
  }
  res.writeHead(405); res.end();
}

function handleLogout(req, res) {
  const info = getSessionFromReq(req);
  if (info && info.token) destroySession(info.token);
  res.writeHead(302, {
    'Set-Cookie': sessionCookie('', true),
    'Location': '/login',
  });
  res.end();
}

function handleAdmin(req, res) {
  const auth = checkAuth(req);
  if (!auth.authenticated) {
    res.writeHead(302, { 'Location': '/login' }); res.end(); return;
  }
  if (auth.redirect) {
    res.writeHead(302, { 'Location': auth.redirect }); res.end(); return;
  }
  if (auth.user.role !== 'admin') {
    res.writeHead(403, { 'Content-Type': 'text/html' });
    res.end(errorPage('Access denied — admin only'));
    return;
  }
  if (req.method === 'GET') {
    const users = loadUsers();
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(adminPage(users, auth.username));
    return;
  }
  res.writeHead(405); res.end();
}

function handleAdminAddUser(req, res) {
  const auth = checkAuth(req);
  if (!auth.authenticated || auth.user.role !== 'admin') {
    res.writeHead(403); res.end('Forbidden'); return;
  }
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    const params = new URLSearchParams(body);
    const username = (params.get('username') || '').trim().toLowerCase();
    const password = params.get('password') || '';
    const role = params.get('role') === 'admin' ? 'admin' : 'viewer';
    if (!username || username.length < 2) {
      res.writeHead(302, { 'Location': '/admin?error=Username+must+be+at+least+2+characters' }); res.end(); return;
    }
    if (!password || password.length < 4) {
      res.writeHead(302, { 'Location': '/admin?error=Password+must+be+at+least+4+characters' }); res.end(); return;
    }
    if (!/^[a-z0-9_-]+$/.test(username)) {
      res.writeHead(302, { 'Location': '/admin?error=Username+must+be+alphanumeric' }); res.end(); return;
    }
    const users = loadUsers();
    if (users[username]) {
      res.writeHead(302, { 'Location': '/admin?error=User+already+exists' }); res.end(); return;
    }
    users[username] = {
      password_hash: hashPassword(password),
      role,
      force_password_change: true,
      created_at: new Date().toISOString(),
    };
    saveUsers(users);
    res.writeHead(302, { 'Location': '/admin?msg=User+' + username + '+created' }); res.end();
  });
}

function handleAdminResetPassword(req, res) {
  const auth = checkAuth(req);
  if (!auth.authenticated || auth.user.role !== 'admin') {
    res.writeHead(403); res.end('Forbidden'); return;
  }
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    const params = new URLSearchParams(body);
    const targetUser = (params.get('username') || '').trim();
    const newPass = params.get('new_password') || '';
    const users = loadUsers();
    if (!users[targetUser]) {
      res.writeHead(302, { 'Location': '/admin?error=User+not+found' }); res.end(); return;
    }
    if (newPass.length < 4) {
      res.writeHead(302, { 'Location': '/admin?error=Password+must+be+at+least+4+characters' }); res.end(); return;
    }
    users[targetUser].password_hash = hashPassword(newPass);
    users[targetUser].force_password_change = true;
    saveUsers(users);
    // Invalidate any active sessions for that user
    for (const [tok, sess] of Object.entries(sessions)) {
      if (sess.username === targetUser) delete sessions[tok];
    }
    res.writeHead(302, { 'Location': '/admin?msg=Password+reset+for+' + targetUser }); res.end();
  });
}

function handleAdminDeleteUser(req, res) {
  const auth = checkAuth(req);
  if (!auth.authenticated || auth.user.role !== 'admin') {
    res.writeHead(403); res.end('Forbidden'); return;
  }
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    const params = new URLSearchParams(body);
    const targetUser = (params.get('username') || '').trim();
    if (targetUser === auth.username) {
      res.writeHead(302, { 'Location': '/admin?error=Cannot+delete+yourself' }); res.end(); return;
    }
    const users = loadUsers();
    if (!users[targetUser]) {
      res.writeHead(302, { 'Location': '/admin?error=User+not+found' }); res.end(); return;
    }
    delete users[targetUser];
    saveUsers(users);
    for (const [tok, sess] of Object.entries(sessions)) {
      if (sess.username === targetUser) delete sessions[tok];
    }
    res.writeHead(302, { 'Location': '/admin?msg=User+' + targetUser + '+deleted' }); res.end();
  });
}

// --- HTML pages ---

function pageShell(title, bodyHtml) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title} - BoothApp Dashboard</title>
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
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
  }
  .container {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 32px; width: 100%; max-width: 440px;
  }
  .container.wide { max-width: 700px; }
  h1 { color: #fff; font-size: 1.5rem; margin-bottom: 24px; text-align: center; }
  label { display: block; color: var(--muted); font-size: 0.85rem; margin-bottom: 4px; margin-top: 16px; }
  input[type="text"], input[type="password"], select {
    width: 100%; padding: 10px 12px; background: var(--bg); color: var(--text);
    border: 1px solid var(--border); border-radius: 6px; font-size: 1rem;
    outline: none;
  }
  input:focus { border-color: var(--accent); }
  button, .btn {
    display: inline-block; padding: 10px 20px; background: var(--accent); color: #fff;
    border: none; border-radius: 6px; font-size: 1rem; cursor: pointer;
    margin-top: 20px; text-decoration: none; text-align: center;
  }
  button:hover, .btn:hover { opacity: 0.9; }
  .btn-danger { background: var(--red); }
  .btn-small { padding: 6px 12px; font-size: 0.85rem; margin-top: 0; }
  .error { color: var(--red); font-size: 0.9rem; margin-top: 12px; text-align: center; }
  .success { color: var(--green); font-size: 0.9rem; margin-top: 12px; text-align: center; }
  .info { color: var(--yellow); font-size: 0.9rem; margin-top: 12px; text-align: center; }
  table { width: 100%; border-collapse: collapse; margin-top: 16px; }
  th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid var(--border); }
  th { color: var(--muted); font-size: 0.8rem; text-transform: uppercase; }
  td { font-size: 0.9rem; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; }
  .badge-admin { background: #2d333b; color: var(--accent); }
  .badge-viewer { background: #2d333b; color: var(--muted); }
  .badge-reset { background: #442200; color: var(--yellow); }
  .top-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; }
  .top-bar h1 { margin-bottom: 0; }
  .top-bar a { color: var(--muted); font-size: 0.85rem; text-decoration: none; }
  .top-bar a:hover { color: var(--text); }
  hr { border: none; border-top: 1px solid var(--border); margin: 24px 0; }
  .form-row { display: flex; gap: 8px; align-items: flex-end; }
  .form-row > div { flex: 1; }
  .actions { display: flex; gap: 4px; }
</style>
</head>
<body>
${bodyHtml}
</body>
</html>`;
}

function loginPage(error) {
  return pageShell('Login', `
<div class="container">
  <h1>BoothApp Central</h1>
  <form method="POST" action="/login">
    <label for="username">Username</label>
    <input type="text" id="username" name="username" autocomplete="username" autofocus required>
    <label for="password">Password</label>
    <input type="password" id="password" name="password" autocomplete="current-password" required>
    ${error ? `<div class="error">${escHtml(error)}</div>` : ''}
    <button type="submit" style="width:100%">Sign In</button>
  </form>
</div>`);
}

function changePasswordPage(forced, error) {
  return pageShell('Change Password', `
<div class="container">
  <h1>Change Password</h1>
  ${forced ? '<div class="info">You must change your password before continuing.</div>' : ''}
  <form method="POST" action="/change-password">
    <label for="new_password">New Password</label>
    <input type="password" id="new_password" name="new_password" autocomplete="new-password" required minlength="4" autofocus>
    <label for="confirm_password">Confirm Password</label>
    <input type="password" id="confirm_password" name="confirm_password" autocomplete="new-password" required minlength="4">
    ${error ? `<div class="error">${escHtml(error)}</div>` : ''}
    <button type="submit" style="width:100%">Update Password</button>
  </form>
</div>`);
}

function adminPage(users, currentUser) {
  const qs = new URL('http://x' + (arguments.length > 2 ? arguments[2] : '')).searchParams;
  // parse from global — not ideal, will use raw query string approach
  const userRows = Object.entries(users).map(([name, u]) => {
    const isSelf = name === currentUser;
    return `<tr>
      <td>${escHtml(name)}</td>
      <td><span class="badge badge-${u.role}">${u.role}</span></td>
      <td>${u.force_password_change ? '<span class="badge badge-reset">pending</span>' : 'OK'}</td>
      <td>${u.created_at ? u.created_at.slice(0, 10) : '?'}</td>
      <td class="actions">
        ${isSelf ? '<span style="color:var(--muted);font-size:0.8rem">you</span>' : `
          <form method="POST" action="/admin/reset-password" style="display:inline">
            <input type="hidden" name="username" value="${escHtml(name)}">
            <input type="password" name="new_password" placeholder="new pw" style="width:80px;padding:4px 6px;font-size:0.8rem" required minlength="4">
            <button class="btn-small" type="submit">Reset</button>
          </form>
          <form method="POST" action="/admin/delete-user" style="display:inline" onsubmit="return confirm('Delete ${escHtml(name)}?')">
            <input type="hidden" name="username" value="${escHtml(name)}">
            <button class="btn-small btn-danger" type="submit">Del</button>
          </form>
        `}
      </td>
    </tr>`;
  }).join('');

  return pageShell('Admin', `
<div class="container wide">
  <div class="top-bar">
    <h1>User Management</h1>
    <div><a href="/">Dashboard</a> | <a href="/logout">Logout</a></div>
  </div>

  <table>
    <thead><tr><th>Username</th><th>Role</th><th>Password</th><th>Created</th><th>Actions</th></tr></thead>
    <tbody>${userRows}</tbody>
  </table>

  <hr>
  <h1 style="font-size:1.1rem;text-align:left">Add User</h1>
  <form method="POST" action="/admin/add-user">
    <div class="form-row">
      <div>
        <label for="new_username">Username</label>
        <input type="text" id="new_username" name="username" required minlength="2" pattern="[a-z0-9_-]+">
      </div>
      <div>
        <label for="new_user_password">Password</label>
        <input type="password" id="new_user_password" name="password" required minlength="4">
      </div>
      <div>
        <label for="new_user_role">Role</label>
        <select id="new_user_role" name="role">
          <option value="viewer">Viewer</option>
          <option value="admin">Admin</option>
        </select>
      </div>
    </div>
    <button type="submit">Add User</button>
  </form>
</div>`);
}

function errorPage(msg) {
  return pageShell('Error', `<div class="container"><h1>Error</h1><div class="error">${escHtml(msg)}</div><a class="btn" href="/" style="display:block;margin-top:20px">Back</a></div>`);
}

function escHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// --- mTLS cert auto-login ---
// Called when nginx verifies a client cert and passes X-Client-CN.
// Creates a session for the CN without requiring password.
function certAutoLogin(cn) {
  if (!cn) return null;
  const username = cn.toLowerCase().replace(/[^a-z0-9_-]/g, '');
  if (!username) return null;
  // Ensure user exists in the store (auto-create as viewer)
  const users = loadUsers();
  if (!users[username]) {
    users[username] = {
      password_hash: hashPassword(crypto.randomUUID()),
      role: 'viewer',
      force_password_change: false,
      created_at: new Date().toISOString(),
      cert_cn: cn,
    };
    saveUsers(users);
    console.log(`Auto-created user '${username}' from mTLS cert CN='${cn}'`);
  }
  return createSession(username);
}

module.exports = {
  ensureUsersFile,
  checkAuth,
  handleLogin,
  handleChangePassword,
  handleLogout,
  handleAdmin,
  handleAdminAddUser,
  handleAdminResetPassword,
  handleAdminDeleteUser,
  sessionCookie,
  certAutoLogin,
};
