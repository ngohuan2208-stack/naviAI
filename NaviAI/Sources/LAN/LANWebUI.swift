import Foundation

// MARK: - Remote Navi web UI

/// The zero-dependency web client served by the LAN server. Every PC / tablet /
/// other phone opens `http://<iphone>:8765` and gets this UI. It mirrors Navi:
/// Home, Chat, Browser, Tabs, Agent, Activity and Settings — with observation
/// and control gated by Navi's LAN permissions.
enum LANWebUI {

    static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>NaviAI · Remote</title>
    <link rel="stylesheet" href="/app.css">
    </head>
    <body>
      <div id="connbar" class="conn sync"><span id="conn-dot" class="dot"></span><span id="conn-text">Connecting…</span></div>
      <aside id="sidebar">
        <div class="brand"><span class="logo">◈</span> Navi<span>AI</span></div>
        <nav>
          <a data-pane="home" class="active"><span>🏠</span> Home</a>
          <a data-pane="chat"><span>💬</span> Chat</a>
          <a data-pane="browser"><span>🌐</span> Browser</a>
          <a data-pane="tabs"><span>🗂</span> Tabs</a>
          <a data-pane="agent"><span>🤖</span> Agent</a>
          <a data-pane="activity"><span>⚡</span> Activity</a>
          <a data-pane="settings"><span>⚙️</span> Settings</a>
        </nav>
        <div class="side-foot" id="side-foot">—</div>
      </aside>
      <main id="main">
        <section id="pane-home" class="pane active">
          <h1>Navi Remote</h1>
          <p class="sub" id="home-sub">Watching your iPhone from this device.</p>
          <div class="card-grid">
            <button class="quick" onclick="openYoutube()"><b>▶</b> YouTube</button>
            <button class="quick" onclick="openFacebook()"><b>f</b> Facebook</button>
            <button class="quick" onclick="openTiktok()"><b>♪</b> TikTok</button>
            <button class="quick" onclick="openNews()"><b>📰</b> News</button>
            <button class="quick" onclick="openSearch()"><b>🔍</b> Search</button>
            <button class="quick" onclick="cmd('readArticle',{})"><b>📄</b> Read article</button>
          </div>
          <div id="home-state" class="card">No state yet.</div>
        </section>

        <section id="pane-chat" class="pane">
          <h1>Task Chat</h1>
          <textarea id="chat-input" rows="3" placeholder="Give Navi a task, e.g. “Read 5 AI articles and summarize them.”"></textarea>
          <input id="chat-cont" placeholder="Optional continuation instruction (stays attached while the task runs)">
          <div class="row">
            <button class="primary" onclick="startTaskFromChat()">▶ Run continuously</button>
            <button onclick="cmd('agent.stop',{})">◼ Stop</button>
            <button onclick="cmd('agent.resume',{})">↩ Resume</button>
          </div>
          <div id="chat-last" class="card">—</div>
        </section>

        <section id="pane-browser" class="pane">
          <h1>Browser</h1>
          <div class="row">
            <button id="btn-back" onclick="cmd('back',{})">‹</button>
            <button id="btn-fwd" onclick="cmd('forward',{})">›</button>
            <button onclick="cmd('reload',{})">⟳</button>
            <input id="url-input" class="grow" placeholder="URL or search…">
            <button class="primary" onclick="goAddress()">Go</button>
          </div>
          <div id="page-meta" class="meta">No page loaded.</div>
          <div class="row">
            <button id="btn-shot" onclick="takeScreenshot()">📸 Capture screenshot</button>
            <button onclick="scrollDir(-700)">▲</button>
            <button onclick="scrollDir(700)">▼</button>
          </div>
          <div id="shot-wrap" class="hidden"><img id="shot-img" alt="screenshot"></div>
          <div id="page-view" class="card">Page context appears here.</div>
        </section>

        <section id="pane-tabs" class="pane">
          <h1>Tabs</h1>
          <div class="row"><button class="primary" onclick="cmd('openTab',{url:''})">＋ New tab</button></div>
          <div id="tab-list" class="list">—</div>
        </section>

        <section id="pane-agent" class="pane">
          <h1>Navi AI</h1>
          <div id="agent-card" class="card">No active agent.</div>
          <button class="primary" id="btn-stop-auto" onclick="cmd('agent.stop',{})">◼ Stop agent</button>
          <h2>Current task</h2>
          <div id="agent-task" class="card">—</div>
        </section>

