---
title: 'Authentication'
description: 'OAuth2 client credentials, HMAC webhook signing, idempotency, rate limits, and key rotation.'
---

# Authentication & Webhook Security

Covers credential issuance, OAuth2 client credentials flow, HMAC webhook signing, idempotency, retry, and rate limits.

---

## TL;DR

- **Partner → klikit:** OAuth2 `client_credentials` grant. Short-lived access tokens (1h). Bearer auth on every request.
- **klikit → partner:** HMAC-SHA256 signed webhooks. Verify the signature before trusting the body.
- **Idempotency:** every outbound event has a stable `event_id`. Every partner write should include an `Idempotency-Key`.
- **Scopes:** least-privilege per capability bundle. POS gets all; ERP gets read-only orders.

---

## 1. Credential Model

A klikit partner is uniquely identified by a `(partner_id, business_id)` pair. One legal partner integrating with multiple businesses gets multiple credential pairs (one per business).

Each credential pair has:

| Field | Purpose |
|---|---|
| `client_id` | Public identifier. Sent in token requests. |
| `client_secret` | Confidential. Used in token requests. Rotatable. |
| `webhook_url` | Your HTTPS endpoint where klikit POSTs events. |
| `webhook_secret` | Your HMAC verification secret. Rotatable. Distinct from `client_secret`. |
| `scopes` | Subset of capability scopes (see §3). |
| `business_id` | The single klikit business this credential is scoped to. |

Credentials are issued by the klikit Partner Operations team during onboarding.

---

## 2. OAuth2 Client Credentials Flow

### Token request

```http
POST /v1/partner/oauth/token HTTP/1.1
Host: {{ TBD — production host }}
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=<client_id>
&client_secret=<client_secret>
&scope=orders:read orders:write menus:read mapping:write stock:write
```

### Token response

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "orders:read orders:write menus:read mapping:write stock:write"
}
```

### Using the token

```http
GET /v1/partner/orders/12345 HTTP/1.1
Host: {{ TBD — production host }}
Authorization: Bearer <access_token>
```

### Refresh strategy

There is **no refresh token** in client credentials flow. Re-request a token when the current one nears expiry. Recommended: refresh at `expires_in - 5min`.

### Errors

| Status | `error` | When |
|---|---|---|
| 400 | `invalid_request` | Missing `grant_type` / `client_id` / `client_secret` |
| 401 | `invalid_client` | Wrong `client_id` or `client_secret` |
| 400 | `invalid_scope` | Requested scope not granted to this credential |
| 429 | `rate_limit_exceeded` | More than 60 token requests/min per `client_id` |

---

## 3. Scopes

Least-privilege scopes. Your credential is issued with the subset your integration needs.

| Scope | Grants |
|---|---|
| `orders:read` | `GET /v1/partner/orders`, `GET /v1/partner/orders/{id}`, `GET /v1/partner/orders/cancel-reasons` |
| `orders:write` | `PATCH /v1/partner/orders/{id}/status` (accept, reject, ready, picked-up, cancel) |
| `menus:read` | `GET /v1/partner/menus`, `GET /v1/partner/menus/items`, `GET /v1/partner/menus/jobs/{id}` |
| `menus:write` | `POST /v1/partner/menus` (Menu Push), `POST /v1/partner/menus/publish` |
| `mapping:write` | `POST /v1/partner/menus/items/mappings`, `POST /v1/partner/menus/categories/mappings`, `POST /v1/partner/menus/modifier-groups/mappings`, `POST /v1/partner/menus/mappings/lookup` |
| `stock:write` | `PATCH /v1/partner/menus/stock/{partner_item_id}`, bulk variant |

**Webhook subscriptions** are configured per-credential at issuance and are not scope-gated; klikit only fires events you have subscribed to.

---

## 4. Outbound Webhook Signing (HMAC)

Every outbound webhook from klikit carries:

| Header | Purpose |
|---|---|
| `X-Klikit-Signature` | HMAC signature: `t=<unix_ts>,v1=<hex hmac-sha256>` |
| `X-Klikit-Event` | Event type, e.g. `order.placed` |
| `X-Klikit-Event-Id` | Stable UUID — use for idempotent processing on your side |
| `X-Klikit-Webhook-Id` | The klikit webhook subscription id (helps if you have multiple subscriptions) |
| `Content-Type` | `application/json` |

### Verification

The signed payload is `<unix_ts>.<raw_request_body>`. Compute HMAC-SHA256 with your `webhook_secret` and verify:

```python
# Python example
import hmac, hashlib, time

