#!/usr/bin/env python3
"""
Generate a Mermaid ER diagram from the JSON produced by export_erpnext_schema.py.

Standard library only.

Because ERPNext has 1000+ DocTypes, a full diagram is unreadable — use the
filters to scope it:

    # everything in a few modules
    python3 schema_to_mermaid.py erpnext_schema.json \
        --modules Accounts Selling -o erd.mmd

    # one DocType and everything within 1 hop of it
    python3 schema_to_mermaid.py erpnext_schema.json \
        --focus "Sales Invoice" --depth 1 -o sales_invoice.mmd

    # include field lists inside each entity box
    python3 schema_to_mermaid.py erpnext_schema.json --focus "Customer" --attributes

Render the .mmd file at https://mermaid.live, the VS Code "Markdown Preview
Mermaid" extension, or with the mermaid CLI:  mmdc -i erd.mmd -o erd.svg
"""
import argparse
import json
import re
import sys
from collections import defaultdict


def eid(name):
    """Sanitize a DocType name into a valid Mermaid entity id."""
    return re.sub(r"[^0-9A-Za-z_]", "_", name)


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def build_adjacency(rels):
    adj = defaultdict(set)
    for r in rels:
        adj[r["from"]].add(r["to"])
        adj[r["to"]].add(r["from"])
    return adj


def expand(seed, adj, depth):
    """BFS from seed up to `depth` hops."""
    seen = set(seed)
    frontier = set(seed)
    for _ in range(depth):
        nxt = set()
        for n in frontier:
            nxt |= adj.get(n, set())
        nxt -= seen
        seen |= nxt
        frontier = nxt
        if not frontier:
            break
    return seen


def main():
    p = argparse.ArgumentParser(description="Schema JSON -> Mermaid ER diagram")
    p.add_argument("schema", help="Path to erpnext_schema.json")
    p.add_argument("--modules", nargs="*", help="Only DocTypes in these modules")
    p.add_argument("--focus", nargs="*", help="Center the diagram on these DocTypes")
    p.add_argument("--depth", type=int, default=1, help="Hops to expand around focus/modules (default 1)")
    p.add_argument("--all", action="store_true", help="Include every DocType (can be huge)")
    p.add_argument("--attributes", action="store_true", help="List each entity's fields inside its box")
    p.add_argument("--max-entities", type=int, default=80,
                   help="Warn if the diagram exceeds this many entities (default 80)")
    p.add_argument("-o", "--output", help="Write to file (default: stdout)")
    args = p.parse_args()

    schema = load(args.schema)
    doctypes = schema.get("doctypes", {})
    rels = schema.get("relationships", [])
    adj = build_adjacency(rels)

    # 1) pick the seed set
    if args.focus:
        seed = {d for d in args.focus if d in doctypes} or set(args.focus)
        included = expand(seed, adj, args.depth)
    elif args.modules:
        seed = {n for n, d in doctypes.items() if d.get("module") in args.modules}
        included = expand(seed, adj, max(args.depth, 0))
    elif args.all:
        included = set(doctypes) | {n for r in rels for n in (r["from"], r["to"])}
    else:
        p.error("Choose a scope: --focus <DocType...>, --modules <Module...>, or --all")

    # keep only edges whose both ends are included
    edges = []
    seen_edge = set()
    for r in rels:
        if r["from"] in included and r["to"] in included:
            key = (r["from"], r["to"], r["field"], r["kind"])
            if key in seen_edge:
                continue
            seen_edge.add(key)
            edges.append(r)

    if len(included) > args.max_entities:
        print(f"WARNING: {len(included)} entities (> {args.max_entities}). The diagram "
              f"may be hard to read — narrow it with --focus/--modules or a smaller "
              f"--depth.", file=sys.stderr)

    # 2) emit Mermaid
    out = ["erDiagram"]

    if args.attributes:
        for name in sorted(included):
            d = doctypes.get(name)
            if not d:
                continue
            out.append(f"    {eid(name)} {{")
            for f in d.get("fields", []):
                ftype = eid(f.get("type") or "Data")
                fname = f.get("fieldname") or "field"
                ref = f.get("links_to") or f.get("child_table")
                comment = f' "-> {ref}"' if ref else ""
                out.append(f"        {ftype} {fname}{comment}")
            out.append("    }")

    for r in edges:
        # child_table: parent ||--o{ child ; link: target ||--o{ referencing
        if r["kind"] == "child_table":
            parent, child = r["from"], r["to"]
        else:  # link
            parent, child = r["to"], r["from"]
        out.append(f'    {eid(parent)} ||--o{{ {eid(child)} : "{r["field"]}"')

    text = "\n".join(out) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"Wrote {args.output}: {len(included)} entities, {len(edges)} relationships.",
              file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