        <section id="pane-activity" class="pane">
          <h1>Activity</h1>
          <button onclick="cmd('state',{})">Refresh state</button>
          <div id="activity-list" class="list">—</div>
        </section>

        <section id="pane-settings" class="pane">
          <h1>Settings <span class="tag">observe · control per Navi permissions</span></h1>
          <div id="settings-body" class="list">—</div>
        </section>
      </main>

      <div id="pair-overlay" class="overlay hidden">
        <div class="pair-card">
          <h2>Pair with Navi</h2>
          <p>On your iPhone open <b>Settings → LAN Control</b> and read the 6-digit PIN.</p>
          <input id="pin-input" inputmode="numeric" maxlength="12" placeholder="PIN code">
          <input id="device-name" placeholder="This device name" value="My device">
          <button class="primary" onclick="pairNow()">Pair</button>
          <p id="pair-error" class="err"></p>
        </div>
      </div>

      <script src="/app.js"></script>
    </body>
    </html>
    """
}

extension LANWebUI {
    static let css = """
    :root{
      --bg:#0b0e14; --panel:#12161f; --panel2:#0f131b; --line:#1f2733;
      --text:#e6edf3; --muted:#8b98a5; --accent:#5b8cff; --accent2:#7aa2ff;
      --green:#3fb950; --red:#f85149; --amber:#d29922;
    }
    *{box-sizing:border-box; margin:0; padding:0;}
    html,body{height:100%;}
    body{
      background:var(--bg); color:var(--text);
      font:14px/1.5 -apple-system, "Segoe UI", Roboto, sans-serif;
      display:grid; grid-template-columns:210px 1fr; grid-template-rows:auto 1fr;
      grid-template-areas:"conn conn" "side main";
      min-height:100%;
    }
    .conn{grid-area:conn; display:flex; align-items:center; gap:8px; padding:6px 14px; font-size:12.5px; background:var(--panel2); border-bottom:1px solid var(--line); color:var(--muted);}
    .conn .dot{width:9px;height:9px;border-radius:50%;background:var(--muted);}
    .conn.on .dot{background:var(--green); box-shadow:0 0 8px var(--green);}
    .conn.off .dot{background:var(--red);}
    .conn.sync .dot{background:var(--amber); animation:pulse 1s infinite;}
    @keyframes pulse{50%{opacity:.35;}}
    #sidebar{grid-area:side; background:var(--panel); border-right:1px solid var(--line); display:flex; flex-direction:column;}
    .brand{padding:16px 16px 10px; font-size:19px; font-weight:700; letter-spacing:.3px;}
    .brand .logo{color:var(--accent); margin-right:4px;}
    .brand span{color:var(--accent2);}
    nav{display:flex; flex-direction:column; gap:2px; padding:8px;}
    nav a{display:flex; align-items:center; gap:10px; color:var(--muted); text-decoration:none; padding:9px 12px; border-radius:9px; cursor:pointer;}
    nav a:hover{background:var(--panel2); color:var(--text);}
    nav a.active{background:#1b2330; color:var(--text);}
    .side-foot{padding:14px; font-size:11.5px; color:var(--muted); margin-top:auto;}
    #main{grid-area:main; overflow:auto; padding:20px 26px 60px;}
    h1{font-size:22px; margin-bottom:4px;}
    h2{font-size:16px; margin:18px 0 8px; color:var(--muted);}
    .sub{color:var(--muted); margin-bottom:16px;}
    .pane{display:none;}
    .pane.active{display:block;}
    .card{background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:14px; margin-top:12px; max-width:860px; white-space:pre-wrap; word-break:break-word; overflow:auto; max-height:46vh;}
    .meta{color:var(--muted); font-size:12.5px; margin:10px 0 4px;}
    .card-grid{display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:10px; max-width:860px;}
    .quick,.primary,button{background:var(--panel); color:var(--text); border:1px solid var(--line); border-radius:10px; padding:9px 12px; cursor:pointer; font-size:13px;}
    button:hover{background:#1c2431;}
    .primary{background:var(--accent); border-color:var(--accent); color:#fff;}
    .row{display:flex; gap:8px; align-items:center; margin-top:10px; max-width:860px; flex-wrap:wrap;}
    input,textarea,select{background:var(--panel2); border:1px solid var(--line); color:var(--text); border-radius:10px; padding:9px 11px; font-size:13.5px;}
    .grow{flex:1; min-width:180px;}
    textarea{width:100%; resize:vertical; margin-top:8px;}
    .list{display:flex; flex-direction:column; gap:8px; max-width:860px; margin-top:12px;}
    .item{background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:10px 12px;}
    .item.active{border-color:var(--accent);}
    .item .t{font-weight:600; display:block;}
    .item .u{color:var(--muted); font-size:11.5px; word-break:break-all;}
    .tag{font-size:10.5px; color:var(--muted); border:1px solid var(--line); padding:2px 7px; border-radius:20px; vertical-align:middle;}
    .err{color:var(--red); font-size:12px; min-height:16px; margin-top:6px;}
    .hidden{display:none;}
    .overlay{position:fixed; inset:0; background:rgba(4,6,10,.8); display:grid; place-items:center; z-index:50; backdrop-filter:blur(4px);}
    .pair-card{background:var(--panel); border:1px solid var(--line); border-radius:16px; padding:28px; width:min(92vw,380px);}
    .pair-card input{width:100%; margin-top:10px;}
    .pair-card .primary{width:100%; margin-top:12px;}
    .feedline{display:flex; gap:8px; align-items:baseline;}
    .feedline .time{color:var(--muted); font-size:11px; min-width:60px;}
    #shot-img{max-width:100%; border-radius:10px; border:1px solid var(--line);}
    @media (max-width:700px){
      body{grid-template-columns:1fr; grid-template-areas:"conn" "main";}
      #sidebar{display:none;}
    }
    """
}

extension LANWebUI {
    static let js = """
    /* NaviAI remote client.
       Connection state machine:
       Disconnected -> Reconnecting... -> Connected (Synchronizing...) -> State restored */
    const LS_TOKEN = 'navi.lan.token';
    const token = localStorage.getItem(LS_TOKEN);
    let ws = null;
    let state = null;
    let reconnectAttempt = 0;
    let heartbeat = null;

    const $ = id => document.getElementById(id);
    const WS_URL = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws?token=';

    function setConn(kind, text) {
      const bar = $('connbar');
      bar.className = 'conn ' + kind;
      $('conn-text').textContent = text;
    }

    function connect() {
      const tok = localStorage.getItem(LS_TOKEN);
      if (!tok) { showPair(); return; }
      if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
      setConn('off', 'Reconnecting…');
      try {
        ws = new WebSocket(WS_URL + encodeURIComponent(tok));
      } catch (e) { scheduleReconnect(); return; }

      ws.onopen = () => {
        reconnectAttempt = 0;
        heartbeat = setInterval(sendPing, 15000);
        setConn('sync', 'Connected · Synchronizing…');
      };
      ws.onmessage = ev => { handleMessage(ev.data); };
      ws.onclose = () => {
        clearInterval(heartbeat);
        setConn('off', 'Disconnected');
        scheduleReconnect();
      };
      ws.onerror = () => { /* onclose follows */ };
    }

    function scheduleReconnect() {
      // Exponential backoff with jitter, capped at 30s.
      const delay = Math.min(1000 * Math.pow(2, reconnectAttempt), 30000) + Math.random() * 500;
      reconnectAttempt++;
      setConn('off', 'Reconnecting in ' + Math.round(delay / 1000) + 's…');
      setTimeout(connect, delay);
    }

    function sendPing() { sendRaw({ t: 'ping', d: {} }); }

    function sendRaw(obj) {
      if (ws && ws.readyState === 1) {
        ws.send(JSON.stringify({ p: 2, t: obj.t, d: obj.d || {} }));
      }
    }

    function cmd(command, args) {
      sendRaw({ t: 'command', d: { command: command, args: args || {} } });
    }

    function handleMessage(raw) {
      let msg;
      try { msg = JSON.parse(raw); } catch (e) { return; }
      if (!msg || msg.t === 'pong') return;
      if (msg.t === 'state.restore' || msg.t === 'state') {
        let s = msg.d && msg.d.state;
        if (typeof s === 'string') { try { s = JSON.parse(s); } catch (e) { return; } }
        if (!s) return;
        state = s;
        applyState();
        setConn('on', 'Connected · State restored');
        return;
      }
      if (msg.t === 'command.result') {
        if (msg.d && msg.d.message) setConn('on', 'Connected · ' + msg.d.message);
        return;
      }
      if (msg.t === 'error') {
        const e = (msg.d && msg.d.error) || 'Remote error';
        setConn('off', 'Error: ' + e);
        if (/reauth|Unauthorized/.test(e)) { localStorage.removeItem(LS_TOKEN); showPair(); }
      }
    }

    function showPair() {
      $('pair-overlay').classList.remove('hidden');
      setConn('off', 'Disconnected — pair with Navi first');
    }

    async function pairNow() {
      const pin = $('pin-input').value.trim();
      const name = $('device-name').value.trim() || 'My device';
      if (pin.length < 4) { $('pair-error').textContent = 'Enter the 6-digit PIN from your iPhone.'; return; }
      $('pair-error').textContent = '';
      try {
        const res = await fetch('/api/pair', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ pin: pin, deviceName: name })
        });
        const body = await res.json();
        if (!res.ok || !body.token) {
          $('pair-error').textContent = body.error || 'Pairing failed.';
          return;
        }
        localStorage.setItem(LS_TOKEN, body.token);
        $('pair-overlay').classList.add('hidden');
        reconnectAttempt = 0;
        connect();
      } catch (e) {
        $('pair-error').textContent = 'Could not reach Navi. Same Wi-Fi network?';
      }
    }

