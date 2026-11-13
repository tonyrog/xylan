#!/usr/bin/env python3
# Generates doc/xylan.html (sequence diagram + deployment + reference)
import sys, html

OUT = sys.argv[1]

C = dict(user="#f5a623", server="#3ac43a", session="#3ac43a", proxys="#3ac43a",
         client="#36c9ef", proxyc="#36c9ef", gw="#9b6bff", service="#f0452a")
LANES = [("user", "USER", 40), ("server", "SERVER", 135), ("session", "SESSION", 222),
         ("proxys", "PROXY", 300), ("client", "CLIENT", 408), ("proxyc", "PROXY", 486),
         ("gw", "GATEWAY", 590), ("service", "SERVICE", 705)]
X = {k: x for k, _, x in LANES}
W = 745
TOP = 70
ROW = 23

svg = []
y = TOP + 34
created = {"proxys": None, "proxyc": None}

def esc(s): return html.escape(s, quote=False)

def lock(x, y, color="#222"):
    return (f'<g transform="translate({x-4},{y-11})"><path d="M1.5 5 V3.2 a2.5 2.5 0 0 1 5 0 V5" '
            f'fill="none" stroke="{color}" stroke-width="1.1"/>'
            f'<rect x="0" y="5" width="8" height="6" rx="1" fill="{color}"/></g>')

def arrow(a, b, label, kind="msg", color="#111", tls=False, lab_pos=0.5, sub=None):
    global y
    x1, x2 = X[a], X[b]
    d = 1 if x2 > x1 else -1
    xe = x2 - d * 2
    if kind == "dbl":   # control channel (double line like the original)
        svg.append(f'<line x1="{x1}" y1="{y-1.5}" x2="{xe-d*6}" y2="{y-1.5}" stroke="{color}" stroke-width="1.1"/>')
        svg.append(f'<line x1="{x1}" y1="{y+1.5}" x2="{xe-d*6}" y2="{y+1.5}" stroke="{color}" stroke-width="1.1"/>')
    elif kind == "dash":
        svg.append(f'<line x1="{x1}" y1="{y}" x2="{xe-d*6}" y2="{y}" stroke="{color}" stroke-width="1.1" stroke-dasharray="4 3"/>')
    elif kind == "data":
        svg.append(f'<line x1="{x1}" y1="{y-1.5}" x2="{xe-d*6}" y2="{y-1.5}" stroke="{color}" stroke-width="1.3"/>')
        svg.append(f'<line x1="{x1}" y1="{y+1.5}" x2="{xe-d*6}" y2="{y+1.5}" stroke="{color}" stroke-width="1.3"/>')
    else:
        svg.append(f'<line x1="{x1}" y1="{y}" x2="{xe-d*6}" y2="{y}" stroke="{color}" stroke-width="1.2"/>')
    svg.append(f'<path d="M{xe} {y} l{-d*8} -4 v8 z" fill="{color}"/>')
    lx = x1 + (x2 - x1) * lab_pos
    txt = esc(label)
    svg.append(f'<text x="{lx}" y="{y-5}" text-anchor="middle" class="lbl">{txt}</text>')
    if tls:
        tw = len(label) * 2.9
        svg.append(lock(lx - tw - 9, y - 1, "#1a7f1a"))
    if sub:
        svg.append(f'<text x="{lx}" y="{y+11}" text-anchor="middle" class="sub">{esc(sub)}</text>')
        y += 8
    y += ROW

def note(lane, text, dx=6, anchor="start", color="#555"):
    global y
    x = X[lane] + dx
    svg.append(f'<text x="{x}" y="{y-8}" text-anchor="{anchor}" class="note" fill="{color}">{esc(text)}</text>')
    y += 13

def section(title):
    global y
    y += 4
    svg.append(f'<rect x="4" y="{y-13}" width="{W-8}" height="17" fill="#f3f3f3" rx="3"/>')
    svg.append(f'<text x="10" y="{y}" class="sec">{esc(title)}</text>')
    y += 22

