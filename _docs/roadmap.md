---
render_macros: true
---

# Roadmap & open items

!!! abstract "Auto-generated from the tracker"
    The sections below are pulled at **build time** from the newest review in
    [`reviews/`](reviews/{{ latest_review_name() }}) (`{{ latest_review_date() }}`),
    which `/lab-review` regenerates. Edit the review, rebuild, and this page follows —
    no manual duplication.

## Suggested next sprint

{{ review_section("Suggested Next Sprint") }}

## Open items punch list

{{ review_section("Open Items Punch List") }}

---

!!! note "Going further"
    Today this refreshes whenever the docs image is rebuilt (i.e. when a review
    changes). To reflect cluster runtime state too, the same approach as
    [Status](status.md#making-this-live) applies — a build step could fold in live
    Prometheus/Flux data.
