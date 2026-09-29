# TypeSafe Jev (optional decision helper)

X-Ray can optionally ask [TypeSafe](https://docs.typesafe.ai) Jev for two
narrow, structured judgments. It is **off by default** and never replaces your
generative AI provider.

## What it does

- **Book type**: before the existing AI book-type refinement, Jev picks one of
  X-Ray's book types from title/author/series/description metadata, or
  `uncertain`. X-Ray only uses the answer when the chosen type has probability
  >= 0.8 and confidence >= 0.7. Otherwise (uncertain, low confidence, error,
  malformed reply) the existing generative request runs as before, in the same
  cancellable background request.
- **Duplicate suggestions**: after the existing AI finds candidate duplicate
  pairs, Jev scores each pair (different / maybe / same) using names, aliases
  and descriptions. The review dialog shows a line such as
  `TypeSafe Jev: likely same (confidence 87%). You decide.`
  Nothing is merged, hidden, filtered or reordered. Up to 36 pairs are sent
  (3 requests of 12); any other pair, or any pair in a failed request, is shown
  as `not assessed`.

Confidence describes how concentrated Jev's answer is, not whether it is
correct. The API guarantees answer types, not accuracy. The thresholds above
are conservative heuristics, not calibrated or validated for books or
literary name matching.

## Privacy and billing

Turning this on sends book metadata (title, author, series, description) and
candidate entity names, aliases and short descriptions to TypeSafe, a third
party. TypeSafe usage is billed to your TypeSafe account, in addition to your
normal AI provider.

## Setup

Menu: API keys > **TypeSafe Jev (optional decisions)**.

1. **Enter key** (paste) or **Send key from phone** (QR code). The phone option
   reuses the encrypted X-Ray transfer page. Ignore its provider buttons: the
   text you send is only ever saved as the TypeSafe key.
2. Tap **Turn on TypeSafe Jev**. Saving a key does not turn it on.

**Remove key** deletes the key and turns it off. "Clear All API Keys" also
removes it. The TypeSafe key never counts as a generative provider key.

## Technical notes

- Endpoint `https://api.typesafe.ai/v1/systemone`, pinned model `jev-1.13.0`
  (not the moving `jev-latest` alias). Replies from any other model version are
  rejected.
- Transport is X-Ray's verified SecureHTTP (CA and hostname checked, no
  redirects, exact host allowlist), 20 s deadline per request, 48 KB request
  cap, 256 KB reply cap.
- Every answer is validated: expected question ids and types, options within
  the defined set, finite probabilities in [0,1] summing to 1, choice equal to
  the most likely option, score consistent with its level probabilities.
- Keys, request bodies and reply bodies are never logged or shown.