def create(lane, color):
    global y
    x = X[lane]
    created[lane] = y
    svg.append(f'<rect x="{x-30}" y="{y-14}" width="60" height="17" rx="8" fill="{color}" stroke="#333" stroke-width="0.7"/>')
    svg.append(f'<text x="{x}" y="{y-2}" text-anchor="middle" class="box">PROXY</text>')
    y += 16

# ----------------------------------------------------------------- sequence
section("1  Control channel   CLIENT ⇒ SERVER   (TLS, pinned certificates, HMAC-SHA256 and/or client certificate)")
arrow("client", "server", "connect client_tls_port 29392 + TLS handshake", "dash", tls=True, lab_pos=0.42)
note("client", "server certificate checked against pinned sha256 fingerprint", dx=-6, anchor="end")
note("server", "optional client certificate (home.pem) presented in the same handshake", dx=6)
arrow("client", "server", "auth_req {id, chal, alg=hmac_sha256 | cert}", "dbl", tls=True, lab_pos=0.42)
arrow("server", "session", "auth_socket", "msg")
note("server", "old port with require_tls, or client_cert fingerprint ≠ id → closed before handover", dx=-90)
arrow("session", "client", "auth_res {chal', HMAC(Ks, \"xylan-server-v1:\"‖chal)}", "dbl", tls=True, lab_pos=0.5)
arrow("client", "session", "auth_ack {HMAC(Kc, \"xylan-client-v1:\"‖chal')}", "dbl", tls=True, lab_pos=0.5)
note("session", "alg=cert: creds empty, identity = client certificate (no shared keys needed)")
note("session", "new socket replaces the active one only after successful auth (no kick-out by id)")

section("2  User connects   USER → SERVER user port (e.g. 11443)")
arrow("user", "server", "connect A", "dash")
create("proxys", C["proxys"])
arrow("server", "proxys", "start(Sk), set A", "msg", lab_pos=0.3)
arrow("user", "proxys", "TLS ClientHello (initial data)", "data", color=C["user"], lab_pos=0.25)
arrow("proxys", "server", "route Ri", "msg", lab_pos=0.25)
arrow("server", "session", "route {29391,29393}, Sk, Ri", "msg", lab_pos=0.5)
arrow("session", "server", "session_bound(Sk, tls=true)", "msg", lab_pos=0.5)
arrow("session", "client", "route {29393, Sk, Ri}", "dbl", tls=True, lab_pos=0.6)
create("proxyc", C["proxyc"])
arrow("client", "proxyc", "start(Sk)", "msg", lab_pos=0.5)
arrow("proxyc", "gw", "connect A  127.0.0.1:11443", "dash", lab_pos=0.5)
arrow("proxyc", "server", "connect B  data_tls_port 29393 + TLS, send Sk", "dash", tls=True, lab_pos=0.5)
note("server", "Sk must be routed AND bound to the same channel type (tls) and client certificate – else closed", dx=6)
arrow("server", "proxys", "set B", "msg", lab_pos=0.5)

section("3  Request   USER ⇄ GATEWAY end-to-end TLS through the tunnel")
arrow("proxys", "proxyc", "ClientHello*", "data", color=C["user"], tls=True, lab_pos=0.5)
arrow("proxyc", "gw", "ClientHello", "data", color=C["user"], lab_pos=0.5)
arrow("gw", "user", "TLS handshake (gw.pem) – server/tunnel only see ciphertext", "dash", color=C["gw"], lab_pos=0.5)
arrow("user", "gw", "POST /v1/chat/completions   Authorization: Bearer sk-xyl-…", "data", color=C["user"], lab_pos=0.5)
note("gw", "verify key: format+crc, sha256, disabled, expires, allow", dx=-6, anchor="end")
arrow("gw", "service", "forward, key removed", "msg", lab_pos=0.5, sub="Host rewritten · Connection: close")
arrow("service", "gw", "RESP (stream)", "data", color=C["service"], lab_pos=0.5)
arrow("gw", "user", "RESP", "data", color=C["service"], lab_pos=0.5)
note("gw", "missing / bad key → 401 JSON (OpenAI or Anthropic error style)", dx=-6, anchor="end")