    function shortHost(u) {
      try { return new URL(u).host; } catch (e) { return u; }
    }

    function applyState() {
      const s = state || {};
      const meta = s.meta || {};
      const b = s.browser || {};
      const p = s.page || {};
      const a = s.agent || {};
      const act = s.activity || {};

      // Connection / foot
      const footParts = [];
      if (meta.deviceName) footParts.push(meta.deviceName);
      footParts.push(meta.clients + ' client' + (meta.clients === 1 ? '' : 's'));
      if (b.title || b.url) footParts.push(shortHost(b.url) || '');
      $('side-foot').textContent = footParts.filter(Boolean).join(' · ');

      // Browser
      const pageTitle = b.title || (p.title || 'No page');
      $('page-meta').textContent = (b.isLoading ? '⏳ ' : '') + (p.readyState && p.readyState !== 'complete' ? 'loading… ' : '') + pageTitle + '\n' + (b.url || 'about:blank');
      if ($('url-input').value !== b.url && document.activeElement !== $('url-input')) {
        $('url-input').value = b.url || '';
      }
      $('btn-back').disabled = !b.canGoBack;
      $('btn-fwd').disabled = !b.canGoForward;

      // Page context card
      let pageText = '';
      if (p.title) pageText += p.title + '\n';
      if (p.readyState) pageText += 'State: ' + p.readyState + ' · ScrollY: ' + Math.round(p.scrollY || 0) + 'px · Viewport: ' + Math.round(p.viewportWidth || 0) + 'x' + Math.round(p.viewportHeight || 0) + '\n';
      if (p.visibleText) pageText += '\n' + p.visibleText.slice(0, 3000);
      if (p.headings && p.headings.length) pageText += '\n\nHeadings: ' + p.headings.join(' | ');
      if (p.buttons && p.buttons.length) pageText += '\n\nButtons: ' + p.buttons.slice(0, 20).join(', ');
      if (p.inputCount !== undefined) pageText += '\n\nInputs: ' + p.inputCount + ' · Forms: ' + (p.formCount || 0);
      $('page-view').textContent = pageText || 'No readable page context yet.';

      // Tabs
      const tabs = b.tabs || [];
      if (tabs.length) {
        $('tab-list').innerHTML = tabs.map(t => {
          const cls = (t.active ? ' active' : '');
          return '<div class="item' + cls + '"><span class="t">' + esc(t.title) + (t.private ? ' 🔒' : '') + '</span><span class="u">' + esc(t.url || '') + '</span>'
            + '<div class="row" style="margin-top:6px"><button onclick="cmd(\'switchTab\',{index:' + t.index + '})">Open</button>'
            + '<button onclick="cmd(\'closeTab\',{index:' + t.index + '})">Close</button></div></div>';
        }).join('');
      } else {
        $('tab-list').textContent = '—';
      }

      // Agent / task
      const cur = act.current || {};
      const name = (cur.title || a.goal || 'No task');
      const running = cur.isRunning || a.isRunning;
      let card = (running ? '● Navi AI Running' : '○ Navi AI Idle') + '\n';
      card += 'Status: ' + (a.status || '—') + '\n';
      card += 'Task: ' + name + '\n';
      card += 'Current: ' + (cur.currentStep || a.status || '…') + '\n';
      const progress = Math.max(0, Math.min(100, cur.progress || 0));
      card += 'Progress: ' + '█'.repeat(Math.round(progress / 10)) + '░'.repeat(10 - Math.round(progress / 10)) + ' ' + progress + '%';
      $('agent-card').textContent = card;
      let task = 'Goal: ' + (a.task ? a.task.goal : '—') + '\n';
      if (a.task) {
        task += 'Status: ' + a.task.status + ' · Steps: ' + a.task.stepCount + '\n';
        task += 'Current step: ' + (a.task.currentStep || '—') + '\n';
        if (a.task.continuation) task += 'Continuation: ' + a.task.continuation + '\n';
        if (a.task.stopReason) task += 'Stop reason: ' + a.task.stopReason;
      }
      $('agent-task').textContent = task;
      $('chat-last').textContent = 'Status: ' + (a.status || 'idle') + (running ? ' (running)' : '');

      // Activity feed
      const feed = act.feed || [];
      if (feed.length) {
        $('activity-list').innerHTML = feed.slice().reverse().map(it => {
          const d = new Date((it.date || 0) * 1000).toLocaleTimeString();
          return '<div class="item feedline"><span class="time">' + d + '</span><span>' + esc(it.message) + '</span></div>';
        }).join('');
      } else {
        $('activity-list').textContent = '—';
      }

      // Home
      $('home-sub').textContent = 'Browsing ' + shortHost(b.url || '…') + ' on ' + (meta.deviceName || 'iPhone');
      $('home-state').textContent = 'Title: ' + pageTitle + '\nURL: ' + (b.url || '—') + '\nAgent: ' + (running ? '● Running — ' + name : '○ idle');

      // Settings
      const rows = [];
      rows.push(['Navi device', meta.deviceName || '—']);
      rows.push(['App version', meta.appVersion || '—']);
      rows.push(['Remote observe enabled', meta.allowObserve ? 'Yes' : 'No']);
      rows.push(['Remote control enabled', meta.allowControl ? 'Yes' : 'No']);
      rows.push(['Connected clients', String(meta.clients || 0)]);
      rows.push(['Server uptime', Math.floor((meta.uptime || 0) / 60) + 'm']);
      rows.push(['Profile', (meta.profile && meta.profile.displayName) || '—']);
      $('settings-body').innerHTML = rows.map(r => '<div class="item"><span class="t">' + esc(r[0]) + '</span><span class="u">' + esc(r[1]) + '</span></div>').join('');
    }

