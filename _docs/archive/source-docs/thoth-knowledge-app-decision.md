# Thoth — unified knowledge management app (decision document)

## Status

**Discussion / pre-decision.** No commitment to build. This document captures the state of architectural thinking from the 2026-05-03 design conversation so it can be picked up cold in a future session for further research and refinement.

Named for [Thoth](https://en.wikipedia.org/wiki/Thoth), Egyptian god of writing, knowledge, and the moon — fits the "single pane of glass for personal knowledge" framing.

## Vision

Replace the current trio of self-hosted apps with one cohesive system:

- **Wallabag** — read-it-later for web articles
- **FreshRSS** — RSS/Atom aggregator
- **Syncthing** — bidirectional file sync (used today for markdown notes)

The unified app provides a single inbox/library for articles, feed items, and notes, with cross-cutting tags, full-text + semantic search, and an AI/ML layer for summarization, auto-tagging, similarity search, and Q&A over the personal knowledge base.

iOS native client is a long-term goal — share-sheet save, offline reading, push notifications.

## Why this exists in the design pipeline

It's the planned anchor application that justifies the broader platform investment:

- A multi-service custom app is the strongest case for the **service mesh decision** (deferred from observability Phase 0; Istio is the leading candidate per the user's preference for production-credentialed tooling).
- It exercises the observability stack (Prometheus, Loki, Tempo) end-to-end with real cross-service tracing.
- It uses every infrastructure primitive already built: CNPG, External Secrets, 1Password Connect, Cilium Gateway, External DNS, freenas-iscsi, Renovate.

The platform-engineering value is high. The product value is debatable — Wallabag + a maintained reader + Obsidian Sync (or Logseq, or Anytype) gets to ~80% of the goal off the shelf. **Be honest with yourself about which goal is primary.**

## Mesh decision (anchored to this app)

| Option | Verdict |
| --- | --- |
| Cilium Service Mesh (sidecarless) | Lowest-cost path; reuses existing Cilium investment. Less mature for advanced features. |
| **Istio Ambient** | **User-preferred long-term.** Most production references; ambient mode sidesteps the per-pod sidecar weirdness. Higher operational complexity tax. |
| Linkerd | Operationally simplest, but Buoyant's 2024 commercial license change cooled community/homelab use. |

**Direction:** Istio Ambient when the mesh phase begins. Adopt **at step 3 of the phased build below** (after the first 1-2 services exist as bare deployments), so the "before" experience makes the mesh's value viscerally felt.

The mesh is east-west (pod-to-pod). Cilium Gateway stays as the north-south ingress; both layers coexist.

## Architecture sketch

```
                            ┌── Cilium Gateway ──┐
                            └─────────┬──────────┘
                                      ▼
┌──────────────────── thoth namespace (Istio) ──────────────────────────┐
│                                                                       │
│   ┌──────┐ ◀── HTTP/JSON ── web (Next.js)                             │
│   │ bff  │ ◀── gRPC      ── iOS (Swift)                               │
│   └──┬───┘                                                            │
│      │                                                                │
│      ├──▶ auth ──▶ 1P Connect                                         │
│      │                                                                │
│      ├──▶ content ──▶ Postgres (canonical "item" table)               │
│      │       │       └─▶ pgvector (embeddings co-located)             │
│      │       └──▶ MinIO (S3, holds article HTML + note files + blobs) │
│      │                                                                │
│      ├──▶ search ──▶ Meilisearch (keyword) + content (vector via pg)  │
│      │                                                                │
│      ├──▶ ai ──▶ {summarize, tag, embed, ask}                         │
│      │      ├──▶ Ollama (local LLM, GPU-optional)                     │
│      │      └──▶ optional: external API (Claude / OpenAI) for heavy   │
│      │                                                                │
│      ├──▶ sync ──▶ note storage state ──▶ Postgres + MinIO            │
│      │                                                                │
│      └──▶ notify ──▶ APNs                                             │
│                                                                       │
│   Workers (NATS-driven, mesh-injected like everything else):          │
│      • web-fetcher    — URL → article (replaces wallabag's graby)     │
│      • feed-poller    — cron → RSS/Atom → items                       │
│      • ai-pipeline    — newly-saved item → tag/summarize/embed async  │
└───────────────────────────────────────────────────────────────────────┘
```

### Service breakdown

| Service | Lang (proposed) | Job |
| --- | --- | --- |
| **bff** | Go | API aggregation, response shaping for web vs. iOS |
| **auth** | Go | OIDC/JWT issuance, session management, brokers to 1P Connect |
| **content** | Go | CRUD on items (article, note, feed entry, file). Owns the canonical schema. |
| **search** | Go | Wraps Meilisearch (keyword) and pgvector (semantic) |
| **ai** | Python | LLM gateway: routes summarize/tag/embed/ask to local (Ollama) or external (Claude/OpenAI) |
| **sync** | Go | Note-specific bidirectional sync (the syncthing replacement) |
| **notify** | Go | APNs push for iOS |
| **web-fetcher** | Go | Worker — URL → readable article |
| **feed-poller** | Go | Worker — RSS/Atom polling |
| **ai-pipeline** | Go | Worker — drives async AI work via the `ai` service |

### Canonical "item" abstraction

All three primitive types reduce to a polymorphic `item` row:

- common: `id, type, title, source_url, created_at, tags[], state, body_ref, metadata jsonb`
- type-specific in `metadata`: feed_id, parser version, sync_vector, etc.
- `body_ref` points to MinIO for HTML/markdown blobs; small notes can live inline.

The mobile app sees one homogenous list, not three. UI affordances diverge per type but the data model is unified.

## Hard decisions still open

### 1. Sync model for notes (most consequential)

| Model | Behavior | Cost |
| --- | --- | --- |
| Server-of-truth (Notion-like) | Server canonical; mobile holds cache; offline edits queue & replay; conflicts surface manually | Easy. Bad UX during long offline. |
| **Filesystem-with-arbiter** (current syncthing-ish, **recommended starting point**) | Notes stay as plain markdown files in MinIO; devices sync via WebDAV/S3-style API; conflicts produce `note.conflict-<ts>.md` files | Medium. Loses fine-grained merge but preserves portability and matches current UX. |
| CRDT-based (Logseq / Automerge / Y.js / Loro) | Every device a replica; automatic merge; server is one peer | Hardest. Best UX but mature CRDT use is a research-grade undertaking for offline-first mobile + server. |

**Initial lean:** filesystem-with-arbiter — preserves the syncthing-equivalent behavior the user has already lived with for years and keeps notes as portable markdown. Reconsider CRDTs only if collaborative editing becomes a real requirement.

### 2. AI hosting policy

Two axes:

- **Always-on vs. on-demand.** Recommended hybrid: embedding + tagging always-on (cheap, unlocks similarity search); summarization + Q&A on-demand.
- **Local vs. external inference.** Strict privacy says all-local (Ollama on a GPU node). Pragmatic says hybrid — local for cheap/sensitive ops, external (Claude/OpenAI) for heavy Q&A with explicit per-query opt-in.

**Open question:** willingness to add a GPU node (Proxmox PCI passthrough; even a used 3060/4060 dramatically improves Q&A latency). CPU-only LLM inference for Q&A is slow enough to feel broken.

### 3. iOS client scope

| Option | Trade-off |
| --- | --- |
| Native (SwiftUI + gRPC) | Real share-sheet save, offline reading, file provider, push. Months of mobile work. |
| PWA | 60% of the value in 10% of the effort. No share-sheet, weaker offline. |

**Long-term goal: native.** Possibly PWA as the v0 to validate UX before committing to mobile work.

### 4. Backend language strategy

| Option | Trade-off |
| --- | --- |
| Go everything (incl. AI service via ONNX runtime) | Single build pipeline, single deploy story. Less flexible AI model choices. |
| **Go + Python (Python only for `ai`)** | **Recommended.** Polyglot is justified — Python has the AI ecosystem; Go for everything else keeps ops simple. Mesh handles cross-language traffic uniformly. |

### 5. Sequencing realism

The full vision is **6–12 months of evening work minimum** if done seriously. Acceptable scope, or compress to a smaller v1?

Possible compressions:
- "Articles + AI" only as v1; defer notes/sync entirely (keeps Syncthing for now).
- Single-user only (no real auth complexity in v1).
- PWA-only client deferred-native (ship mobile in v2).

## Phased build plan

Don't pre-split into microservices. Start as a Go monolith; split when the mesh enters.

1. **Articles only.** `bff + auth + content + web-fetcher + postgres + minio` as a single Go binary or 2-3 services. Replicate Wallabag's core flow: save URL, read, tag. Use `go-readability` or call out to Mercury Parser. **Use it daily for 2 weeks before adding anything.**
2. **RSS.** Add `feed-poller`. Items land in the same `item` table — same UI, same tags. Decommission FreshRSS once trusted.
3. **Mesh enable + observability deep-dive.** Pause feature work, instrument, feel the difference. The "before/after" learning win lands here.
4. **Notes + sync.** Add `sync` service + MinIO-backed markdown. iOS file provider extension. Discover whether filesystem-arbiter is good enough. Decommission Syncthing once trusted.
5. **AI layer (embedding + tagging).** Always-on pipeline. Cross-corpus similarity search comes alive — first single-pane-of-glass moment.
6. **AI layer (summarization + Q&A).** On-demand, with the local/external toggle.
7. **iOS native client.** SwiftUI + gRPC. Share extension, file provider, push.

## Honest pushbacks captured during design

1. This is **18+ months of part-time work** for what already exists in 80%-complete forms (Wallabag + Reeder + Obsidian Sync, or Logseq, or Anytype). Be clear whether you're optimizing for product value or platform-engineering value.
2. The cluster will likely sprout a **GPU node** if AI gets serious. CPU-only LLM Q&A is painful.
3. The **iOS native app is a real project on its own** — not a small bolt-on.
4. **Decommissioning means migration.** Wallabag/FreshRSS/Syncthing all have export formats; plan for a one-shot importer per source.
5. **Don't pre-split into microservices.** A monolith you split later is much easier than a distributed system you have to debug from day one.

## Infrastructure already built that this leverages

| Primitive | Status | Used for |
| --- | --- | --- |
| Postgres (CNPG) | Production-ready in dev | `content`, `sync`, `auth` session state, pgvector embeddings |
| MariaDB operator | Deployed | Available if any service prefers it (probably not needed) |
| External Secrets + 1P Connect | Live | All credentials, APNs cert, OIDC client secrets |
| Cilium Gateway + External DNS + cert-manager | Live | North-south ingress, internal HTTPS via wildcard-tls |
| Renovate | Live | Auto-bumps Go/Python deps and container images |
| Tempo + Loki + Prometheus + Grafana | Live (Phase 0 complete) | Full observability for every service |
| Tailscale (operator + tailnet) | Live | iOS access to internal services without exposing publicly |
| freenas-iscsi CSI | Live | Persistent storage for Postgres, MinIO |

**Net-new infrastructure required:**
- MinIO (or alternative S3-compatible) for blob storage
- Meilisearch for keyword search
- NATS for the worker queue
- Ollama deployment (CPU-initial, GPU-eventual)
- Istio Ambient (the mesh decision)
- Optional: GPU node in Proxmox

## Open questions to research before next session

1. **Sync model deep-dive:** if filesystem-with-arbiter, what's the iOS File Provider Extension story for syncing markdown to/from MinIO? Any reference projects?
2. **Article extraction:** survey current state of `go-readability`, Mercury Parser, and whether Wallabag's `graby` (PHP) has a Go equivalent. The parser is wallabag's secret sauce — replacement quality matters.
3. **CRDT escape hatch:** if filesystem-arbiter proves insufficient, what's the migration path to Automerge/Y.js/Loro later? Is a single schema change enough, or does it require a rewrite?
4. **GPU node feasibility:** PCI passthrough on the Beelink S13s is unlikely (no full-size PCIe slot). A separate GPU host (used workstation) is the realistic path. Pricing + power budget?
5. **Istio Ambient maturity for an Ollama backend:** any known issues with long-lived gRPC streams (LLM token streaming) through ztunnel/waypoints?
6. **Auth strategy:** roll your own OIDC (small Go service) vs. deploy Authentik/Keycloak/Pocket-ID and integrate? For single-user, the former is fine; for multi-user, the latter.
7. **iOS app — Swift+gRPC or Swift+REST?** gRPC-Swift exists but is less native than URLSession+REST. Trade-off matters for long-term mobile dev velocity.
8. **Cost ceiling for external AI APIs** if hybrid model wins. Define the per-month spend cap up front.
9. **Backup and DR for the new app's data:** notes are now in MinIO instead of syncthing folders — does the existing notes-backup script (TrueNAS zvol → restic to anubis) need to be re-pointed at MinIO buckets?

## Reference: discussion artifacts

This document is the synthesis of the 2026-05-03 design conversation. Prior context that informed it:

- Observability Phase 0 plan: `_docs/observability-phase-0-plan.md` (now complete)
- Istio decision doc: referenced in `_docs/`-adjacent decision history (locate next session)
- `~/.claude/plans/today-i-d-like-to-piped-teacup.md` — prior mesh design notes
