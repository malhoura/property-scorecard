#!/usr/bin/env python3
"""Build the hosted (GitHub Pages) version of the web app from webapp/static/index.html.

The local app and the hosted app share one page. This script swaps the local /api/ calls
for Supabase calls, adds a sign-in screen, and writes docs/index.html (served by GitHub Pages).

    python3 site/build.py
"""
import pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT.parent / "webapp" / "static" / "index.html"
OUT = ROOT.parent / "docs" / "index.html"

# Public by design: the anon key only lets a browser call the API as a signed-out user.
# Signed-out users get nothing (no grants); signed-in users see data only if their email
# is in scorecard.app_users. Never put the service_role key or database password here.
SUPABASE_URL = "https://vudjbkcnzgjjcahrfmfe.supabase.co"
SUPABASE_ANON_KEY = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ1ZGpia2NuemdqamNh"
                     "aHJmbWZlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI4NTQ3MzQsImV4cCI6MjEwODQzMDczNH0."
                     "iv95RNvLk4ZLhZqyQ6pQabznhnKZ30cwlM_p4xzioLo")
SUPABASE_JS = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"

html = SRC.read_text()


def swap(old, new, count=1):
    global html
    n = html.count(old)
    if n != count:
        sys.exit(f"build.py: expected {count} match(es), found {n}, for:\n{old[:200]}")
    html = html.replace(old, new)


# ---- styles for the sign-in screen
swap("</style>", """
.login { max-width: 380px; margin: 8vh auto 0; display: grid; gap: 12px; }
.login h2 { font-family: var(--font-display); font-weight: 400; font-size: 26px; margin: 0; }
.login label { display: grid; gap: 4px; font-size: 12px; color: var(--muted); }
.login input { background: var(--bg); border: 1px solid var(--line); border-radius: 6px; padding: 8px 10px; font-size: 14px; }
.login .row { display: flex; gap: 8px; flex-wrap: wrap; }
.login button { border: 1px solid var(--accent); background: var(--accent); color: var(--panel); border-radius: 6px; padding: 8px 14px; cursor: pointer; font-weight: 600; }
.login button.ghost { background: transparent; color: var(--accent); }
.login button:disabled { opacity: .6; cursor: default; }
.login .msg { font-size: 13px; min-height: 1.2em; }
.login .msg.err { color: var(--bad); }
body.out .tabs, body.out .ctl, body.out #db, body.out #refresh, body.out #signout,
body.out #view-ranking, body.out #view-listings, body.out #banner { display: none !important; }
body:not(.out) #login { display: none; }
</style>""")

# ---- sign-out button in the top bar
swap('<button class="refresh" id="refresh" title="Reload from the database">Refresh</button>',
     '<button class="refresh" id="refresh" title="Reload from the database">Refresh</button>\n'
     '  <button class="refresh" id="signout" title="Sign out">Sign out</button>')

swap("<body>", '<body class="out">')

# ---- sign-in screen
swap('<div class="banner" id="banner" hidden></div>', '''<div class="banner" id="banner" hidden></div>

  <form class="card login" id="login" autocomplete="on">
    <h2>Sign in</h2>
    <p class="note" style="margin:0">Only approved email addresses can see the scorecard.</p>
    <label>Email <input type="email" id="li-email" autocomplete="username" required></label>
    <label>Password <input type="password" id="li-pass" autocomplete="current-password" minlength="8" required></label>
    <div class="row">
      <button type="submit" id="li-in">Sign in</button>
      <button type="button" class="ghost" id="li-up">Create account</button>
    </div>
    <div class="msg" id="li-msg" role="status"></div>
  </form>''')

# ---- Supabase client library, loaded before the app script
swap("<script>", f'<script src="{SUPABASE_JS}"></script>\n<script>')

# ---- API calls go to Supabase functions instead of the local server
swap("""  async function api(path) {
    const r = await fetch('/api/' + path, { cache: 'no-store' });
    let body = null; try { body = await r.json(); } catch {}
    if (!r.ok) throw new Error((body && body.error) || `Request failed (${r.status})`);
    return body;
  }""", f"""  const sb = window.supabase.createClient('{SUPABASE_URL}', '{SUPABASE_ANON_KEY}');
  async function api(path) {{
    const [name, q = ''] = path.split('?');
    const p = new URLSearchParams(q);
    const calls = {{
      overview: ['app_overview', {{}}],
      ranking: ['app_ranking', {{ p_month: p.get('month'), p_lens: p.get('lens') }}],
      zip: ['app_zip', {{ p_zip: p.get('zip'), p_month: p.get('month'), p_lens: p.get('lens') }}],
      listings: ['app_listings', {{}}],
    }};
    const [fn, args] = calls[name];
    const {{ data, error }} = await sb.rpc(fn, args);
    if (error) throw new Error(error.message);
    if (name === 'overview' && !data.allowed) throw new Error(`Signed in as ${{data.db_user}}, but this email isn't on the access list yet. Ask the owner to add it.`);
    if (name === 'zip' && !data.evaluation) throw new Error('No evaluation for this ZIP, month and lens.');
    return data;
  }}""")

# ---- error banner wording (no local Postgres to check)
swap("""      el('span', { text: 'Check that Postgres is running (' }), el('code', { text: 'brew services list' }),
      el('span', { text: '), then press Refresh. The terminal running the app shows more detail.' }));""",
     """      el('span', { text: 'Press Refresh to try again.' }));""")

# ---- start: wait for a session before loading data
swap("""  setTab(location.hash.startsWith('#listings') ? 'listings' : 'ranking');
  boot();
})();""", """  setTab(location.hash.startsWith('#listings') ? 'listings' : 'ranking');

  // ---------- sign-in
  const msg = (t, err) => { const m = $('#li-msg'); m.textContent = t || ''; m.className = 'msg' + (err ? ' err' : ''); };
  const busy = (on) => { $('#li-in').disabled = on; $('#li-up').disabled = on; };
  $('#login').onsubmit = async (e) => {
    e.preventDefault(); busy(true); msg('Signing in…');
    const { error } = await sb.auth.signInWithPassword({ email: $('#li-email').value.trim(), password: $('#li-pass').value });
    busy(false); msg(error ? error.message : '', !!error);
  };
  $('#li-up').onclick = async () => {
    if (!$('#login').reportValidity()) return;
    busy(true); msg('Creating account…');
    const { data, error } = await sb.auth.signUp({ email: $('#li-email').value.trim(), password: $('#li-pass').value,
      options: { emailRedirectTo: location.origin + location.pathname } });
    busy(false);
    if (error) msg(error.message, true);
    else if (!data.session) msg('Check your email for a confirmation link, then come back and sign in.');
  };
  $('#signout').onclick = () => sb.auth.signOut();
  let who = null;
  sb.auth.onAuthStateChange((event, session) => {
    const id = session ? session.user.id : null;
    if (id === who) return;            // token refreshes don't reload the page
    who = id;
    document.body.classList.toggle('out', !session);
    $('#dbname').textContent = session ? session.user.email : '';
    if (session) { msg(''); setTimeout(boot, 0); }
    else { S.overview = S.ranking = S.detail = S.listings = null; }
  });
})();""")

OUT.write_text(html)
print(f"wrote {OUT} ({len(html):,} bytes)")