section("4  Keep alive")
arrow("client", "session", "ping", "dbl", tls=True)
arrow("session", "client", "pong", "dbl", tls=True)

H = y + 10
# lifelines + heads
heads = []
for k, name, x in LANES:
    y0 = TOP + 9
    if k in created and created[k]:
        y0 = created[k] + 3
    dash = ' stroke-dasharray="1 0"'
    heads.append(f'<line x1="{x}" y1="{y0}" x2="{x}" y2="{H}" stroke="#999" stroke-width="1"/>')
    if k not in created:
        heads.append(f'<rect x="{x-37}" y="{TOP-9}" width="74" height="18" fill="{C[k]}" stroke="#333" stroke-width="0.7"/>')
        heads.append(f'<text x="{x}" y="{TOP+4}" text-anchor="middle" class="box">{name}</text>')

legend = f'''
<g transform="translate(8,{TOP-48})" class="leg">
 <line x1="0" y1="0" x2="26" y2="0" stroke="#111" stroke-dasharray="4 3"/><text x="31" y="3">connect</text>
 <line x1="80" y1="-1.5" x2="106" y2="-1.5" stroke="#111"/><line x1="80" y1="1.5" x2="106" y2="1.5" stroke="#111"/><text x="111" y="3">control channel</text>
 <line x1="200" y1="-1.5" x2="226" y2="-1.5" stroke="{C['user']}" stroke-width="1.3"/><line x1="200" y1="1.5" x2="226" y2="1.5" stroke="{C['user']}" stroke-width="1.3"/><text x="231" y="3">user data (end-to-end TLS to GATEWAY)</text>
 {lock(420, 4, "#1a7f1a")}<text x="426" y="3">inside xylan TLS (tunnel)</text>
 <text x="560" y="3">Sk session key · Ri route info</text>
</g>'''

seq_svg = f'<svg viewBox="0 0 {W} {H}" width="100%">{legend}{"".join(heads)}{"".join(svg)}</svg>'

# ----------------------------------------------------------------- deployment
def box(x, y, w, h, title, color, lines, tcolor="#000"):
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="#fff" stroke="{color}" stroke-width="2"/>',
           f'<rect x="{x}" y="{y}" width="{w}" height="20" rx="6" fill="{color}"/>',
           f'<rect x="{x}" y="{y+12}" width="{w}" height="8" fill="{color}"/>',
           f'<text x="{x+8}" y="{y+14}" class="box">{esc(title)}</text>']
    yy = y + 36
    for ln in lines:
        cls = "mono" if ln.startswith(" ") or ln.startswith("/") or ln.startswith(":") else "dtxt"
        out.append(f'<text x="{x+10}" y="{yy}" class="{cls}">{esc(ln.strip() if cls=="dtxt" else ln)}</text>')
        yy += 14
    return "".join(out)

dep = []
dep.append(box(10, 20, 150, 150, "USER", C["user"], [
    "curl / OpenAI SDK", "holds:", "  sk-xyl-… api key", "  gw.pem (if self-signed)",
    "connects to", "  xylan3.example:11443"]))
dep.append(box(205, 20, 230, 230, "SERVER node (public)", C["server"], [
    "xylan mode=server", ":11443  user port (gateway route)", ":22xx   user ports (ssh …)",
    ":29392  client_tls_port", ":29393  data_tls_port", ":29390/1 old ports → none",
    "/etc/xylan/", "  xylan.config      0600", "  server.pem", "  server.key        0600",
    "  (client cert: fingerprint only)",
    "sees: ssh + TLS ciphertext only"]))
