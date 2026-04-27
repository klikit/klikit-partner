---
title: 'Menus'
description: 'Menu Mapping (POS-critical), Stock Sync, and Menu Push.'
---

# Menus

Menu Mapping (the critical POS use case), Stock Sync (out-of-stock / availability), and Menu Push.

---

## TL;DR

- **Menu Mapping** is the critical POS capability: it lets you say "this thing in your menu is the same as this thing in mine" — without it, you cannot push out-of-stock signals tied to your own SKUs.
- **Stock Sync** is the highest-frequency partner write — single + bulk endpoints, async propagation to delivery providers.
- **Menu Push** is for partners who own the master menu (POS or white-label) — full tree, async job, status polling.
- **Menu Read** lets you discover klikit's canonical structure to map against.

---

## Concept Model

klikit's menu hierarchy is **4 levels**, top-down:

```
Section (e.g. "Lunch", "Dinner")           ← time-of-day / availability scoping
  └─ Category (e.g. "Burgers", "Drinks")   ← presentation grouping
      └─ Item (e.g. "Classic Cheeseburger")  ← the orderable thing, with SKU + price
          └─ Modifier Group (e.g. "Cheese")   ← required/optional choice container
              └─ Modifier (e.g. "Extra cheddar +$1")  ← individual option
```

If your model is flatter, the contract supports flattening:

| You have | Map to klikit as |
|---|---|
| Just items + categories (no sections) | One default Section "All Day" containing all categories |
| Items only, no categories | One default Section, one default Category "Menu" |
| Items + addon-list (no group concept) | One Modifier Group per item with all addons inside |

`POST /v1/partner/menus` (Menu Push) accepts these flattened shapes — see §3.

---

## 1. Menu Mapping

