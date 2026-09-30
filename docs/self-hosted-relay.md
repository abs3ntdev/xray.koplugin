# Run your own X-Ray setup relay on Unraid

The relay is a small, single-container Node 24 LTS HTTP server. It serves the
existing phone setup page and passes encrypted pairing payloads to your reader.
It is not an AI gateway: model requests and OAuth token exchanges still go
straight from KOReader to the existing pinned provider endpoints.

## Image published with each release

After this change is merged and the next **Release** workflow succeeds, use:

```text
ghcr.io/abs3ntdev/xray.koplugin:latest
```

The workflow also publishes matching `vMAJOR.MINOR.PATCH` and
`MAJOR.MINOR.PATCH` image tags, for example `:v26.10.0` if that release exists.
Use a version tag (or the published image digest) if you want deliberate upgrades.
Version tags can be published or repaired after main advances. Rerunning an older
release publishes its version tags without replacing the latest release’s `latest` tag.
The image targets **linux/amd64**, the usual Intel/AMD Unraid hosts. It uses
Node 24 LTS, has no npm runtime dependencies, and runs as the unprivileged
`node` user. The MIT license is included at `/app/LICENSE`.

The image is built from the exact published plugin release commit. The existing
`xray.koplugin.zip` release asset remains unchanged. No manual PAT or repository
secret is needed: the image job uses the workflow's temporary `GITHUB_TOKEN`
with `contents: read` and `packages: write`.

