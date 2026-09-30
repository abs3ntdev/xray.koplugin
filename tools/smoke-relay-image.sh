#!/usr/bin/env bash
set -euo pipefail
image="${1:-xray-relay:test}"
docker run -d --name xray-relay-test --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --memory=128m --pids-limit=64 \
  -e RELAY_ORIGIN=https://relay.example.test -p 127.0.0.1:8080:8080 "$image"
trap 'docker logs xray-relay-test; docker rm -f xray-relay-test' EXIT
base=http://127.0.0.1:8080
for attempt in $(seq 1 30); do
  if curl --fail --silent "$base/healthz"; then break; fi
  sleep 1
done
curl --fail --silent "$base/healthz"
test "$(docker exec xray-relay-test id -u)" != 0
session=$(curl --fail --silent -X POST -H 'Content-Type: application/json' -d '{}' "$base/api/session/create" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["success"]; print(d["session_id"])')
[[ "$session" =~ ^[A-Z0-9]{6}$ ]]
test "$(curl --silent -o /dev/null -w '%{http_code}' "$base/api/session/$session/poll")" = 204
# Dummy opaque bytes only. No API keys, OAuth codes or other real credentials.
payload=$(python3 -c 'import base64,json; print(json.dumps({"encrypted_payload":"HMAC:"+base64.b64encode(bytes([7])*64).decode()}))')
curl --fail --silent -X POST -H 'Content-Type: application/json' -d "$payload" "$base/api/session/$session/submit"
curl --fail --silent "$base/api/session/$session/poll" | python3 -c 'import base64,json,sys; d=json.load(sys.stdin); assert d["status"]=="ready" and d["payload"]=="HMAC:"+base64.b64encode(bytes([7])*64).decode()'
