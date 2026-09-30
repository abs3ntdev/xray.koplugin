/**
 * KOReader X-Ray Plugin — Cloudflare Worker Setup Relay
 * 
 * Ephemeral encrypted pairing relay for setting API keys from smartphone / PC.
 * Payloads are encrypted in the browser using the existing HMAC-SHA256 stream format with
 * a client-generated secret from the URL hash (#secret), so plaintext API keys
 * are never visible to the relay or stored online.
 */

// In-memory session store (backed by KV if bound)
const memoryStore = new Map();

// Helper: Generate random 6-character uppercase alphanumeric code
function generateSessionId() {
  const chars = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"; // Omit ambiguous characters like 0, 1, I, O
  let result = "";
  const randomBytes = new Uint8Array(6);
  crypto.getRandomValues(randomBytes);
  for (let i = 0; i < 6; i++) {
    result += chars[randomBytes[i] % chars.length];
  }
  return result;
}

// Clean up expired sessions (> 5 minutes)
function cleanExpiredSessions() {
  const now = Date.now();
  for (const [id, session] of memoryStore.entries()) {
    if (session.expiresAt < now) {
      memoryStore.delete(id);
    }
  }
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const pathname = url.pathname;

    // CORS headers for API calls
    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }

    cleanExpiredSessions();

    // 1. POST /api/session/create -> E-reader creates a new pairing session
    if (pathname === "/api/session/create" && request.method === "POST") {
      const sessionId = generateSessionId();
      const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes TTL

      const sessionData = {
        status: "pending",
        encryptedPayload: null,
        expiresAt,
        createdAt: Date.now(),
      };

      memoryStore.set(sessionId, sessionData);

      if (env?.XRAY_SESSIONS) {
        await env.XRAY_SESSIONS.put(
          `session:${sessionId}`,
          JSON.stringify(sessionData),
          { expirationTtl: 600 }
        );
      }

      return new Response(
        JSON.stringify({
          success: true,
          session_id: sessionId,
          expires_in: 600,
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // 2. GET /api/session/:id/poll -> E-reader polls for submitted keys
    const pollMatch = pathname.match(/^\/api\/session\/([A-Za-z0-9]+)\/poll$/);
    if (pollMatch && request.method === "GET") {
      const sessionId = pollMatch[1].toUpperCase();

      let session = memoryStore.get(sessionId);
      if (!session && env?.XRAY_SESSIONS) {
        const kvData = await env.XRAY_SESSIONS.get(`session:${sessionId}`, "json");
        if (kvData) session = kvData;
      }

      if (!session || session.expiresAt < Date.now()) {
        return new Response(
          JSON.stringify({ error: "Session expired or not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      if (session.status === "ready" && session.encryptedPayload) {
        return new Response(
          JSON.stringify({
            success: true,
            status: "ready",
            payload: session.encryptedPayload,
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Still waiting for user submission
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // 3. POST /api/session/:id/submit -> Browser sends encrypted keys
    const submitMatch = pathname.match(/^\/api\/session\/([A-Za-z0-9]+)\/submit$/);
    if (submitMatch && request.method === "POST") {
      const sessionId = submitMatch[1].toUpperCase();

      let session = memoryStore.get(sessionId);
      if (!session && env?.XRAY_SESSIONS) {
        const kvData = await env.XRAY_SESSIONS.get(`session:${sessionId}`, "json");
        if (kvData) session = kvData;
      }

      if (!session || session.expiresAt < Date.now()) {
        return new Response(
          JSON.stringify({ success: false, error: "Session expired or code invalid. Please verify the 6-character code on your e-reader screen." }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      try {
        const body = await request.json();
        if (!body.encrypted_payload) {
          return new Response(
            JSON.stringify({ success: false, error: "Missing encrypted payload" }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        session.status = "ready";
        session.encryptedPayload = body.encrypted_payload;
        memoryStore.set(sessionId, session);

        if (env?.XRAY_SESSIONS) {
          await env.XRAY_SESSIONS.put(
            `session:${sessionId}`,
            JSON.stringify(session),
            { expirationTtl: 600 }
          );
        }

        return new Response(
          JSON.stringify({ success: true, message: "Keys successfully transmitted to your e-reader!" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } catch (err) {
        return new Response(
          JSON.stringify({ success: false, error: "Malformed request payload" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    // 4. GET / -> Serve Mobile Web Portal
    if (request.method === "GET" && (pathname === "/" || pathname === "/index.html")) {
      return new Response(HTML_PAGE, {
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "public, max-age=3600",
        },
      });
    }

    return new Response("Not Found", { status: 404 });
  },
};

export const HTML_PAGE = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>KOReader X-Ray — API Key Setup</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  body {
    background: #090d16;
    color: #f1f5f9;
    display: flex;
    justify-content: center;
    align-items: center;
    min-height: 100vh;
    padding: 16px;
  }
  .card {
    background: #131d2e;
    border-radius: 20px;
    box-shadow: 0 20px 40px -10px rgba(0,0,0,0.6);
    max-width: 520px;
    width: 100%;
    padding: 24px;
    border: 1px solid #223249;
  }
  .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
  .header h1 { font-size: 1.35rem; font-weight: 800; color: #38bdf8; letter-spacing: -0.5px; }
  .badge-device {
    font-size: 0.72rem;
    font-weight: 700;
    color: #38bdf8;
    background: rgba(56, 189, 248, 0.12);
    border: 1px solid rgba(56, 189, 248, 0.3);
    padding: 4px 10px;
    border-radius: 9999px;
  }

  /* Privacy Notice Box */
  .security-box {
    background: rgba(16, 185, 129, 0.08);
    border: 1px solid rgba(16, 185, 129, 0.3);
    border-radius: 12px;
    padding: 12px 14px;
    margin-bottom: 18px;
  }
  .security-header {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.85rem;
    font-weight: 700;
    color: #34d399;
    margin-bottom: 4px;
  }
  .security-text {
    font-size: 0.78rem;
    line-height: 1.45;
    color: #cbd5e1;
  }

  /* Screen View Controllers */
  .view-step { display: none; }
  .view-step.active { display: block; }

  /* STEP 1: Code Input Screen */
  .step1-card {
    text-align: center;
    padding: 10px 0;
  }
  .step1-title {
    font-size: 1.15rem;
    font-weight: 800;
    color: #f8fafc;
    margin-bottom: 8px;
  }
  .step1-desc {
    font-size: 0.85rem;
    color: #94a3b8;
    line-height: 1.45;
    margin-bottom: 20px;
  }
  .code-input-wrap {
    position: relative;
    max-width: 300px;
    margin: 0 auto 16px auto;
  }
  .code-input-single {
    width: 100%;
    background: #0b121e;
    border: 2px solid #38bdf8;
    color: #38bdf8;
    border-radius: 12px;
    padding: 14px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    font-size: 1.6rem;
    font-weight: 800;
    letter-spacing: 6px;
    text-transform: uppercase;
    text-align: center;
    display: block;
    outline: none;
    box-shadow: 0 0 15px rgba(56, 189, 248, 0.15);
  }
  .code-input-single:focus {
    border-color: #7dd3fc;
    box-shadow: 0 0 20px rgba(56, 189, 248, 0.3);
  }

  /* STEP 2: Key Entry Screen */
  .paired-status-bar {
    background: #0b121e;
    border: 1px solid #223249;
    border-radius: 10px;
    padding: 8px 14px;
    margin-bottom: 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .paired-tag {
    font-size: 0.8rem;
    font-weight: 700;
    color: #34d399;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .change-code-btn {
    font-size: 0.75rem;
    color: #94a3b8;
    background: none;
    border: none;
    text-decoration: underline;
    cursor: pointer;
    padding: 2px 4px;
  }
  .change-code-btn:hover { color: #38bdf8; }

  /* Provider Grid */
  .section-label {
    display: block;
    font-size: 0.82rem;
    font-weight: 700;
    color: #94a3b8;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-bottom: 8px;
  }
  .provider-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    margin-bottom: 16px;
  }
  .provider-btn {
    background: #0b121e;
    color: #94a3b8;
    border: 1px solid #223249;
    padding: 10px 12px;
    border-radius: 10px;
    font-size: 0.82rem;
    font-weight: 700;
    cursor: pointer;
    text-align: left;
    display: flex;
    align-items: center;
    justify-content: space-between;
    transition: all 0.15s ease;
  }
  .provider-btn:hover {
    border-color: #38bdf8;
    color: #f1f5f9;
  }
  .provider-btn.active {
    background: rgba(56, 189, 248, 0.15);
    color: #38bdf8;
    border-color: #38bdf8;
    box-shadow: 0 0 0 1px #38bdf8;
  }
  .provider-btn.full-width {
    grid-column: span 2;
  }
  .tag-free {
    background: #10b981;
    color: #064e3b;
    font-size: 0.65rem;
    font-weight: 900;
    padding: 2px 6px;
    border-radius: 6px;
  }

  /* Provider Instructions Card */
  .guide-card {
    background: #0b121e;
    border: 1px solid #1e293b;
    border-radius: 12px;
    padding: 12px 14px;
    margin-bottom: 16px;
  }
  .guide-title {
    font-size: 0.82rem;
    font-weight: 700;
    color: #38bdf8;
    margin-bottom: 6px;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .guide-steps {
    font-size: 0.78rem;
    color: #cbd5e1;
    line-height: 1.5;
    margin-bottom: 8px;
    padding-left: 16px;
  }
  .guide-steps li { margin-bottom: 3px; }
  .btn-get-key {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    background: #1e293b;
    color: #38bdf8;
    border: 1px solid rgba(56, 189, 248, 0.3);
    text-decoration: none;
    font-size: 0.78rem;
    font-weight: 700;
    padding: 6px 12px;
    border-radius: 8px;
    transition: all 0.15s;
  }
  .btn-get-key:hover {
    background: rgba(56, 189, 248, 0.15);
    border-color: #38bdf8;
  }

  /* Form Fields */
  .form-group { margin-bottom: 16px; }
  label {
    display: block;
    font-size: 0.82rem;
    font-weight: 700;
    color: #e2e8f0;
    margin-bottom: 6px;
  }
  .input-wrap {
    position: relative;
    display: flex;
    width: 100%;
  }
  .key-input {
    width: 100%;
    background: #0b121e;
    border: 1.5px solid #223249;
    color: #f8fafc;
    border-radius: 12px;
    padding: 13px 88px 13px 14px; /* Room for embedded paste pill */
    font-size: 16px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    box-sizing: border-box;
    display: block;
    transition: all 0.15s ease;
  }
  .key-input.no-btn {
    padding-right: 14px;
  }
  .key-input:focus {
    outline: none;
    border-color: #38bdf8;
    background: #070c14;
    box-shadow: 0 0 0 2px rgba(56, 189, 248, 0.15);
  }
  .btn-paste-embedded {
    position: absolute;
    right: 8px;
    top: 50%;
    transform: translateY(-50%);
    background: #1e293b;
    color: #38bdf8;
    border: 1px solid rgba(56, 189, 248, 0.35);
    border-radius: 8px;
    padding: 6px 10px;
    font-size: 0.78rem;
    font-weight: 700;
    cursor: pointer;
    white-space: nowrap;
    display: flex;
    align-items: center;
    gap: 4px;
    transition: all 0.15s ease;
  }
  .btn-paste-embedded:hover {
    background: rgba(56, 189, 248, 0.15);
    border-color: #38bdf8;
  }
  .btn-paste-embedded.pasted {
    background: #064e3b;
    color: #34d399;
    border-color: #10b981;
  }

  /* Primary Action Buttons */
  .btn-primary {
    width: 100%;
    background: #38bdf8;
    color: #090d16;
    border: none;
    border-radius: 12px;
    padding: 14px;
    font-size: 1rem;
    font-weight: 800;
    cursor: pointer;
    transition: all 0.15s;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
  }
  .btn-primary:hover { background: #7dd3fc; }
  .btn-primary:disabled {
    background: #1e293b;
    color: #64748b;
    cursor: not-allowed;
  }

  /* Feedback Message */
  #msgBox {
    margin-top: 14px;
    padding: 12px 14px;
    border-radius: 10px;
    font-size: 0.85rem;
    display: none;
    line-height: 1.45;
    font-weight: 600;
  }
  #msgBox.success { background: rgba(16, 185, 129, 0.15); color: #6ee7b7; border: 1px solid #10b981; }
  #msgBox.error { background: rgba(239, 68, 68, 0.15); color: #fca5a5; border: 1px solid #ef4444; }
</style>
</head>
<body>
<div class="card">
  <div class="header">
    <h1>KOReader X-Ray</h1>
    <span class="badge-device">E-Reader Setup</span>
  </div>

  <!-- Encryption and operator trust notice -->
  <div class="security-box">
    <div class="security-header">
      <span>🔒 Encrypted phone-to-reader setup</span>
    </div>
    <div class="security-text">
      Your data is encrypted <strong>in your browser</strong> with the secret in the full QR link. The relay holds encrypted data for up to 10 minutes. Trust the operator of this page: they serve the code that handles what you type. The six-character pairing code alone is not enough; scan the QR link from your reader.
    </div>
  </div>

  <!-- STEP 1: Enter Pairing Code Screen (Shown if no code in URL) -->
  <div id="viewStep1" class="view-step">
    <div class="step1-card">
      <div class="step1-title">Open the Full QR Link</div>
      <p class="step1-desc">
        On your e-reader, go to <strong>API Keys & Providers → Set Key from Phone / PC → Cloud Relay</strong> and scan the QR link. Its private fragment is required; the six-character code alone cannot pair securely.
      </p>

      <div class="code-input-wrap">
        <input
          type="text"
          id="pairingCodeInput"
          class="code-input-single"
          placeholder="CODE"
          maxlength="6"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="characters"
          spellcheck="false"
          autofocus
        >
      </div>

      <button type="button" id="btnContinue" class="btn-primary" onclick="proceedToStep2()">
        <span>Continue →</span>
      </button>
    </div>
  </div>

  <!-- STEP 2: Configure & Send API Key Screen -->
  <div id="viewStep2" class="view-step">
    <div class="paired-status-bar">
      <span class="paired-tag">
        <span>🟢 Paired to E-Reader:</span>
        <strong id="activeSessionCode" style="letter-spacing: 1px;"></strong>
      </span>
      <button type="button" class="change-code-btn" onclick="backToStep1()">Change</button>
    </div>

    <span class="section-label">Select AI Provider</span>
    <div class="provider-grid">
      <button type="button" class="provider-btn active" data-provider="gemini" onclick="selectProvider('gemini')">
        <span>Google Gemini</span>
        <span class="tag-free">FREE</span>
      </button>
      <button type="button" class="provider-btn" data-provider="chatgpt" onclick="selectProvider('chatgpt')">
        <span>OpenAI ChatGPT</span>
      </button>
      <button type="button" class="provider-btn" data-provider="deepseek" onclick="selectProvider('deepseek')">
        <span>DeepSeek</span>
      </button>
      <button type="button" class="provider-btn" data-provider="claude" onclick="selectProvider('claude')">
        <span>Anthropic Claude</span>
      </button>
      <button type="button" class="provider-btn full-width" data-provider="custom1" onclick="selectProvider('custom1')">
        <span>Custom API / OpenRouter / Local LLM</span>
      </button>
    </div>

    <!-- Provider Guide & Direct Links -->
    <div id="guideContent"></div>

    <!-- Key Input Field -->
    <div id="formContent"></div>

    <button type="button" id="submitBtn" class="btn-primary" onclick="submitKey()">
      <span>Send Encrypted Key to E-Reader</span>
    </button>
  </div>

  <div id="msgBox"></div>
</div>

<script>
// State
let currentProvider = 'gemini';
let activeSessionId = '';
let secretKeyHex = '';

// Provider Catalog
const providerDetails = {
  gemini: {
    name: 'Google Gemini',
    guideTitle: 'How to get a Free Google Gemini API Key:',
    steps: [
      'Click the button below to open Google AI Studio in a new tab.',
      'Sign in with your Google account and click <strong>Create API Key</strong>.',
      'Copy your key (starts with <code>AQ.</code> or <code>AIzaSy...</code>) and paste it below.'
    ],
    linkUrl: 'https://aistudio.google.com/app/apikey',
    linkText: '🔑 Open Google AI Studio (Get Free Key) →',
    fields: [
      { id: 'keyInput', label: 'Google Gemini API Key', placeholder: 'AQ.Ab8RN6... or AIzaSy...', hasPaste: true }
    ]
  },
  chatgpt: {
    name: 'OpenAI ChatGPT',
    guideTitle: 'How to get an OpenAI API Key:',
    steps: [
      'Click the button below to open OpenAI Platform.',
      'Sign in and navigate to <strong>API Keys → Create new secret key</strong>.',
      'Copy your key (starts with <code>sk-proj-...</code> or <code>sk-...</code>) and paste it below.'
    ],
    linkUrl: 'https://platform.openai.com/api-keys',
    linkText: '🔑 Open OpenAI Platform API Keys →',
    fields: [
      { id: 'keyInput', label: 'OpenAI API Key', placeholder: 'sk-proj-... or sk-...', hasPaste: true }
    ]
  },
  deepseek: {
    name: 'DeepSeek',
    guideTitle: 'How to get a DeepSeek API Key:',
    steps: [
      'Click the button below to open DeepSeek Platform.',
      'Sign in and create a new API Key in your dashboard.',
      'Copy the key (starts with <code>sk-...</code>) and paste it below.'
    ],
    linkUrl: 'https://platform.deepseek.com/api_keys',
    linkText: '🔑 Open DeepSeek API Dashboard →',
    fields: [
      { id: 'keyInput', label: 'DeepSeek API Key', placeholder: 'sk-...', hasPaste: true }
    ]
  },
  claude: {
    name: 'Anthropic Claude',
    guideTitle: 'How to get an Anthropic Claude API Key:',
    steps: [
      'Click the button below to open Anthropic Console.',
      'Sign in and go to <strong>Settings → API Keys → Create Key</strong>.',
      'Copy the key (starts with <code>sk-ant-...</code>) and paste it below.'
    ],
    linkUrl: 'https://console.anthropic.com/settings/keys',
    linkText: '🔑 Open Anthropic Console →',
    fields: [
      { id: 'keyInput', label: 'Anthropic Claude API Key', placeholder: 'sk-ant-...', hasPaste: true }
    ]
  },
  custom1: {
    name: 'Custom API (OpenRouter / Local LLM)',
    guideTitle: 'Custom OpenAI-Compatible API:',
    steps: [
      'For <strong>OpenRouter</strong>: Get an API key from openrouter.ai/keys.',
      'Enter your API key, endpoint URL, and default model name below.'
    ],
    linkUrl: 'https://openrouter.ai/keys',
    linkText: '🔑 Open OpenRouter Keys Dashboard →',
    fields: [
      { id: 'keyInput', label: 'API Key', placeholder: 'sk-or-... or custom key', hasPaste: true },
      { id: 'endpointInput', label: 'Endpoint URL', placeholder: 'https://openrouter.ai/api/v1/chat/completions', def: 'https://openrouter.ai/api/v1/chat/completions' },
      { id: 'modelInput', label: 'Default Model', placeholder: 'google/gemini-2.5-flash', def: 'google/gemini-2.5-flash' }
    ]
  }
};

// Initialization
window.addEventListener('DOMContentLoaded', function() {
  const params = new URLSearchParams(window.location.search);
  const paramCode = (params.get('s') || '').trim().toUpperCase();
  secretKeyHex = (window.location.hash || '').replace(/^#/, '').trim();

  if (!hasValidSecret()) {
    showStep(1);
    document.getElementById('pairingCodeInput').disabled = true;
    document.getElementById('btnContinue').disabled = true;
    showMsg('Scan the full QR link from your reader before entering any key or code. The pairing code alone is not enough.', 'error');
    return;
  }

  // Allow pressing Enter in the Step 1 code box
  const codeInput = document.getElementById('pairingCodeInput');
  if (codeInput) {
    codeInput.addEventListener('keypress', function(e) {
      if (e.key === 'Enter') {
        proceedToStep2();
      }
    });
  }

  if (/^[A-Z0-9]{6}$/.test(paramCode)) {
    activeSessionId = paramCode;
    showStep(2);
  } else {
    showStep(1);
  }
});

function hasValidSecret() {
  return /^[0-9a-fA-F]{64}$/.test(secretKeyHex);
}

function showStep(stepNum) {
  if (stepNum === 2 && !hasValidSecret()) return;
  document.getElementById('viewStep1').classList.remove('active');
  document.getElementById('viewStep2').classList.remove('active');
  hideMsg();

  if (stepNum === 1) {
    document.getElementById('viewStep1').classList.add('active');
    const input = document.getElementById('pairingCodeInput');
    if (input) {
      input.value = activeSessionId;
      setTimeout(function() { input.focus(); }, 50);
    }
  } else {
    document.getElementById('viewStep2').classList.add('active');
    document.getElementById('activeSessionCode').textContent = activeSessionId;
    renderProviderUI(currentProvider);
  }
}

function proceedToStep2() {
  if (!hasValidSecret()) {
    showMsg('Scan the full QR link from your reader first.', 'error');
    return;
  }
  const input = document.getElementById('pairingCodeInput');
  const code = (input ? input.value : '').trim().toUpperCase();
  if (!/^[A-Z0-9]{6}$/.test(code)) {
    showMsg('Please enter the 6-character code from your e-reader.', 'error');
    if (input) input.focus();
    return;
  }
  activeSessionId = code;
  showStep(2);
}

function backToStep1() {
  showStep(1);
}

function selectProvider(provider) {
  currentProvider = provider;
  document.querySelectorAll('.provider-btn').forEach(function(b) {
    if (b.getAttribute('data-provider') === provider) {
      b.classList.add('active');
    } else {
      b.classList.remove('active');
    }
  });
  renderProviderUI(provider);
}

function renderProviderUI(provider) {
  const p = providerDetails[provider];
  if (!p) return;

  // 1. Render Instructions Guide
  let guideHtml = '<div class="guide-card">';
  guideHtml += '<div class="guide-title">ℹ️ ' + p.guideTitle + '</div>';
  guideHtml += '<ol class="guide-steps">';
  p.steps.forEach(function(s) {
    guideHtml += '<li>' + s + '</li>';
  });
  guideHtml += '</ol>';
  guideHtml += '<a href="' + p.linkUrl + '" target="_blank" rel="noopener noreferrer" class="btn-get-key">' + p.linkText + '</a>';
  guideHtml += '</div>';
  document.getElementById('guideContent').innerHTML = guideHtml;

  // 2. Render Form Inputs with Integrated Clipboard Button
  let formHtml = '';
  p.fields.forEach(function(f) {
    formHtml += '<div class="form-group">';
    formHtml += '<label for="' + f.id + '">' + f.label + '</label>';
    formHtml += '<div class="input-wrap">';
    const inputClass = f.hasPaste ? 'key-input' : 'key-input no-btn';
    formHtml += '<input type="text" id="' + f.id + '" class="' + inputClass + '" placeholder="' + f.placeholder + '" value="' + (f.def || '') + '" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">';
    if (f.hasPaste) {
      formHtml += '<button type="button" id="pasteBtn" class="btn-paste-embedded" onclick="pasteKey()">📋 Paste</button>';
    }
    formHtml += '</div>';
    formHtml += '</div>';
  });
  document.getElementById('formContent').innerHTML = formHtml;

  // Auto-focus key input and attach Enter key listener
  const keyEl = document.getElementById('keyInput');
  if (keyEl) {
    keyEl.addEventListener('keypress', function(e) {
      if (e.key === 'Enter') {
        submitKey();
      }
    });
    setTimeout(function() { keyEl.focus(); }, 60);
  }
}

// Browser Clipboard API Integration with graceful feedback
async function pasteKey() {
  const el = document.getElementById('keyInput');
  const btn = document.getElementById('pasteBtn');
  if (!el) return;

  if (navigator.clipboard && navigator.clipboard.readText) {
    try {
      const text = await navigator.clipboard.readText();
      if (text && text.trim()) {
        el.value = text.trim();
        el.focus();
        if (btn) {
          btn.innerHTML = '✓ Pasted';
          btn.classList.add('pasted');
          setTimeout(function() {
            btn.innerHTML = '📋 Paste';
            btn.classList.remove('pasted');
          }, 1500);
        }
        return;
      }
    } catch (err) {
      // Permission blocked or dismissed
    }
  }

  el.focus();
}

// Convert Hex string to Uint8Array
function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  }
  return bytes;
}

// ArrayBuffer to Base64
function bufferToBase64(buffer) {
  let binary = '';
  const bytes = new Uint8Array(buffer);
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return window.btoa(binary);
}

// Existing HMAC-SHA256 stream + tag format, preserved for KOReader compatibility
async function encryptPayload(dataObj, hexSecret) {
  const plaintext = JSON.stringify(dataObj);
  const enc = new TextEncoder();
  const rawData = enc.encode(plaintext);
  if (rawData.length > 4096) {
    throw new Error('Payload is too large for the reader (4096 bytes maximum).');
  }

  if (typeof hexSecret !== 'string' || !/^[0-9a-fA-F]{64}$/.test(hexSecret)) {
    throw new Error('Missing or invalid secret. Scan the full QR link from your reader; the pairing code alone is not enough.');
  }
  const keyBytes = hexToBytes(hexSecret);

  const hmacKey = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );

  const iv = crypto.getRandomValues(new Uint8Array(16));
  
  // Generate HMAC keystream
  const keystream = [];
  let counter = 0;
  while (keystream.length < rawData.length) {
    const counterBuf = new Uint8Array(20);
    counterBuf.set(iv, 0);
    const view = new DataView(counterBuf.buffer);
    view.setUint32(16, counter, false); // big-endian
    const block = await crypto.subtle.sign('HMAC', hmacKey, counterBuf);
    const blockBytes = new Uint8Array(block);
    for (let i = 0; i < blockBytes.length && keystream.length < rawData.length; i++) {
      keystream.push(blockBytes[i]);
    }
    counter++;
  }

  const ciphertext = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; i++) {
    ciphertext[i] = rawData[i] ^ keystream[i];
  }

  // Compute 16-byte authentication tag over "AUTH" + iv + ciphertext
  const authPrefix = enc.encode("AUTH");
  const authData = new Uint8Array(authPrefix.length + iv.length + ciphertext.length);
  authData.set(authPrefix, 0);
  authData.set(iv, authPrefix.length);
  authData.set(ciphertext, authPrefix.length + iv.length);

  const tagSig = await crypto.subtle.sign('HMAC', hmacKey, authData);
  const tag16 = new Uint8Array(tagSig).slice(0, 16);

  // Combined: [16 bytes IV] + [16 bytes Tag] + [Ciphertext]
  const combined = new Uint8Array(iv.length + tag16.length + ciphertext.length);
  combined.set(iv, 0);
  combined.set(tag16, iv.length);
  combined.set(ciphertext, iv.length + tag16.length);

  return 'HMAC:' + bufferToBase64(combined.buffer);
}

async function submitKey() {
  if (!hasValidSecret()) {
    showMsg('Scan the full QR link from your reader first.', 'error');
    return;
  }
  if (!activeSessionId) {
    showMsg('Missing pairing session. Please enter your code.', 'error');
    showStep(1);
    return;
  }

  const keyInput = document.getElementById('keyInput');
  const apiKey = keyInput ? keyInput.value.trim() : '';

  if (!apiKey) {
    showMsg('Please enter or paste your API key.', 'error');
    if (keyInput) keyInput.focus();
    return;
  }

  const payload = {
    provider: currentProvider,
    api_key: apiKey,
    timestamp: Date.now()
  };

  if (currentProvider === 'custom1') {
    payload.endpoint = (document.getElementById('endpointInput') || {}).value || '';
    payload.model = (document.getElementById('modelInput') || {}).value || '';
  }

  const btn = document.getElementById('submitBtn');
  btn.disabled = true;
  btn.textContent = 'Encrypting & Sending...';

  try {
    const encryptedPayload = await encryptPayload(payload, secretKeyHex);

    const res = await fetch('/api/session/' + encodeURIComponent(activeSessionId) + '/submit', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ encrypted_payload: encryptedPayload })
    });

    const data = await res.json();
    if (res.ok && data.success) {
      showMsg('✓ API key encrypted and sent successfully! Check your e-reader screen.', 'success');
      btn.textContent = '✓ Sent to E-Reader!';
    } else {
      showMsg(data.error || 'Failed to submit key to session.', 'error');
      btn.disabled = false;
      btn.textContent = 'Send Encrypted Key to E-Reader';
    }
  } catch (err) {
    showMsg('Network error: ' + err.message, 'error');
    btn.disabled = false;
    btn.textContent = 'Send Encrypted Key to E-Reader';
  }
}

function showMsg(text, type) {
  const box = document.getElementById('msgBox');
  box.className = type;
  box.textContent = text;
  box.style.display = 'block';
}

function hideMsg() {
  const box = document.getElementById('msgBox');
  if (box) box.style.display = 'none';
}
</script>
</body>
</html>
`;