def verify(headers, raw_body, secret):
    sig_header = headers["X-Klikit-Signature"]
    parts = dict(p.split("=") for p in sig_header.split(","))
    ts = parts["t"]
    received = parts["v1"]

    # Reject replays older than 5 minutes
    if abs(time.time() - int(ts)) > 300:
        return False

    expected = hmac.new(
        secret.encode(),
        f"{ts}.{raw_body}".encode(),
        hashlib.sha256,
    ).hexdigest()

    return hmac.compare_digest(expected, received)
```

### Replay protection

- The timestamp `t` is included in the signed payload — replay attempts with a stale `t` will fail.
- You **must** reject events with `t` older than 5 minutes.
- You **must** deduplicate by `X-Klikit-Event-Id` to handle retries.

---

## 5. Webhook Retry Policy

| Aspect | Behaviour |
|---|---|
| Acceptance | Your endpoint must respond `2xx` within **10 seconds**. Any other response = retry. |
| Retry schedule | Exponential backoff: 30s, 2m, 10m, 1h, 6h, 24h. Six attempts total. |
| Give-up | After final attempt fails → event lands in dead-letter queue. You will be notified by email. |
| Manual replay | You can request replay of dead-lettered events via klikit support. |
| Ordering | **Not guaranteed.** Do not rely on event order; rely on `created_at` and `event_id`. |

---

## 6. Idempotency (Partner → klikit)

All non-idempotent partner writes (`POST`, `PATCH`) **should** include:

```http
Idempotency-Key: <UUID v4 chosen by you>
```

klikit caches the response for 24h. A retry with the same key returns the original response without re-executing the action.

If you reuse an `Idempotency-Key` with a *different* request body, klikit returns `409 Conflict`.

---

## 7. Rate Limits

Per-credential, per-endpoint-class:

| Class | Limit |
|---|---|
| Token issuance (`/oauth/token`) | 60 req/min |
| Reads (`GET`) | 600 req/min |
| Writes (`POST`, `PATCH`) | 300 req/min |
| Bulk writes (`/bulk` suffix) | 60 req/min |

Exceeding the limit returns `429 Too Many Requests` with:

```http
Retry-After: <seconds>
X-RateLimit-Limit: 600
X-RateLimit-Remaining: 0
X-RateLimit-Reset: <unix_ts>
```

---

## 8. Key Rotation

Both `client_secret` and `webhook_secret` are rotatable independently.

- Request rotation via klikit support (a self-service partner dashboard is on the roadmap).
- During rotation, both old and new secrets are valid for **24 hours** to allow your systems to roll over. After 24h the old secret is revoked.
- Webhook signature verification accepts a signature computed with **either** the old or new `webhook_secret` during the overlap window.

---

## 9. Onboarding Sequence

```
1. Sign partner agreement with klikit Partner Operations.
2. klikit issues credentials for your business:
     -> client_id, client_secret, webhook_secret
3. Register your webhook URL with klikit Partner Operations.
4. Subscribe to the events you want to receive.
5. Exchange client_credentials for a token (smoke test).
6. klikit fires a sandbox order; you verify HMAC + 200 OK.
7. Push initial menu mapping (POS) or full menu (white-label).
8. Live cutover: business is enabled for production order flow.
```