    function esc(v) {
      return String(v == null ? '' : v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    // ---- Actions ----
    function openYoutube()   { cmd('navigate', { url: 'https://www.youtube.com' }); }
    function openFacebook()  { cmd('navigate', { url: 'https://www.facebook.com' }); }
    function openTiktok()    { cmd('navigate', { url: 'https://www.tiktok.com' }); }
    function openNews()      { cmd('search', { query: 'breaking news today' }); }
    function openSearch()    { cmd('navigate', { url: 'https://duckduckgo.com' }); }
    function goAddress()     { cmd('navigate', { url: $('url-input').value.trim() || 'https://duckduckgo.com' }); }
    function scrollDir(dy)   { cmd('scroll', { dy: dy }); }
    function startTaskFromChat() {
      const goal = $('chat-input').value.trim();
      if (!goal) return;
      cmd('agent.start', { goal: goal, continuation: $('chat-cont').value.trim() });
      $('chat-input').value = '';
    }

    async function takeScreenshot() {
      const tok = localStorage.getItem(LS_TOKEN);
      const img = $('shot-img');
      $('shot-wrap').classList.remove('hidden');
      try {
        const res = await fetch('/api/screenshot?token=' + encodeURIComponent(tok || ''));
        if (!res.ok) { img.alt = 'Screenshot failed (' + res.status + ')'; return; }
        const blob = await res.blob();
        img.src = URL.createObjectURL(blob);
      } catch (e) {
        img.alt = 'Screenshot failed';
      }
    }

    // ---- Navigation ----
    document.querySelectorAll('nav a').forEach(a => {
      a.addEventListener('click', () => {
        document.querySelectorAll('nav a').forEach(x => x.classList.remove('active'));
        a.classList.add('active');
        document.querySelectorAll('.pane').forEach(p => p.classList.remove('active'));
        $('pane-' + a.dataset.pane).classList.add('active');
      });
    });
    $('url-input').addEventListener('keydown', e => { if (e.key === 'Enter') goAddress(); });

    if (!localStorage.getItem(LS_TOKEN)) showPair();
    connect();
    """
}
