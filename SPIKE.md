# ge-mcp spike

**Goal:** decide `ge-mcp`'s tool surface *empirically* before writing any Go. Point a
generic read-only Postgres MCP at the real Timescale DB, drive an agent against the
directives we care about, and capture the SQL it converges on. Those queries become the
4–6 tools `ge-mcp` will expose. Building the tool surface after seeing real query
patterns beats guessing it.

**Time-box:** one afternoon. The output is notes + decisions in this file, not code.

---

## Background (what `ge-mcp` will become)

A read-only MCP server (Go, `mark3labs/mcp-go`) running in k8s alongside the ingester,
exposing *domain* tools — not raw SQL — to the `ge-agent` directive loop. It honors the
schema contract in `ge-data/init/01_schema.sql`; it never writes.

The data it reads (forward-only, grows from when polling began):

| Table | Grain | Has volume? | Has margin? | Notes |
|---|---|---|---|---|
| `items` | static | — | — | metadata; `items_name_lower_idx` for name→id |
| `prices_5m` | 5-min block | **yes** (`high_volume`,`low_volume`) | no | only source of volume/liquidity |
| `prices_1m` | per-minute, dedup-on-change | no | **yes** (`margin`, post-tax, stored at ingest) | instantaneous last-trade prices |

Schema rules that the spike must respect (and that tools will later encode):
- **Nulls are a liquidity signal, never zero-fill.** A null price = nothing traded that
  side. `WHERE x IS NOT NULL`, not `COALESCE(x,0)`.
- **`prices_1m.margin` is already post-tax** (`high − LEAST(high/50, 5M) − low`). Read
  it; do not recompute. `prices_5m` has **no** margin column.
- **Compression after 7 days** on both hypertables (`compress_orderby ts DESC`,
  `segmentby item_id`). Queries over old ranges decompress — keep spike queries recent,
  and note any directive that wants long lookback (→ may need a continuous aggregate).

---

## Setup

### 1. Read-only DB access
The spike must use a **SELECT-only** connection — never the ingester's read/write role.
For the spike, the simplest path is a throwaway read-only role on eldo:

```sql
-- run on eldo as a superuser, throwaway for the spike (the permanent ge-mcp
-- role gets declared in ~/cfg later — see osrs-ge-architecture / ge-data-db-home memory)
CREATE ROLE ge_mcp_spike LOGIN PASSWORD '<temp>';
GRANT CONNECT ON DATABASE "ge-data" TO ge_mcp_spike;   -- db name is hyphenated → must be quoted
GRANT USAGE ON SCHEMA public TO ge_mcp_spike;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ge_mcp_spike;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT TO ge_mcp_spike;
```

Connect over the tailnet to eldo. If your spike machine isn't already covered by a
`pg_hba` rule, add a temporary one in `~/cfg` (or test from a host that is). DSN:
```
postgresql://ge_mcp_spike:<temp>@eldo.<tailnet>:5432/ge-data?sslmode=disable
```

### 2. The MCP server
Use **`postgres-mcp`** ("Postgres MCP Pro", Crystal DBA) in **restricted/read-only**
mode — actively maintained, has guardrails and EXPLAIN. (The reference
`@modelcontextprotocol/server-postgres` also works but is archived; fine for a quick try.)
Register it with your agent client pointing at the read-only DSN above.

### 3. Cleanup checklist (end of spike)
- [ ] `DROP ROLE ge_mcp_spike;`
- [ ] remove any temporary `pg_hba` entry
- [ ] copy findings into the "Decisions" section below

---

## Directives to throw at the agent

These stand in for the real `ge-agent` directives. For each, let the agent figure out
the SQL, then **record the query it lands on** (next section).

1. **Best flips right now** — top N items by current post-tax margin, restricted to
   items that actually trade (use `prices_5m` volume as the liquidity gate; margin from
   the latest `prices_1m` row per item).
2. **Liquid flips only** — same, but require e.g. `high_volume + low_volume > V` over the
   last hour. Forces a 5m↔1m join and a volume window.
3. **Margin as % of capital** — ROI = margin / low, not just absolute margin. Surfaces
   cheap high-turnover items vs. big-ticket ones.
4. **Price/volume history for one item** — given a name ("Twisted bow"), resolve to
   `item_id`, then pull the last 24h/7d series. Tests `items` lookup + hypertable read +
   which grain the agent prefers.
5. **Movers** — items whose margin or price changed most over the last hour/day. Tests
   window functions / self-joins over a time range.
6. **Buy-limit-aware sizing** — join `items.buy_limit` so a "flip" accounts for how many
   you can actually buy per 4h. Tests whether item metadata belongs in the flip tool.

For each directive note: did it need volume (→ 5m)? margin (→ 1m stored col)? a join?
a time window? item metadata? how far back?

---

## What to capture (the actual deliverable)

A table like this, filled in during the spike:

| Directive | SQL the agent used | Tables/joins | Lookback | Notes / gotchas |
|---|---|---|---|---|
| best flips | … | prices_1m (+5m for liquidity) | latest | … |
| … | | | | |

From the recurring shapes, draft the **tool list** for `ge-mcp`, e.g.:
- `top_flips(min_volume, members?, limit)` → ordered by stored margin, volume-gated
- `item_history(name_or_id, grain, lookback)` → series from the right hypertable
- `liquidity(item_id, window)` → summed 5m volume
- `lookup_item(name)` → uses `items_name_lower_idx`
- `movers(window, by=margin|price, limit)` → only if directive 5 proves useful

---

## Decisions to reach (fill in at the end)

> **Superseded.** The spike happened; the resolved tool surface and decisions now live in
> [SPEC.md §5](./SPEC.md#5-decisions) (8 tools, not the "4–6" guessed below) and the build
> decisions in [DESIGN.md](./DESIGN.md). The prompts below are kept for provenance.
> **Cleanup status:** the throwaway `ge_mcp_spike` role was **never created** (confirmed
> 2026-06-19) — the spike was run a different way, so there's no leftover login role or
> `pg_hba` entry to drop. No prod exposure. The permanent read-only `ge-mcp` role DDL (still
> to be applied) is checked in at [`ge-mcp/db/grants.sql`](./db/grants.sql).

1. **Tool surface:** the final 4–6 tools + their params (above).
2. **Does anything need margins on 5m data?** If yes → the tax formula
   (`flipMargin`/`maxGETax`, currently in `ge-data` collect.go) becomes the first thing
   worth extracting to a shared spot. If no (everything rides `prices_1m.margin`) →
   confirmed: no `ge-shared`, ge-mcp stays pure-SELECT.
3. **Continuous aggregate needed?** If any directive wants multi-week/month lookback,
   raw decompression is too slow → spec a Timescale continuous aggregate (e.g. daily
   rollup) in `ge-data/init/` and point the history tool at it.
4. **"Latest row per item" pattern:** `prices_1m` is dedup-on-change, so "current price"
   = the most recent row per item, not a fixed timestamp. Decide the canonical query
   (`DISTINCT ON (item_id) ... ORDER BY item_id, ts DESC`) — it'll be in most tools.
5. **Result shape:** what JSON the tools return (include `name` + `icon` from `items`?
   raw ids? formatted gp?).

---

## Next step after the spike
Scaffold `ge-mcp`: `go mod init`, `mark3labs/mcp-go` server skeleton, the read-only DSN
from config, and the tools decided above. Then wire `ge-agent` to it.