dep.append(box(480, 20, 255, 300, "HOME node (client + service)", C["client"], [
    "xylan mode=client", "route {data,ssl} → 127.0.0.1:11443", "", "api gateway (xylan_gw)",
    ":11443  TLS + api key check", "  → ollama 127.0.0.1:11434", "",
    "/etc/xylan/", "  xylan.config      0600", "  gw.pem", "  gw.key            0600",
    "  home.pem", "  home.key          0600 (client cert)",
    "  api_keys.conf     0600 (hashes)", "", "ollama  127.0.0.1:11434", "  (never exposed)"]))
# arrows
dep.append(f'<path d="M160 90 H205" stroke="{C["user"]}" stroke-width="2.5" fill="none" marker-end="url(#ah)"/>')
dep.append(f'<text x="182" y="84" text-anchor="middle" class="sub">TLS</text>')
dep.append(f'<path d="M480 120 H435" stroke="{C["client"]}" stroke-width="2.5" fill="none" marker-end="url(#ah)"/>')
dep.append(f'<text x="457" y="114" text-anchor="middle" class="sub">TLS</text>')
dep.append(f'<text x="457" y="134" text-anchor="middle" class="sub">outbound</text>')
dep.append(f'<text x="330" y="290" text-anchor="middle" class="note">client connects OUT to the server – no inbound ports at home</text>')
dep_svg = f'''<svg viewBox="0 0 745 345" width="100%"><defs><marker id="ah" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto"><path d="M0 0 L8 4 L0 8 z" fill="#333"/></marker></defs>{"".join(dep)}</svg>'''

page_css = """
@page { size: A4; margin: 12mm 11mm; }
body { font-family: Helvetica, Arial, sans-serif; color: #111; margin: 0; }
h1 { font-weight: 300; font-size: 30px; text-align: center; margin: 0 0 2px 0; }
h1 small { font-size: 14px; color: #777; }
h2 { font-size: 16px; margin: 10px 0 6px 0; border-bottom: 2px solid #3ac43a; padding-bottom: 2px; }
h3 { font-size: 12.5px; margin: 10px 0 3px 0; }
p, li, td { font-size: 10.5px; line-height: 1.38; }
ul { margin: 2px 0 4px 0; padding-left: 16px; }
.page { page-break-after: always; }
.page:last-child { page-break-after: auto; }
svg text.lbl { font-size: 8.6px; }
svg text.sub { font-size: 8px; fill: #444; }
svg text.note { font-size: 7.9px; font-style: italic; }
svg text.sec { font-size: 9.5px; font-weight: bold; }
svg text.box { font-size: 9.5px; font-weight: bold; }
svg text.dtxt { font-size: 9.5px; }
svg text.mono { font-size: 9px; font-family: Menlo, Consolas, monospace; }
svg .leg text { font-size: 8.4px; }
pre { font-family: Menlo, Consolas, monospace; font-size: 8.6px; background: #f6f6f6;
      border-left: 3px solid #36c9ef; padding: 5px 7px; margin: 3px 0 6px 0; line-height: 1.3;
      white-space: pre-wrap; }
table { border-collapse: collapse; width: 100%; margin: 3px 0 6px 0; }
td, th { border: 1px solid #ddd; padding: 3px 5px; vertical-align: top; text-align: left; }
th { font-size: 10px; background: #f3f3f3; }
code { font-family: Menlo, Consolas, monospace; font-size: 9.4px; background: #f3f3f3; padding: 0 2px; }
.cols { display: flex; gap: 12px; } .cols > div { flex: 1; min-width: 0; }
.key { font-family: Menlo, Consolas, monospace; font-size: 11px; text-align: center; margin: 4px 0; }
.key span { padding: 1px 3px; border-radius: 3px; }
"""

page1 = f'''<div class="page"><h1>xylan (proxy wedding) <small>2026 · tls · api keys</small></h1>{seq_svg}</div>'''

