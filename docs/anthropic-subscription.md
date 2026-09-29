# Claude subscription (experimental, unofficial)

This is an optional personal-use route. It is unofficial, not endorsed by Anthropic, and may be restricted for third-party apps by the vendor. It can stop working or affect your account. The regular Anthropic API key option is unchanged.

## Signing in

1. Open X-Ray API Keys and choose "Claude subscription (experimental) - account".
2. Read the warning and continue. A QR code and URL for Claude's official sign-in page are shown.
3. Sign in on your phone or computer and approve. Copy the long `code#state` value shown.
4. Either use "Receive code from phone" (recommended, see below) or tap "Enter code" and type or paste it. Typing is a manual step because there is no on-device browser. The code field is masked, and the code is never logged or saved by the UI.

### Receive code from phone (optional)

Typing a long code on an e-reader is awkward, so the authorization QR dialog also offers "Receive code from phone". It reuses the existing X-Ray web setup page as an encrypted carrier only:

1. Scan the first QR, sign in on Claude's page and copy the code on your phone.
2. On the reader tap "Receive code from phone" and scan the second QR (a transfer link, not the six-character pairing code).
3. On the page, paste the Claude authorization code into the field labelled "API key" and tap Send (pasting alone does not send it). This is only a transfer box: do NOT enter a real API key. Any provider choice on the page is ignored.
4. The reader polls in the background and continues sign-in automatically. It stops before the exchange, so the code is used once.

The authorization URL, PKCE verifier and tokens never go to the relay, only the encrypted code does. A pasted real API key is rejected locally by the auth module before any token request. Cancel, closing the dialog, starting a new sign-in or expiry stop polling and discard the transfer session. The relay keeps the encrypted ciphertext until its TTL expires and has no delete API. Single use is enforced locally on the reader only. The relay operator serves the page's JavaScript, so you trust it while pasting. "Enter code" manual entry remains available.

Closing or cancelling any dialog during sign-in invalidates the pending flow.

## Permissions requested

Sign-in requests these scopes: `org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`. Refresh requests the same set without `org:create_api_key`. Only `user:inference` is required: if the service returns granted scopes, a token missing it is rejected. If the response has no scope field, entitlement stays unverified until the first request. X-Ray does not create API keys and makes no profile, session, MCP or file-upload calls. The full set is kept because it is Claude Code's compatibility string, and the pinned source (Jcode 02777ce1) does not show that a smaller set is accepted. This was not tested live.

Technically, the grant lets whoever holds the token do all of those things. The token is stored unencrypted on the reader, so treat physical or USB access to it as account access. Network use is limited to `platform.claude.com` (token) and `api.anthropic.com` (Messages), plus the optional pinned X-Ray relay (`xray-setup.ultimatejimmy.workers.dev`) only if you use phone transfer.

## Limits

- "Connected" only means a local credential is present. It does not prove your plan includes Claude access or has quota left.
- Usage counts against your Claude plan quota.
- Normal primary/secondary failover applies: if the subscription fails, the configured Secondary AI Model is tried. A billed API secondary can incur API charges. Choose a subscription or unconfigured secondary to avoid charges. Cancelling never triggers the fallback. Settings → Logs → Update History shows which slot served each update.
- Tokens are stored locally on the reader. On FAT/USB-accessible storage, physical access may expose them.
- Signing in does not change your saved model or defaults. Pick a "Claude subscription (experimental)" model in the model menu, which is only usable once connected.
- Sign out removes local credentials only.

## Thinking

The Claude extended-thinking setting is not sent in v1. Requests use the plain no-thinking adapter, so any thinking preference in X-Ray does not apply to this route.

## Validation status

Covered by mocked UI specs. Not tested on hardware or against the live service.
