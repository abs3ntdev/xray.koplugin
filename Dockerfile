FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=8080
# Explicit allowlist keeps credentials, Wrangler cache and release tooling out.
COPY --chown=node:node LICENSE ./LICENSE
COPY --chown=node:node relay/app.mjs relay/server.mjs ./relay/
COPY --chown=node:node cloudflare-worker/worker.js cloudflare-worker/package.json ./cloudflare-worker/
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 8080) + '/healthz').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"
CMD ["node", "relay/server.mjs"]