page2 = f'''<div class="page">
<h2>Deployment – where things live</h2>
{dep_svg}
<h3>Files</h3>
<table>
<tr><th>file</th><th>node</th><th>contains</th><th>create with</th><th>secret?</th></tr>
<tr><td><code>/etc/xylan/server.pem</code><br><code>/etc/xylan/server.key</code></td><td>server</td>
<td>tunnel certificate, presented to xylan clients on 29392/29393</td>
<td><code>xylan:generate_cert("server", [{{dir,"/etc/xylan"}}, {{hosts,["xylan3.example"]}}])</code> – prints the fingerprint</td>
<td>.key yes (0600)</td></tr>
<tr><td><code>/etc/xylan/gw.pem</code><br><code>/etc/xylan/gw.key</code></td><td>home</td>
<td>gateway certificate presented to users; hosts = the public name users connect to</td>
<td><code>xylan:generate_cert("gw", [{{dir,"/etc/xylan"}}, {{hosts,["xylan3.example"]}}])</code> or a Let's Encrypt certificate (DNS-01)</td>
<td>.key yes (0600)</td></tr>
<tr><td><code>/etc/xylan/home.pem</code><br><code>/etc/xylan/home.key</code></td><td>home</td>
<td>optional tunnel client certificate; the server stores only its fingerprint (<code>client_cert</code>)</td>
<td><code>xylan:generate_cert("home", [{{dir,"/etc/xylan"}}, {{usage,client}}])</code></td>
<td>.key yes (0600)</td></tr>
<tr><td><code>/etc/xylan/api_keys.conf</code></td><td>home</td>
<td>api key ids and <b>sha256 hashes</b> only, name, created, expires, allow, disabled</td>
<td><code>xylan:generate_api_key("tony-laptop")</code>, <code>xylan:revoke_api_key(Id)</code>, <code>xylan:list_api_keys()</code></td>
<td>no secrets, keep 0600</td></tr>
<tr><td><code>xylan.config</code> (server)</td><td>server</td><td>per client <code>server_key</code>/<code>client_key</code>, <code>require_tls</code>, routes, tls ports</td>
<td>keys: <code>xylan:generate_key(256)</code> – not needed for a client using only a client certificate</td><td>yes (0600)</td></tr>
<tr><td><code>xylan.config</code> (client)</td><td>home</td><td>same two keys, <code>server_tls</code> fingerprint, routes, <code>api_gateways</code>, <code>api_key_file</code></td>
<td></td><td>yes (0600)</td></tr>
</table>
<h3>What the user needs</h3>
<pre># the api key is shown ONCE by xylan:generate_api_key/1
curl --cacert gw.pem -H "Authorization: Bearer sk-xyl-…" https://xylan3.example:11443/api/tags

# OpenAI compatible SDKs (ollama /v1)
export OPENAI_BASE_URL=https://xylan3.example:11443/v1
export OPENAI_API_KEY=sk-xyl-…
export SSL_CERT_FILE=gw.pem          # only for a self-signed gw certificate</pre>
<h3>What each party can see</h3>
<ul>
<li><b>Network between client and server</b>: only TLS. Session keys, route info and auth are inside the tunnel.</li>
<li><b>xylan server</b>: ssh and the user's TLS stream as ciphertext – never api keys or prompts.</li>
<li><b>Gateway (home)</b>: plaintext HTTP, checks the key, removes it, forwards to ollama on localhost.</li>
<li><b>Ollama</b>: only reachable on 127.0.0.1, sees requests without api keys.</li>
</ul>
</div>'''