**First publication:** GitHub Container Registry can create a package with
private visibility. If anonymous pulls fail, the repository owner should open
the repository's **Packages** entry, select the image, and set the package's
visibility to **Public** if public distribution is intended. A public repository
does not by itself guarantee a public package. This workflow does not change
package visibility. See [GitHub's container registry documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).

## Unraid: Docker → Add Container

No Compose stack, database, appdata mapping, API key or OAuth secret is needed.
In Unraid's container editor, use:

- **Name:** `xray-relay`
- **Repository:** `ghcr.io/abs3ntdev/xray.koplugin:latest` (or a published version tag)
- **Network Type:** `bridge`, or the existing network reachable by your Pangolin/Newt connector
- **Port:** container `8080/TCP` → an unused host port, for example `8087`
- **Variable:** `RELAY_ORIGIN` = your public origin, for example `https://xray.example.com`
- **Privileged:** off
- **Volume mappings:** none
- **Extra Parameters** (Advanced View):

```text
--read-only --cap-drop=ALL --security-opt=no-new-privileges --memory=128m --cpus=0.5 --pids-limit=64 --log-opt max-size=1m --log-opt max-file=2
```

Leave the internal `PORT` at its default `8080`. Only change the host-side port
if it conflicts. Do not pass `PUID`/`PGID`, provider keys, auth tokens or passwords.
Enable Unraid's **Autostart** if desired. These are suggested settings; adding
the container and changing your networking remain your deployment actions.

`RELAY_ORIGIN` must be a DNS hostname using HTTPS, at the root path and the
standard public TLS port 443. A final slash is allowed. IP addresses, localhost,
userinfo, explicit ports, URL paths, queries and fragments are rejected. Startup
fails rather than guessing a hostname. The internal HTTP listener is intended
only for the trusted reverse-proxy/tunnel network; do not port-forward `8080` or
`8087` directly to the internet.

Unraid's [container management guide](https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/managing-and-customizing-containers/)
explains ports, variables and container updates.

## Pangolin HTTPS resource

1. Create a dedicated HTTPS hostname, such as `xray.example.com`, with a valid
   publicly trusted certificate. Set the exact same origin in `RELAY_ORIGIN`.
2. Route that resource to HTTP at the container's reachable address. If your
   Newt connector reaches Unraid via its LAN IP, use the Unraid IP and host
   port `8087`. If it shares the container's Docker network, use
   `xray-relay:8080`. `127.0.0.1` inside another container is that container,
   not the Unraid host or the relay.
3. The reader's `/api/session/create` and `/api/session/<id>/poll` requests must
   reach the relay without a Pangolin sign-in page, browser challenge, access
   cookie or extra authorization header. The phone also needs the page and
   `/api/session/<id>/submit`. Use a dedicated public resource configured for
   non-interactive access; do not disable authentication on unrelated resources.
4. Preserve the paths and query string. Do not redirect to another hostname or
   mount the relay below a path prefix. Do not cache the API or record request
   bodies, headers or full QR URLs in proxy logs. Prefer turning off access
   logging for this dedicated resource, since URL paths contain session IDs.
5. From a phone on cellular data, open `https://xray.example.com/healthz` and
   confirm JSON `{"status":"ok"}` without a login or redirect. This checks the
   external route; a healthy Docker container alone does not prove public TLS
   and routing work.

The relay deliberately rejects cross-origin browser requests and credential
headers. Interactive gateway authentication is incompatible with these
credential-free machine endpoints. Limit abuse with the proxy's request limits
and network controls that work for both your reader and phone. No secret bypass
token is built into the plugin. See [Pangolin's resource authentication guide](https://docs.pangolin.net/manage/resources/public/authentication).

## Point KOReader at your relay

Install the plugin release containing this change. Open **X-Ray → Settings → AI Settings → API Keys & Providers →
Setup relay server...**, enter `https://xray.example.com`, and save. This one
`cloud_setup_worker_url` setting applies to ordinary API-key QR setup, Claude's
optional phone authorization-code transfer, and TypeSafe phone-key transfer.
OpenAI's existing device-login flow does not use this relay.

The setting is validated and saved through the plugin's normal settings store.
An absent setting uses the upstream relay. An invalid saved custom setting or a
failed custom server does **not** silently switch to the upstream server. The
**Use upstream relay** button is an explicit reset. An in-progress pairing
session keeps the origin where it started; start a new session after changing
the setting.

Use the complete QR link from the reader. Its 64-hex-character fragment contains
the encryption key and stays in the browser; a six-character pairing code on
its own is insufficient. The browser now rejects missing, shortened and invalid
fragment secrets instead of deriving a weak key from the public pairing code.
The existing `HMAC:` ciphertext format is preserved; there is no crypto-format
migration. Claude's phone transfer still uses the page's field labelled
**API key** as an encrypted transfer box for the authorization code, as described
in [Claude setup](anthropic-subscription.md).

## State, privacy and limits

- **Single instance only.** Sessions live only in process memory, for ten minutes.
  No SQLite, Redis, Cloudflare KV or durable volume is used. A restart or update
  cancels active pairings; start them again. Do not load-balance across replicas.
- The server does not decrypt payloads, need provider credentials, contact model
  providers, log requests or store plaintext keys. The trusted browser page
  necessarily handles what you type. A malicious relay operator could change
  that page, so self-hosting changes whom you trust; encryption is not a reason
  to trust an unknown page. The existing custom HMAC stream protocol is retained
  for compatibility and is not presented as a new audited cryptographic design.
- Up to **256 live sessions**, **8 KiB encoded ciphertext** (the browser limits plaintext to 4 KiB for reader compatibility), **16 KiB request
  body**, **600 requests/minute** and **30 new sessions/minute**, globally per
  instance. Limits are intentionally conservative for a personal relay. Polling
  has a global budget too. HTTP headers are bounded to 8 KiB, active sockets to
  128, and slow requests time out. The app ignores forwarded client-IP headers,
  so untrusted headers cannot bypass limits.
- The first submitted ciphertext wins. An identical submit retry succeeds;
  different replacement data gets `409`. Polling is retryable and does not
  delete data. Ciphertext expires at the original deadline, even after submit.
  Expired entries are swept within 30 seconds and on requests, and cannot be polled after their deadline. The reader enforces local
  one-time use for phone-code transfer.
- TLS certificate/hostname verification is required by both reader relay flows.
  Redirects and relay credential headers are rejected. Changing the relay
  setting never changes the allowlist for OAuth tokens or model requests.
- Docker build inputs are explicitly allowlisted. No `.wrangler` cache,
  personalized plugin settings, account IDs, release tooling or credentials are
  copied into the image. Keep all such data out of source control regardless.

## Troubleshooting

- **Container exits immediately:** check that `RELAY_ORIGIN` is a valid HTTPS root
  origin. Logs intentionally contain only startup status or generic errors.
- **Reader says relay unavailable, or the phone gets HTML instead of JSON:**
  check public DNS/TLS, the Pangolin target and interactive-auth settings. The
  reader rejects redirects rather than following them with session traffic.
- **Browser returns 400 despite public routing:** use a dedicated hostname with no
  parent-domain cookies, or a clean browser profile. The relay rejects Cookie
  headers as well as authorization headers.
- **TLS failure on reader:** check its clock and trusted CA bundle. Never disable
  certificate verification or use a self-signed public endpoint as a workaround.
- **Missing secret in browser:** scan a new full QR link. Do not paste the full
  link into chat, logs or issue reports; it contains the client-side secret.
- **404 during pairing:** the session may have expired or the container restarted.
  Start a new pairing on the reader. **429/503:** wait for request limits or old
  sessions to clear; do not add a second replica.
- **Unable to pull image:** verify that the release's image job succeeded and the
  GHCR package is public or otherwise accessible to your Docker client. This
  change does not publish an image until an authorized release runs.

## Local development

No npm install is needed for the relay itself:

```sh
npm run test:relay
RELAY_ORIGIN=https://relay.example.test node relay/server.mjs
curl http://127.0.0.1:8080/healthz
docker build -t xray-relay:local .
```

Local HTTP is suitable for health/API smoke tests using dummy data. A real phone
setup must go through the trusted HTTPS origin so Web Crypto is available and
browser origin checks match. The PR workflow runs the relay tests, plugin Lua
suite and a non-root, read-only Docker build/smoke test without pushing images.
