# Claude subscription (experimental, unofficial)

This is an optional personal-use route. It is unofficial, not endorsed by Anthropic, and may be restricted for third-party apps by the vendor. It can stop working or affect your account. The regular Anthropic API key option is unchanged.

## Signing in

1. Open X-Ray API Keys and choose "Claude subscription (experimental) - account".
2. Read the warning and continue. A QR code and URL for Claude's official sign-in page are shown.
3. Sign in on your phone or computer and approve. Copy the long `code#state` value shown.
4. Tap "Enter code" and type or paste it. This is a manual step because there is no on-device browser and no relay or companion service. The code field is masked, and the code is never logged or saved by the UI.

Closing or cancelling any dialog during sign-in invalidates the pending flow.

## Permissions requested

Sign-in requests these scopes: `org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`. Refresh requests the same set without `org:create_api_key`. Only `user:inference` is required: if the service returns granted scopes, a token missing it is rejected. If the response has no scope field, entitlement stays unverified until the first request. X-Ray does not create API keys and makes no profile, session, MCP or file-upload calls. The full set is kept because it is Claude Code's compatibility string, and the pinned source (Jcode 02777ce1) does not show that a smaller set is accepted. This was not tested live.

Technically, the grant lets whoever holds the token do all of those things. The token is stored unencrypted on the reader, so treat physical or USB access to it as account access. Network use is limited to `platform.claude.com` (token) and `api.anthropic.com` (Messages).

## Limits

- "Connected" only means a local credential is present. It does not prove your plan includes Claude access or has quota left.
- Usage counts against your Claude plan quota.
- Subscription requests never fall back to a paid API automatically.
- Tokens are stored locally on the reader. On FAT/USB-accessible storage, physical access may expose them.
- Signing in does not change your saved model or defaults. Pick a "Claude subscription (experimental)" model in the model menu, which is only usable once connected.
- Sign out removes local credentials only.

## Thinking

The Claude extended-thinking setting is not sent in v1. Requests use the plain no-thinking adapter, so any thinking preference in X-Ray does not apply to this route.

## Validation status

Covered by mocked UI specs. Not tested on hardware or against the live service.
