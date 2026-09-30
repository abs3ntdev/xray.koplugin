# KOReader X-Ray — Cloudflare Worker Setup Relay

An ephemeral pairing relay that allows users to configure their API keys on their KOReader e-reader from any smartphone or PC.

## Docker / Unraid

For a single-container Node server, use the release-built image and [Unraid/Pangolin guide](../docs/self-hosted-relay.md). It shares this browser page but uses a separate bounded in-memory HTTP handler. No Cloudflare account or KV is needed.

## Features
- **Works Everywhere**: Outbound HTTPS polling bypasses guest Wi-Fi isolation, cellular 5G data, WSL emulators, and local firewalls.
- **Client-side encryption**: The browser uses the existing HMAC-SHA256 stream/tag format with the full 64-hex secret in the QR URL fragment. The relay carries ciphertext. Trust the page operator, who controls the JavaScript handling your input; the six-character pairing code alone is insufficient.
- **Single-File Zero Dependency**: Serves both the mobile web UI and ephemeral pairing endpoints in a single `worker.js` file.
- **100% Free**: Operates entirely within Cloudflare's free tier (100,000 requests/day).

---

## Deployment (1-Click)

### Method 1: Cloudflare Dashboard (No CLI required)
1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com) and go to **Workers & Pages**.
2. Click **Create Application** → **Create Worker**.
3. Name it (e.g. `koreader-xray-setup`) and click **Deploy**.
4. Click **Edit Code**, paste the entire contents of `worker.js`, and click **Deploy**.
5. Your worker URL will be `https://koreader-xray-setup.<your-subdomain>.workers.dev`.

### Method 2: Wrangler CLI
```bash
npm install -g wrangler
wrangler login
wrangler deploy
```

The Wrangler configuration contains no account or namespace identifiers. Create your own optional KV namespace before enabling its commented binding. The Cloudflare Worker backend retains its existing behavior; the Docker limits and single-instance semantics are documented separately.
