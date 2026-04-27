---
title: 'klikit Partner API'
description: 'Receive orders, sync menus, and manage availability across every delivery provider — through one documented contract.'
---

# klikit Partner API

> **Audience:** External partners — POS systems, ERP/accounting, inventory tools, white-label storefronts.
> **Status:** v1.0 — accepting design partners.

---

## What is this?

klikit aggregates orders for restaurants across every major delivery platform — GrabFood, Uber Eats, Foodpanda, GoFood, ShopeeFood, Wolt, Deliveroo, and more — plus webshop, dine-in, and scan-to-order channels. The Partner API gives you one contract to:

- **Receive every order** in real-time, regardless of which channel it came from
- **Drive order status** (accept, reject, mark ready, mark picked up, cancel)
- **Sync availability** — push out-of-stock, snooze items, restock — and have it propagate to every aggregator automatically
- **Map your catalogue** to klikit's so your own SKUs work for stock signals
- **Push your master menu** into klikit (for partners who own the catalogue)

One credential pair, one webhook subscription, one canonical schema.

---

## Who uses each capability

| You are a... | You'll use |
|---|---|
| **POS** | Order webhooks + status callbacks + Menu Mapping + Stock Sync |
| **ERP / accounting** | Order webhooks (`order.delivered`) + read-only order queries |
| **Inventory system** | Menu Mapping + Stock Sync only |
| **White-label storefront** | Menu Push + Order webhooks |

Capabilities are gated by OAuth2 scopes — you only get what your integration needs.

---

## Capability Matrix

| Capability | Direction | Scope | Reference |
|---|---|---|---|
| Order webhooks (`order.placed`, `updated`, `cancelled`, `amended`) | klikit → partner | Subscribed event | [Orders](./orders.md) |
| Order status callback (accept, reject, ready, picked-up, cancel) | partner → klikit | `orders:write` | [Orders](./orders.md) |
| Order read (single + list) | partner → klikit | `orders:read` | [Orders](./orders.md) |
| Cancel reasons enum | partner → klikit | `orders:read` | [Orders](./orders.md) |
| Menu Mapping (lookup + upsert items, categories, modifier groups) | partner → klikit | `mapping:write` | [Menus](./menus.md) |
| Stock Sync (single + bulk) | partner → klikit | `stock:write` | [Menus](./menus.md) |
| Menu Push (full tree, async) | partner → klikit | `menus:write` | [Menus](./menus.md) |
| Menu Read (canonical klikit menu) | partner → klikit | `menus:read` | [Menus](./menus.md) |

---

## Quick Start

1. **Request credentials.** klikit issues a `client_id` + `client_secret` per partner per business.
2. **Exchange for a token.** `POST /v1/partner/oauth/token` with grant `client_credentials` → returns a short-lived `access_token`.
3. **Register your webhook URL.** Provide an HTTPS endpoint that klikit will POST events to, plus your HMAC verification secret.
4. **Receive a test order.** klikit fires an `order.placed` test event from a sandbox business; you confirm HMAC verification + `2xx` response.
5. **Push menu mapping.** `POST /v1/partner/menus/items/mappings` with your SKUs against klikit item IDs (use `GET /v1/partner/menus` to discover them). Once mapped, stock calls work using your own SKUs.

Detailed onboarding sequence in [Authentication](./authentication.md).

---

## Documents

| Doc | Contents |
|---|---|
| [Authentication](./authentication.md) | OAuth2 client credentials, HMAC webhook signing, idempotency, rate limits, key rotation |
| [Orders](./orders.md) | Order schema, lifecycle, outbound webhooks, status callback API |
| [Menus](./menus.md) | Menu Mapping, Stock Sync, Menu Push, async job model |
| [OpenAPI: Auth](./openapi/auth.yaml) | Machine-readable spec |
| [OpenAPI: Orders](./openapi/orders.yaml) | Machine-readable spec |
| [OpenAPI: Menus](./openapi/menus.yaml) | Machine-readable spec |

---

## Out of Scope (v1)

| Capability | Reason |
|---|---|
| Live modification of in-flight aggregator orders | Aggregator platforms do not support API-driven in-flight edits. Use cancel + re-create. |
| Payment processing / refunds | Separate contract — contact your klikit account manager. |
| Customer PII bulk export | Privacy/compliance — PII is surfaced only on a per-order basis. |
| Multi-business partner credentials (one token across multiple businesses) | Tracked for a future release. For v1, request one credential pair per business. |
| Inbound order creation from partner (POS-originated dine-in into klikit's order management) | Out of scope for v1. |

---

## Support

- **Onboarding & credentials:** {{ TBD — partner ops contact }}
- **Technical questions:** {{ TBD — developer support email or portal }}
- **Status page:** {{ TBD — status.klikit.io or equivalent }}
