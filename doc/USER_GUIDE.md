# xylan user guide

xylan ("proxy wedding") lets users on the internet reach services on
machines that have no public address. A **client** (a home machine, a
Raspberry Pi, a laptop) connects *out* to a **server** with a public
address. Users connect to the server, the server routes each connection
to the right client, and the client connects it to the local service
(ssh, a web server, ollama, ...).

This guide covers setting up xylan with TLS: certificates, fingerprints,
client certificates, the API gateway and how to migrate a running
installation. For the sequence diagram see [xylan.pdf](xylan.pdf).

- [1. Overview](#1-overview)
- [2. Quick start: add TLS to a running server](#2-quick-start-add-tls-to-a-running-server)
- [3. Certificates](#3-certificates)
- [4. Fingerprint pinning](#4-fingerprint-pinning)
- [5. Client authentication: shared keys or client certificate](#5-client-authentication-shared-keys-or-client-certificate)
- [6. Rotating certificates](#6-rotating-certificates)
- [7. API gateway and API keys](#7-api-gateway-and-api-keys)
- [8. Turning off the old ports](#8-turning-off-the-old-ports)
- [9. Troubleshooting](#9-troubleshooting)
- [10. Reference](#10-reference)

---

## 1. Overview

```
   USER                       SERVER (public)                    CLIENT (home)          SERVICE
   ssh / curl  ──────────▶  user ports (22xx, 11443…)
                            client_tls_port 29392  ◀── control ── xylan client
                            data_tls_port   29393  ◀── data ───── (one per user connection)
                                                                       └──────────▶  sshd :22
                                                                                     gateway :11443 → ollama
```

- The client keeps a **control connection** to the server. When a user
  connects, the server tells the client over the control connection,
  and the client opens a **data connection** back to the server for that
  user. Nothing is ever opened *towards* the home machine.
- Since version 2.x both connections can use **TLS** on two new ports.
  The old plain ports (29390/29391) keep working until you turn them off,
  so nodes can be upgraded one at a time.

### What protects what

| Layer | Protects | Configured with |
|-------|----------|-----------------|
| Server certificate + fingerprint | The client only talks to *your* server. Session keys, routing and authentication are encrypted. | `tls_options` on the server, `server_tls` + `fingerprint` on the client |
| Client authentication | The server only accepts *your* clients. | Shared keys (`server_key`/`client_key`) and/or a client certificate (`client_cert`) |
| API gateway (optional) | Only users with an API key reach a web service. Users talk TLS end-to-end with the home machine. | `api_gateways`, `api_key_file` on the client |

### Files

Suggested layout. All private keys and configs should be readable only by
the user running xylan (`chmod 600`); xylan creates its own files that way.

| File | Node | What | Secret? |
|------|------|------|---------|
| `/etc/xylan/xylan.config` | both | configuration, may contain shared keys | yes |
| `/etc/xylan/server.pem` | server | tunnel certificate shown to clients | no |
| `/etc/xylan/server.key` | server | its private key | **yes** |
| `/etc/xylan/home.pem` | client | client certificate (optional) | no |
| `/etc/xylan/home.key` | client | its private key | **yes** |
| `/etc/xylan/gw.pem` | client | gateway certificate shown to users | no |
| `/etc/xylan/gw.key` | client | its private key | **yes** |
| `/etc/xylan/api_keys.conf` | client | API key ids and *hashes* | no secrets, still 0600 |

The rule of thumb: a `.pem` file (certificate) can be shown to anyone.
A `.key` file never leaves the machine it was created on.

---

## 2. Quick start: add TLS to a running server

You have a server running and one client (say, a laptop) with the new
version. The goal is to test TLS with the laptop while every other client
keeps running on the old ports.

### Step 1 – server: create the certificate

In an Erlang shell on the server (with xylan in the code path):

```erlang
1> xylan:generate_cert("server", [{dir, "/etc/xylan"},
                                  {hosts, ["xylan3.example.com"]}]).
certificate: /etc/xylan/server.pem
key:         /etc/xylan/server.key
fingerprint: sha256:21:09:88:61:B9:A4:A1:C1:BC:CE:53:F2:59:A3:17:6E:26:9E:B0:8B:D6:81:C9:C3:19:14:44:AC:77:CA:17:0F
```

Write down the fingerprint – the laptop needs it (see
[section 4](#4-fingerprint-pinning) for why). You can always print it again:

```erlang
2> xylan:cert_fingerprint("/etc/xylan/server.pem").
```

### Step 2 – server: add the TLS ports

Add to the server's `xylan` section (keep the old `client_port`/`data_port`):

```erlang
{client_tls_port, 29392},
{data_tls_port,   29393},
{tls_options, [{certfile, "/etc/xylan/server.pem"},
               {keyfile,  "/etc/xylan/server.key"}]},
```

Open 29392 and 29393 (tcp) in the firewall and **restart** xylan. A hot
code reload is not enough: the internal state changed between versions.

The log should show:

```
open client_tls port 29392
open data_tls port 29393
tls certificate /etc/xylan/server.pem fingerprint sha256:21:09:88:...
```

Old clients are not affected.

### Step 3 – laptop: connect with TLS

In the laptop's config, change the port and add `server_tls`. Keep the
existing `server_key`/`client_key` for now:

```erlang
{server_port, 29392},
{server_tls, [{fingerprint, "sha256:21:09:88:61:B9:A4:...:17:0F"}]},
```

Restart the laptop client. On the server the log shows

```
client connected from 1.2.3.4:51234 (tls=true)
client "laptop" reply and challenge sent (tls=true, alg=hmac_sha256)
client "laptop" credential accepted (tls=true)
```

and `xylan:status().` on the server shows `tls=true` for the laptop.
Test it: `ssh -p <user port> you@xylan3.example.com`.

With TLS the client automatically uses HMAC-SHA256 instead of the old
SHA1 authentication, and the data connections also go over TLS.

**Rollback:** set `server_port` back to 29390 and remove `server_tls`.

### Step 4 – lock it down

When TLS works for the laptop:

1. Give it new 256-bit keys, `xylan:generate_key(256)` (twice, one for
   `server_key` and one for `client_key`), the same values on both sides.
   The key is printed in two forms, decimal and hex. They are the same
   key; paste either one into the config:
   ```erlang
   1> xylan:generate_key(256).
   decimal: 59659307909770683321564084784431556580882190118024054427101833046974652398080
   hex:     16#83E5F8BE725EF5D05073320AD4E977B1C926D23E2C4C859EBE078C15E2B2BA00
   59659307909770683321564084784431556580882190118024054427101833046974652398080
   ```
   ```erlang
   {server_key, 16#83E5F8BE725EF5D05073320AD4E977B1C926D23E2C4C859EBE078C15E2B2BA00},
   ```
   Do not put `16#` in front of the *decimal* digits – that is a
   different number. To convert an existing decimal key:
   `"16#" ++ integer_to_list(Key, 16)`.
2. Add `{require_tls, true}` to the laptop's entry on the server. From
   now on the server refuses this client id on the old port and refuses
   the old SHA1 authentication.
3. Optionally switch to a client certificate ([section 5](#5-client-authentication-shared-keys-or-client-certificate)).

Repeat steps 3–4 for each client, then [turn off the old ports](#8-turning-off-the-old-ports).

---

## 3. Certificates

### Creating certificates with xylan

```erlang
xylan:generate_cert(Name, Options).
```

writes `<dir>/<Name>.pem` and `<dir>/<Name>.key` and prints the
fingerprint. The key is EC P-256, the certificate is self-signed.

| Option | Default | Meaning |
|--------|---------|---------|
| `{dir, Dir}` | `"."` | where to write the files |
| `{hosts, [Host]}` | `[Name]` | DNS names and/or IP addresses (subjectAltName). The first is the common name. |
| `{days, Days}` | `3650` | validity |
| `{usage, server \| client \| both}` | `server` | what the certificate may be used for |
| `{password, Pw}` | none | encrypt the key file (AES-256-CBC) |
| `{force, true}` | false | overwrite existing files (otherwise `{error, {exists, File}}`) |

Examples:

```erlang
%% tunnel certificate on the server
xylan:generate_cert("server", [{dir,"/etc/xylan"}, {hosts,["xylan3.example.com"]}]).

%% client certificate on a home machine
xylan:generate_cert("home", [{dir,"/etc/xylan"}, {usage,client}]).

%% gateway certificate, must contain the name users connect to
xylan:generate_cert("gw", [{dir,"/etc/xylan"},
                           {hosts,["xylan3.example.com","127.0.0.1"]}]).
```

### Which `hosts` to use

- **Tunnel certificate (server):** xylan clients check the fingerprint,
  not the name, so the name does not matter for xylan. Use the server's
  DNS name so tools like `openssl s_client` show something sensible.
- **Gateway certificate:** users' tools (curl, SDKs) *do* check the name.
  It must contain the exact name users put in their URL.
- **Client certificate:** the name is not checked; the default (`Name`)
  is fine.

### With openssl instead

Any EC or RSA certificate works. The equivalent of `generate_cert` is:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout server.key -out server.pem -days 3650 \
    -subj "/CN=xylan3.example.com" -addext "subjectAltName=DNS:xylan3.example.com"
chmod 600 server.key
```

### Key passwords

A password encrypts the key *file*. It protects the key when the file is
copied somewhere it should not be: a backup, a disk image, a stolen SD
card. It does **not** protect against someone who can log in as the
xylan user, since xylan must be able to read the password to start.

So a password is only worth having when the password is stored
**somewhere else than the key**. Putting it in `xylan.config` next to the
key adds nothing. xylan can read it from an environment variable or a
file:

```erlang
%% create an encrypted key
xylan:generate_cert("server", [{dir,"/etc/xylan"}, {password,"long random passphrase"}]).
```

```erlang
{tls_options, [{certfile, "/etc/xylan/server.pem"},
               {keyfile,  "/etc/xylan/server.key"},
               {password, {env, "XYLAN_KEY_PASSWORD"}}]}   %% or
               %% {password, {file, "/run/credentials/xylan.service/keypw"}}
               %% or {password, "plain"} (not recommended, see above)
```

`{file, F}` reads the first line of the file. With systemd,
`LoadCredential=` (or `LoadCredentialEncrypted=`, which ties the secret
to the machine's TPM) puts the password in `/run/credentials/...`,
outside the config and outside backups of `/etc`.

The same `password` option works in `server_tls` on the client (for
`home.key`) and in a gateway's `tls` options (for `gw.key`).

For an unattended Raspberry Pi with no TPM, file permissions (`0600`)
are usually the honest protection and a password adds little.

---

## 4. Fingerprint pinning

### What it is

A fingerprint is the SHA-256 hash of a certificate:

```
sha256:21:09:88:61:B9:A4:A1:C1:BC:CE:53:F2:59:A3:17:6E:26:9E:B0:8B:D6:81:C9:C3:19:14:44:AC:77:CA:17:0F
```

The client stores the server's fingerprint and, after the TLS handshake,
refuses to continue unless the certificate the server presented has
exactly that fingerprint. This is called *pinning*.

### Why

TLS encrypts, but encryption alone does not tell you *who* you are
talking to. Someone in the middle (a hostile network, a hijacked DNS
name) could present their own certificate, decrypt, and relay. Normally a
certificate authority (CA) vouches for the server's name. xylan uses
self-signed certificates, so no CA is involved; the fingerprint replaces
it. It is stronger than a CA in one way: only *that one* certificate is
accepted, not anything some CA was tricked into signing.

The fingerprint is not secret. It is safe to put it in configs, mails and
git.

### Which file

The fingerprint comes from the **certificate** (`server.pem`), never the
key. It is printed

- by `xylan:generate_cert/2` when the certificate is created,
- by `xylan:cert_fingerprint("/etc/xylan/server.pem")`,
- in the server log at startup (`tls certificate ... fingerprint ...`),
- by openssl: `openssl x509 -in server.pem -noout -fingerprint -sha256`.

The openssl output (`sha256 Fingerprint=21:09:...`) can be pasted as
is after the `=`; xylan accepts the fingerprint with or without the
`sha256:` prefix and in upper or lower case.

### The process

1. On the **server**, get the fingerprint from the certificate file
   (above).
2. Bring it to the client over a channel you already trust: copy it in an
   ssh session to the server, a password manager, your own notes. Do
   **not** read it over the network connection you are trying to protect.
3. Put it in the client config:
   ```erlang
   {server_tls, [{fingerprint, "sha256:21:09:88:..."}]}
   ```
4. Restart the client. If the fingerprint is wrong the client logs
   `certificate rejected` and keeps retrying every `reconnect_interval`;
   nothing is sent to the server.

To check from the client side what the server presents (for comparison,
not as the source of truth):

```sh
openssl s_client -connect xylan3.example.com:29392 </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256
```

If you would rather use a real CA chain, leave out `fingerprint` and give
normal ssl options, e.g. `{server_tls, [{verify, verify_peer}, {cacertfile, "ca.pem"}]}`.

---

## 5. Client authentication: shared keys or client certificate

The server must know that a connecting client really is "home" and not
someone who knows the name. There are two ways, which can be combined.

### Shared keys (HMAC)

Each client has two keys, `server_key` and `client_key`, with the **same
values in the server's and the client's config**. Each side proves it
knows the keys by answering a random challenge with HMAC-SHA256 (over
TLS) or SHA1 (old plain port).

- Simple, works with old clients.
- Both secrets are stored on the server. Anyone who gets a copy of the
  server config can impersonate every client.

### Client certificate

The client has its own certificate and key (`home.pem`/`home.key`).
It presents the certificate in the TLS handshake; the server compares its
fingerprint with the one configured for that client id.

- The server stores only the fingerprint, which is **not a secret**. A
  leaked server config does not let anyone impersonate a client.
- The private key never leaves the client machine.
- A stranger without the right certificate is turned away at its first
  message (the client id), before any authentication exchange and before
  it is handed to the client's session.
- The data connections must present the same certificate, so knowing a
  session key is not enough to take over a user's connection.
- Revoking a client = removing its fingerprint from the server config.

**When to use it:** for long-lived machines you control (home servers,
Raspberry Pis, your laptop) once the TLS port works. Keep shared keys for
clients that cannot be upgraded yet. Use both if you want two independent
proofs.

### Setting up a client certificate

1. **On the client**, create the certificate:
   ```erlang
   1> xylan:generate_cert("home", [{dir,"/etc/xylan"}, {usage,client}]).
   certificate: /etc/xylan/home.pem
   key:         /etc/xylan/home.key
   fingerprint: sha256:9A:3F:...
   ```
2. **On the client**, add it to `server_tls`:
   ```erlang
   {server_tls, [{fingerprint, "sha256:21:09:88:..."},   %% the server's
                 {certfile, "/etc/xylan/home.pem"},
                 {keyfile,  "/etc/xylan/home.key"}]},
   ```
3. **On the server**, add the client's fingerprint to its entry:
   ```erlang
   {"home", [{client_cert, "sha256:9A:3F:..."},
             {server_key, ...}, {client_key, ...},   %% still there
             {route, [...]}]}
   ```
   `client_cert` implies `require_tls`.
4. Restart both. The server logs `client "home" connected (client cert ok)`.
   With both certificate and keys configured, both are checked.
5. **Optional, certificate only:** remove `server_key` and `client_key`
   from *both* configs and restart both. The client then authenticates
   with `alg=cert`, and the server holds no secret for this client.

Note the two fingerprints in play:

| fingerprint | of | configured on | as |
|---|---|---|---|
| server | `server.pem` | client | `server_tls` → `fingerprint` |
| client | `home.pem` | server | client entry → `client_cert` |

---

## 6. Rotating certificates

A new certificate has a new fingerprint. To change a certificate without
an outage, both `fingerprint` (client) and `client_cert` (server) accept a
**list**: the old and the new fingerprint are accepted during the change.

**Server certificate:**

1. Create the new certificate under another name:
   `xylan:generate_cert("server-2027", [...])`.
2. On every client, add the new fingerprint next to the old one and
   restart:
   `{fingerprint, ["sha256:<old>", "sha256:<new>"]}`.
3. On the server, point `tls_options` at the new files and restart.
4. Remove the old fingerprint from the clients.

**Client certificate:**

1. On the client, create `home-2027.pem/.key`.
2. On the server: `{client_cert, ["sha256:<old>", "sha256:<new>"]}`, restart.
3. On the client, switch `certfile`/`keyfile` to the new files, restart.
4. Remove the old fingerprint on the server.

Revoking a lost or stolen client: remove its fingerprint (and keys) from
the server config and restart the server.

---

## 7. API gateway and API keys

The gateway runs on the **client** (home) side next to a web service such
as ollama. Users connect with TLS to a user port on the server; the
encrypted stream goes through the tunnel to the gateway, which checks the
API key and forwards the request to the service on localhost. The xylan
server never sees the key or the request.

### API keys

Keys look like OpenAI/Anthropic keys and are accepted as
`Authorization: Bearer <key>` or `x-api-key: <key>`:

```
sk-xyl-LiOSGdJ4-S3mDjsLEhKhsJyOgBozZs1dh7Qes4mm1uyLKrcvYXUs0ivUUp
       └─ id ─┘ └──────────── secret (256 bit) ─────────────┘└crc ┘
```

Only the id and a SHA-256 hash are stored. With
`{api_key_file, "/etc/xylan/api_keys.conf"}` in the client config:

```erlang
xylan:generate_api_key("tony-laptop").                    %% key shown ONCE
xylan:generate_api_key("ci", [{expires,{2027,6,30}}, {allow,[ollama]}]).
xylan:list_api_keys().
xylan:revoke_api_key("LiOSGdJ4").
```

Changes take effect immediately, no restart. Without `api_key_file` the
entry is printed for you to paste into `{api_keys, [...]}`.

### Gateway config (client)

```erlang
{route, [{ [{data, ssl}], [{port, 11443}] }]},     %% tls traffic to the gateway
{api_key_file, "/etc/xylan/api_keys.conf"},
{api_gateways,
 [{ollama, [{port, 11443}, {ip, {127,0,0,1}},
            {target, {"127.0.0.1", 11434}},
            {tls, [{certfile, "/etc/xylan/gw.pem"},
                   {keyfile,  "/etc/xylan/gw.key"}]},
            {host, rewrite},          %% ollama refuses non-local Host headers
            {max_connections, 64}]}]}
```

and on the server a user port routed to that client, e.g.
`{port, [{ollama, "0.0.0.0", 11443}]}` and `[{dst_port, 11443}]` in the
client's routes.

### Using it

```sh
curl --cacert gw.pem -H "Authorization: Bearer sk-xyl-..." \
     https://xylan3.example.com:11443/api/tags

export OPENAI_BASE_URL=https://xylan3.example.com:11443/v1
export OPENAI_API_KEY=sk-xyl-...
export SSL_CERT_FILE=gw.pem        # only with a self-signed gw certificate
```

With a self-signed `gw.pem`, users need the file (it is not secret). A
certificate from Let's Encrypt for the public name avoids that; the
certificate lives on the home machine since that is where TLS ends, so
use the DNS-01 challenge.

Each connection carries one request (`Connection: close` is forced), the
key headers are removed before forwarding, and a missing or bad key gives
`401` with an OpenAI- or Anthropic-style JSON error.

---

## 8. Turning off the old ports

When every client uses TLS (check `xylan:status()` on the server, all
`tls=true`), set on the server:

```erlang
{client_port, none},
{data_port,   none},
```

restart, and close 29390/29391 in the firewall.

---

## 9. Troubleshooting

Raise the log level with `xylan:set_debug(true)`.

### Client log

| Message | Meaning |
|---------|---------|
| `server ... certificate rejected {error,{fingerprint_mismatch,"sha256:..."}}` | The server's certificate is not the pinned one. The message shows what the server presented. Check the fingerprint (section 4); if the server certificate was replaced, rotate (section 6). |
| `server not connected, {error,econnrefused}` | Wrong port, server not running, or firewall. |
| `server not connected, {error,timeout}` | Often `server_tls` used against the old plain port (29390), which never answers the TLS handshake. |
| `server not connected, {error,{tls_alert,...}}` | TLS handshake failed, e.g. a problem with the client certificate or key. |
| `server credential failed` | `server_key` differs between client and server. |
| `server_key/client_key or client certificate (certfile) required` | `server_tls` without keys and without a client certificate. |
| `server_key and client_key required without server_tls` | Plain (old port) client without keys. |

### Server log

| Message | Meaning |
|---------|---------|
| `client "x" requires tls, rejected` | Client with `require_tls` connected on the old port. |
| `client "x" bad client certificate sha256:..., rejected` | The presented certificate (or `(none)`) does not match `client_cert`. The fingerprint shown is what the client presented. |
| `client "x" credential failed` | `client_key` differs, or wrong key on the client. |
| `client "x" requires tls and hmac_sha256/cert` | An old client tried SHA1 auth for a `require_tls` client. |
| `client "x" has no keys, use client certificate` | Client entry has only `client_cert`, but the client sent HMAC auth (it still has keys in its config). |
| `client "x" not found` | Unknown client id. |
| `data channel mismatch` / `data channel client certificate mismatch` | A data connection did not match the session's channel type or certificate. Seen during attacks, or if a client is half upgraded. |
| `tls handshake limit (per ip) reached` | Too many unfinished TLS handshakes; see `max_tls_handshakes*`. |
| `tls port configured but tls_options has no certificate` | Startup error: TLS port without `certfile`. |
| `{password_env_not_set, Var}` at startup | The key password variable is not set in xylan's environment. |

### Checking the server by hand

```sh
openssl s_client -connect xylan3.example.com:29392 </dev/null
```

shows the certificate and confirms that TLS is up.

---

## 10. Reference

### Server options (new in 2.x)

| Option | Default | |
|--------|---------|---|
| `client_port` | `29390` | old control port, `none` to disable |
| `data_port` | `29391` | old data port, `none` to disable |
| `client_tls_port` | `none` | TLS control port |
| `data_tls_port` | `none` | TLS data port |
| `tls_options` | `[]` | ssl server options; `certfile` + `keyfile` required with TLS ports; `password` may be `{env,V}` / `{file,F}` |
| `max_tls_handshakes` | `64` | concurrent unfinished TLS handshakes |
| `max_tls_handshakes_per_ip` | `8` | the same per source address |
| `auth_timeout` | `5000` | ms allowed for the TLS handshake and for each authentication step |

Per client entry:

| Option | |
|--------|---|
| `server_key`, `client_key` | shared keys; optional if `client_cert` is set (both or none) |
| `require_tls` | only TLS + HMAC-SHA256 (or certificate) accepted |
| `client_cert` | fingerprint or list of fingerprints of the client certificate; implies `require_tls` |

### Client options (new in 2.x)

| Option | |
|--------|---|
| `server_port` | `29392` for TLS |
| `server_tls` | enables TLS. `fingerprint` (string or list), optional `certfile`/`keyfile`/`password` for a client certificate, or plain ssl client options |
| `api_key_file`, `api_keys`, `api_gateways` | see section 7 |

### Functions

| Function | |
|----------|---|
| `xylan:generate_key(256)` | random 256-bit key for `server_key`/`client_key`, printed in decimal and hex |
| `xylan:generate_cert(Name, Opts)` | self-signed certificate + key, prints fingerprint |
| `xylan:cert_fingerprint(File)` | fingerprint of a certificate file |
| `xylan:generate_api_key(Name [, Opts])` | new API key |
| `xylan:list_api_keys()`, `xylan:revoke_api_key(Id)` | manage API keys |
| `xylan:status()` | connection status of clients/servers |

### Compatibility

- New servers accept old clients on the old ports; new clients without
  `server_tls` work against old servers.
- Restart nodes when upgrading – no hot code loading between 1.x and 2.x.
- TLS and HMAC need OTP 22.1 or later; the code needs OTP 21 to compile.
