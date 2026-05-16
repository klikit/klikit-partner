# Partner Event Schema — Versioning Policy

> **Story:** E7-S0 · Partner API v1 · Frozen 2026-05-16
> Companion to [`../../CONTRACT.md`](../../CONTRACT.md) and PRD TR-4.

This document is the authoritative versioning policy for klikit partner
webhook events. The JSON-schema for each event type lives alongside it in this
directory.

---

## 1. Why a separate versioned event contract

`oni` publishes internal order lifecycle events to Dapr pub/sub. Those internal
shapes change whenever internal needs change. The partner-facing event contract
**must not break** when they do.

`hookit` is the explicit **mapping boundary** (PRD TR-4): it subscribes to the
internal `oni` events and transforms each into a versioned partner event before
signed delivery. Adding `order.placed.v2` later means adding a transform path in
`hookit`, not coordinating an `oni` release.

```
oni  ──(internal event, Dapr pub/sub)──▶  hookit  ──(order.*.vN, HMAC-signed HTTP)──▶  partner
                                          └─ transform / mapping boundary ─┘
```

---

## 2. Version naming

- Every partner event type carries an explicit `.vN` suffix in `event_type`:
  `order.placed.v1`, `order.delivered.v1`, …
- `N` is a single integer, starting at `1`. There is no minor version in the
  type string.
- The webhook envelope also carries an `event_version` string field (e.g.
  `"1.0"`) for human display. **The authoritative version is the `.vN` in
  `event_type`** — consumers route on `event_type`, not `event_version`.
- The `X-Klikit-Event` HTTP header repeats the full versioned `event_type`.

## 3. What counts as a breaking change

A **new version** (`order.placed.v2`) is required for any of:

- Removing or renaming a field.
- Changing a field's type or its set of enum values (narrowing).
- Changing the meaning of an existing field.
- Making a previously-optional field required.

The following are **non-breaking** and ship within the same version:

- Adding a new optional field.
- Adding a new enum value to a field that consumers are documented to treat
  permissively (consumers MUST ignore unknown enum values).
- Adding a new event type (`order.refunded.v1` is additive).

## 4. Deprecation window

- When `order.X.v2` ships, `order.X.v1` continues to be delivered in parallel
  for **at least 6 months**.
- During the overlap, a partner credential receives **both** versions for each
  qualifying order. Partners migrate at their own pace and then ask klikit CX to
  stop `v1` delivery for their credential, or wait for the window to close.
- klikit announces the `v1` end-of-life date on the Mintlify site and by email
  to every partner with an active credential at least 90 days before cutoff.

## 5. Event registry

The v1 event type registry — the complete set a partner credential can receive:

| Event type | Schema file | Fires when |
|---|---|---|
| `order.placed.v1` | [`order.placed.v1.json`](./order.placed.v1.json) | New order arrives in klikit (any channel) |
| `order.updated.v1` | [`order.updated.v1.json`](./order.updated.v1.json) | Order details change — not status |
| `order.cancelled.v1` | [`order.cancelled.v1.json`](./order.cancelled.v1.json) | Order moves to `cancelled`, any party |
| `order.amended.v1` | [`order.amended.v1.json`](./order.amended.v1.json) | Operator post-hoc correction to an order |
| `order.courier_assigned.v1` | [`order.courier_assigned.v1.json`](./order.courier_assigned.v1.json) | A rider is assigned to a delivery order |
| `order.picked_up.v1` | [`order.picked_up.v1.json`](./order.picked_up.v1.json) | Order collected from the store |
| `order.delivered.v1` | [`order.delivered.v1.json`](./order.delivered.v1.json) | Delivery order confirmed delivered |

All seven share the same envelope (`PartnerEventEnvelope`, defined in each
schema's `$defs`) and the same `data` shape (the canonical `Order` object from
[`../orders.yaml`](../orders.yaml)). They differ only in the `event_type`
constant and the per-event notes below.

## 6. Delivery semantics (no event-type subscription)

- A partner credential receives **every** order event type for the
  business/brand/branch scope its `webhook_url` is registered against. There is
  **no event-type subscription model** (D2, 2026-05-15) — partners filter on
  `event_type` client-side if they only care about a subset.
- Delivery is **at-least-once**. Partners MUST deduplicate on `event_id`.
- Event **order is not guaranteed**. Partners order events by the order's
  `data.updated_at` / `data.status_history`, not by arrival order.
- Each event is HMAC-signed (`X-Klikit-Signature`); see
  [`../../CONTRACT.md`](../../CONTRACT.md) §4.

## 7. Per-event notes

- **`order.placed.v1`** — fires exactly once per order. `data.status` is
  `placed`. The richest payload; everything downstream is an update to it.
- **`order.updated.v1`** — non-status detail change (customer note, address,
  delivery instruction). `data` is the full current order, not a delta.
- **`order.cancelled.v1`** — `data.status` is `cancelled`. The cancelling party
  and reason are in the last `data.status_history` entry (`by`, `reason_code`).
- **`order.amended.v1`** — operator correction. `data` is the full corrected
  order; partners reconcile their local copy entirely against it.
- **`order.courier_assigned.v1`** — `delivery` orders only.
  `data.fulfilment.rider` is populated (`status: assigned` and rider contact
  where the aggregator provides it).
- **`order.picked_up.v1`** — `data.status` is `picked_up` for pickup / dine-in /
  scan-to-order; for `delivery`, the order has left the store and
  `data.fulfilment.rider.status` is `en_route`.
- **`order.delivered.v1`** — `delivery` orders only. `data.status` is
  `delivered`. `data.totals.aggregator_commission` is populated when the
  originating platform supplies it, `null` otherwise (BRD reconciliation §5).

## 8. Schema validation

The JSON-schema files are JSON Schema **draft 2020-12**. They are the source of
truth for the `data` payload shape and are kept consistent with the `Order`
schema in `../orders.yaml`. CI (Wave 1, `hookit`) validates every transformed
event against the matching schema before signed delivery.