A POS partner does not know that klikit calls their burger `item_id: 12345`. You only know your own `POS-SKU-998`. Without a registered mapping, you cannot:
- Push OOS for a klikit item using your own SKU
- Recognise items on incoming orders (the order's `partner_item_id` will be `null`)

Mappings are **per-business** and exist for three node types: items, categories, modifier groups. (Modifiers themselves inherit from their group's mapping.)

### 1.1 Discover klikit menu (read first, then map)

```http
GET /v1/partner/menus?branch_id=100&brand_id=10
Authorization: Bearer <token>
```

Returns the full canonical menu tree for that store. Use this to build a local cache, then fuzzy-match your SKUs to klikit IDs (or — preferably — let your admin pick from a dropdown).

### 1.2 Bulk lookup by partner ID

```http
POST /v1/partner/menus/mappings/lookup
Authorization: Bearer <token>
Content-Type: application/json

{
  "type": "item",
  "partner_ids": ["POS-SKU-998", "POS-SKU-999", "POS-SKU-1000"]
}
```

Response:

```json
{
  "data": {
    "POS-SKU-998":  { "klikit_id": 12345, "name": "Classic Cheeseburger", "sku": "BURGER-CLASSIC" },
    "POS-SKU-999":  { "klikit_id": 12350, "name": "Veggie Burger",        "sku": "BURGER-VEGGIE" },
    "POS-SKU-1000": null
  }
}
```

`null` = unmapped. Use this before any stock call to confirm coverage.

### 1.3 Bulk upsert mappings

```http
POST /v1/partner/menus/items/mappings
Authorization: Bearer <token>
Idempotency-Key: <uuid>
Content-Type: application/json

{
  "branch_id": 100,
  "mappings": [
    { "klikit_id": 12345, "partner_id": "POS-SKU-998",  "partner_sku": "BURGER-CLASSIC", "partner_name": "Classic Burger" },
    { "klikit_id": 12350, "partner_id": "POS-SKU-999",  "partner_sku": "BURGER-VEGGIE",  "partner_name": "Veggie Burger" }
  ]
}
```

Response:

```json
{
  "applied": 2,
  "skipped": 0,
  "errors": []
}
```

Errors are returned per-row (e.g. `klikit_id` not found in this branch, partner_id duplicate within the request).

### 1.4 Categories and modifier groups

Same shape, different paths:

| Node | Endpoint |
|---|---|
| Item | `POST /v1/partner/menus/items/mappings` |
| Category | `POST /v1/partner/menus/categories/mappings` |
| Modifier group | `POST /v1/partner/menus/modifier-groups/mappings` |

### 1.5 Lifecycle

- Mappings are **upsert** — sending a mapping for a `(business_id, klikit_id)` pair overwrites any prior `partner_id` for the same partner credential.
- Mappings are **per credential** — two different partners can map the same klikit item to different `partner_id` values without conflict.
- Removing a mapping: `DELETE /v1/partner/menus/items/mappings` body `{ "klikit_ids": [12345] }`.
- When a klikit item is deleted, mappings against it are auto-cleaned and a `mapping.invalidated` webhook fires (subscription `mapping.invalidated`).

---

## 2. Stock Sync

The high-frequency endpoint. Use your own ID — klikit resolves via the mapping registered in §1.

### 2.1 Single item

```http
PATCH /v1/partner/menus/stock/{partner_item_id}
Authorization: Bearer <token>
Idempotency-Key: <uuid>
Content-Type: application/json

{
  "branch_id": 100,
  "is_enabled": false,
  "stock_quantity": 0,
  "snooze_duration_seconds": 3600,
  "snooze_until_turn_back": false
}
```

| Field | Notes |
|---|---|
| `branch_id` | Required — stock is per-store. |
| `is_enabled` | `false` = hard disable (stays off until re-enabled). `true` = enabled / available. |
| `stock_quantity` | Optional integer. `0` triggers OOS even if `is_enabled: true`. Omit if you don't track unit counts. |
| `snooze_duration_seconds` | Soft OOS for N seconds, then auto-restore. Mutually exclusive with `snooze_until_turn_back: true`. |
| `snooze_until_turn_back` | Soft OOS until you re-enable. Equivalent to indefinite snooze. |

**Use the right knob:**

| Intent | Set |
|---|---|
| Sold out for the day; comes back tomorrow | `snooze_until_turn_back: true` |
| Sold out for the next hour | `snooze_duration_seconds: 3600` |
| Sold out *right now*, kitchen will toggle back manually when restocked | `is_enabled: false` |
| Restock complete | `is_enabled: true`, omit snooze fields |
| 47 left in stock today | `stock_quantity: 47, is_enabled: true` (klikit auto-marks OOS at 0) |

### 2.2 Bulk (kitchen batches)

```http
PATCH /v1/partner/menus/stock/bulk
Authorization: Bearer <token>
Idempotency-Key: <uuid>
Content-Type: application/json

{
  "branch_id": 100,
  "updates": [
    { "partner_item_id": "POS-SKU-998", "is_enabled": false, "snooze_until_turn_back": true },
    { "partner_item_id": "POS-SKU-999", "is_enabled": true },
    { "partner_item_id": "POS-SKU-1000", "stock_quantity": 5 }
  ]
}
```

Up to 500 updates per request. Response is per-row pass/fail.

### 2.3 Propagation latency

A stock update is acknowledged synchronously (item is OOS in klikit immediately), but propagation to delivery providers is **asynchronous**. Typical end-to-end latency:

| Provider | Typical | P95 |
|---|---|---|
| klikit (direct webshop) | `<1s` | `<2s` |
| GrabFood | 5-15s | 60s |
| Uber Eats | 10-30s | 90s |
| Foodpanda | 5-15s | 60s |
| GoFood | 10-30s | 90s |
| ShopeeFood | 10-30s | 60s |

If you need sub-5s propagation guarantees, contact klikit support — current SLAs are best-effort.

### 2.4 Webhook (optional)

If subscribed to `stock.synced`, klikit fires when propagation completes per provider:

```json
{
  "event_type": "stock.synced",
  "data": {
    "branch_id": 100,
    "klikit_item_id": 12345,
    "partner_item_id": "POS-SKU-998",
    "providers": [
      { "provider_id": 6, "name": "grabfood",  "status": "synced",  "synced_at": "2026-04-27T10:14:42Z" },
      { "provider_id": 2, "name": "uber_eats", "status": "failed",  "error": "rate_limited" }
    ]
  }
}
```

---

## 3. Menu Push

For partners that own the master menu (typically white-label storefronts and PMS-backed POS systems). klikit becomes a downstream consumer: you push your canonical menu and klikit handles aggregator transformations.

### 3.1 Push the menu

```http
POST /v1/partner/menus
Authorization: Bearer <token>
Idempotency-Key: <uuid>
Content-Type: application/json

{
  "branch_id": 100,
  "brand_id": 10,
  "currency": "THB",
  "sections": [
    {
      "partner_section_id": "SEC-1",
      "title": { "en": "All Day" },
      "available_times": [{ "day": "all", "start": "00:00", "end": "23:59" }],
      "categories": [
        {
          "partner_category_id": "CAT-1",
          "title": { "en": "Burgers" },
          "items": [
            {
              "partner_item_id": "POS-SKU-998",
              "sku": "BURGER-CLASSIC",
              "title":       { "en": "Classic Cheeseburger" },
              "description": { "en": "Beef patty, cheddar, lettuce, tomato" },
              "image_url": "https://cdn.partner.example/burger.jpg",
              "prices": {
                "default": 199.00,
                "by_provider": { "grabfood": 219.00, "uber_eats": 219.00 }
              },
              "vat_rate": 0.07,
              "is_enabled": true,
              "modifier_groups": [
                {
                  "partner_modifier_group_id": "MG-CHEESE",
                  "title": { "en": "Cheese options" },
                  "min_select": 0,
                  "max_select": 2,
                  "modifiers": [
                    {
                      "partner_modifier_id": "MOD-CHEDDAR",
                      "title": { "en": "Extra cheddar" },
                      "price": 30.00,
                      "is_enabled": true
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

### Schema notes

| Field | Notes |
|---|---|
| `title` / `description` | Map of locale codes (`en`, `th`, `ja`, `id`, …) to strings. At least one locale is required. |
| `partner_*_id` | Stable IDs you control. klikit registers these as mappings automatically — no separate Mapping call needed. |
| `prices.default` | Used when no provider-specific override exists. |
| `prices.by_provider` | Override per delivery provider. Provider names must come from `GET /v1/partner/providers`. |
| `available_times[].day` | `0`-`6` (Mon-Sun), or `"all"`. |
| `min_select` / `max_select` | Modifier group selection bounds. `min_select: 1` = required group. |
| `is_enabled` | Default availability; OOS/stock is managed via §2 endpoints, not Menu Push. |

### Flattened input

If you have no concept of sections, omit them — klikit synthesises a default `"All Day"` section. Same for categories.

```jsonc
{
  "branch_id": 100,
  "currency": "THB",
  "items": [ /* flat list — klikit infers section/category */ ]
}
```

### 3.2 Async job model

`POST /v1/partner/menus` returns immediately:

```http
202 Accepted

{
  "job_id": "job_01HX7K4J4M9V2P0Q5T8Z3W6Y1B",
  "status": "pending",
  "submitted_at": "2026-04-27T10:14:20Z"
}
```

Poll for status:

```http
GET /v1/partner/menus/jobs/{job_id}
Authorization: Bearer <token>
```

```json
{
  "job_id": "job_01HX7K4J4M9V2P0Q5T8Z3W6Y1B",
  "status": "in_progress",
  "submitted_at": "2026-04-27T10:14:20Z",
  "started_at":   "2026-04-27T10:14:21Z",
  "completed_at": null,
  "progress": {
    "stages": [
      { "name": "validation",        "status": "completed", "duration_ms": 320 },
      { "name": "klikit_persistence","status": "completed", "duration_ms": 1240 },
      { "name": "aggregator_sync",   "status": "in_progress", "providers": [
        { "provider_id": 6, "name": "grabfood",  "status": "completed" },
        { "provider_id": 2, "name": "uber_eats", "status": "in_progress" }
      ]}
    ]
  },
  "errors": []
}
```

### Job statuses

| Status | Meaning |
|---|---|
| `pending` | Queued, not yet started |
| `in_progress` | Validation/persistence/sync running |
| `completed` | All stages succeeded |
| `partial_success` | klikit persistence succeeded, but at least one provider sync failed |
| `failed` | Validation or persistence failed; fix and resubmit |

Optional: subscribe to `menu.job.completed` webhook to skip polling.

### 3.3 Validation rules

Validation runs before any persistence. Common errors:

| Error | Cause |
|---|---|
| `validation.missing_currency` | `currency` not provided |
| `validation.unknown_provider` | `prices.by_provider` references an unknown provider name |
| `validation.duplicate_partner_id` | Same `partner_item_id` appears twice in the payload |
| `validation.modifier_group_bounds` | `min_select > max_select`, or `max_select` exceeds modifier count |
| `validation.no_locale` | `title` / `description` map is empty |
| `validation.invalid_locale` | Locale code not in supported set |
| `validation.image_unreachable` | `image_url` returns non-2xx or non-image content-type |

The full payload is rejected on any validation error — Menu Push is all-or-nothing for v1.

### 3.4 Publishing to delivery providers

After successful klikit persistence, the menu is in **DRAFT**. To push to providers:

```http
POST /v1/partner/menus/publish
Authorization: Bearer <token>
Content-Type: application/json

{
  "branch_id": 100,
  "provider_ids": [6, 2]
}
```

`provider_ids` empty/omitted = publish to all providers configured for the store. Returns a separate job. Each provider's publish state surfaces via the same `progress.stages.aggregator_sync.providers` shape.

---

## 4. Reading Menus

For partners that need to inspect klikit's canonical state.

| Endpoint | Use |
|---|---|
| `GET /v1/partner/menus?branch_id=100&brand_id=10` | Full menu tree for a store |
| `GET /v1/partner/menus/items?branch_id=100&page=1&limit=200` | Paginated flat item list |
| `GET /v1/partner/menus/items/{klikit_item_id}` | Single item detail incl. modifier groups |
| `GET /v1/partner/menus/items/{klikit_item_id}/stock?branch_id=100` | Current stock state per provider |

All read endpoints honour `menus:read` scope; partners with only `mapping:write` and `stock:write` cannot enumerate the full menu (you look up by partner ID via §1.2 instead).

---

## 5. Capability Cheat Sheet by Persona

| Persona | Read menus | Mapping | Stock | Push menus |
|---|---|---|---|---|
| POS | ✅ | ✅ | ✅ | optional |
| ERP / accounting | optional | optional | — | — |
| Inventory system | — | ✅ | ✅ | — |
| White-label storefront | ✅ | (auto via Push) | optional | ✅ |

The "auto via Push" cell means: when a white-label partner uses Menu Push, mappings between your `partner_*_id` and klikit IDs are registered automatically — no separate Mapping call needed. POS partners typically don't push menus (the klikit dashboard is master), so they explicitly call Mapping.

---

## See Also

- [Authentication](./authentication.md) — scopes, idempotency, signing
- [Orders](./orders.md) — order schema (where `partner_item_id` populates from §1 mappings)
- [OpenAPI Spec](./openapi/menus.yaml) — machine-readable spec