page3 = '''<div class="page">
<h2>Configuration reference</h2>
<div class="cols"><div>
<h3>Server (public node)</h3>
<pre>{xylan,
 [{mode, server},
  {id, "xylan3"},
  {port, [{ssh, "0.0.0.0", 46122},
          {ollama, "0.0.0.0", 11443}]},
  {client_port, 29390},      %% old, → none
  {data_port,   29391},      %% old, → none
  {client_tls_port, 29392},
  {data_tls_port,   29393},
  {tls_options,
   [{certfile, "/etc/xylan/server.pem"},
    {keyfile,  "/etc/xylan/server.key"}]},
  {max_tls_handshakes, 64},
  {max_tls_handshakes_per_ip, 8},
  {clients,
   [{"home",
     [{client_cert, "sha256:9A:3F:…"},
      %% and/or shared keys (both = cert+hmac)
      %% {server_key, 16#…256 bit…},
      %% {client_key, 16#…256 bit…},
      {require_tls, true},  %% implied by client_cert
      {route, [[{data, "SSH-2.0.*"}],
               [{dst_port, 11443}]]}]}]}]}</pre>
</div><div>
<h3>Client (home node)</h3>
<pre>{xylan,
 [{mode, client},
  {id, "home"},
  {server_ip, "xylan3.example"},
  {server_port, 29392},
  {server_tls,
   [{fingerprint, "sha256:21:09:88:…"},
    {certfile, "/etc/xylan/home.pem"},
    {keyfile,  "/etc/xylan/home.key"}]},
  %% {server_key, 16#…}, {client_key, 16#…},
  {route,
   [{ [{data, "SSH-2.0.*"}], [{port, 22}] },
    { [{data, ssl}],         [{port, 11443}] }]},

  {api_key_file, "/etc/xylan/api_keys.conf"},
  {api_gateways,
   [{ollama,
     [{port, 11443}, {ip, {127,0,0,1}},
      {target, {"127.0.0.1", 11434}},
      {tls, [{certfile, "/etc/xylan/gw.pem"},
             {keyfile,  "/etc/xylan/gw.key"}]},
      {host, rewrite},
      {max_connections, 64}]}]}]}</pre>
</div></div>

<h3>API key format</h3>
<div class="key"><span style="background:#eee">sk-xyl-</span><span style="background:#d9f5ff">LiOSGdJ4</span>-<span style="background:#ffe9c7">S3mDjsLEhKhsJyOgBozZs1dh7Qes4mm1uyLKrcvYXUs</span><span style="background:#e7dcff">0ivUUp</span></div>
<p style="text-align:center">prefix · <b>id</b> (8 base62, public, used in logs/revoke) · <b>secret</b> (43 base62 = 256 bit) · <b>crc32</b> (6 base62, catches typos).
Stored as <code>{"LiOSGdJ4", [{name,"ci"}, {hash,"sha256:…"}, {created,…}, {expires,{2027,6,30}}, {allow,[ollama]}]}</code>.
Accepted as <code>Authorization: Bearer …</code> or <code>x-api-key: …</code>.</p>

<div class="cols"><div>
<h3>Migration of existing nodes</h3>
<ol style="padding-left:16px">
<li>Server: <code>generate_cert("server", …)</code>, add tls ports + <code>tls_options</code>. Old ports keep working.</li>
<li>Per client: new keys <code>generate_key(256)</code> on both sides, <code>server_tls</code> with the fingerprint on the client, <code>{require_tls,true}</code> on the server.</li>
<li>Optional: <code>generate_cert("home", [{usage,client}])</code> on the client, add <code>certfile/keyfile</code> to <code>server_tls</code>, put the printed fingerprint as <code>client_cert</code> on the server, then remove the shared keys on both sides.</li>
<li>When all clients are upgraded: <code>{client_port,none}</code>, <code>{data_port,none}</code>.</li>
</ol>
</div><div>
<h3>Security properties</h3>
<ul>
<li>Session key bound to channel type; must be routed before use.</li>
<li>Auth: HMAC-SHA256 with role labels, constant time compare, and/or pinned client certificate – then the server holds no client secret.</li>
<li>Data connections must present the same client certificate as the control channel.</li>
<li>A connecting socket can not close an active session before it authenticates.</li>
<li>TLS handshakes in separate processes, capped total and per ip.</li>
<li>Gateway: one request per connection, key headers removed, obs-fold rejected.</li>
</ul>
</div></div>
</div>'''

open(OUT, "w").write(f'''<!doctype html><html><head><meta charset="utf-8"><title>xylan</title>
<style>{page_css}</style></head><body>{page1}{page2}{page3}</body></html>''')
