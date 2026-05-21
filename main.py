"""mkdocs-macros module for the home-0ps docs site.

Provides build-time macros that pull the Roadmap page's content straight from
the newest dated review in _docs/reviews/, so the roadmap never drifts from the
`/lab-review` tracker.
"""

import glob
import os
import re

REVIEW_GLOB = "_docs/reviews/home-0ps-review-*.md"


def _latest_review_path():
    files = sorted(glob.glob(REVIEW_GLOB))
    return files[-1] if files else None


def _extract_section(text, *title_substrings):
    """Return the body of the first level-2 (##) section whose heading contains
    any of the given substrings, up to the next heading of equal/higher level."""
    lines = text.splitlines()
    start_level = None
    out = []
    for line in lines:
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            heading = m.group(2)
            if start_level is None:
                if any(s.lower() in heading.lower() for s in title_substrings):
                    start_level = level
                continue
            elif level <= start_level:
                break
        if start_level is not None:
            out.append(line)
    return "\n".join(out).strip()


def define_env(env):
    @env.macro
    def latest_review_name():
        path = _latest_review_path()
        return os.path.basename(path) if path else "n/a"

    @env.macro
    def latest_review_date():
        name = latest_review_name()
        m = re.search(r"(\d{4}-\d{2}-\d{2})", name)
        return m.group(1) if m else "unknown"

    @env.macro
    def review_section(*title_substrings):
        path = _latest_review_path()
        if not path:
            return "_No review found in `_docs/reviews/`._"
        with open(path, encoding="utf-8") as fh:
            body = _extract_section(fh.read(), *title_substrings)
        return body or f"_Section { ' / '.join(title_substrings) } not found in the latest review._"
