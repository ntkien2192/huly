#!/usr/bin/env python3
"""
Export the full ERPNext / Frappe schema (DocTypes, fields, relationships) to JSON.

Only uses the Python standard library — no pip install needed.

Usage:
    export ERPNEXT_URL="https://erp.estateos.cloud"
    export ERPNEXT_API_KEY="xxxx"
    export ERPNEXT_API_SECRET="yyyy"
    python3 export_erpnext_schema.py -o erpnext_schema.json

    # or pass on the command line
    python3 export_erpnext_schema.py \
        --url https://erp.estateos.cloud \
        --key xxxx --secret yyyy \
        --modules Accounts Selling Stock \
        -o schema.json

Get the API key/secret in ERPNext: avatar (top-right) -> My Settings ->
API Access -> Generate Keys.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

# Field types that are pure layout / display and do not hold data.
LAYOUT_FIELDTYPES = {
    "Section Break", "Column Break", "Tab Break",
    "HTML", "Heading", "Button", "Fold",
}

# Every Frappe document carries these system columns.
STANDARD_FIELDS = [
    {"fieldname": "name", "type": "Data", "note": "primary key"},
    {"fieldname": "owner", "type": "Link", "links_to": "User"},
    {"fieldname": "creation", "type": "Datetime"},
    {"fieldname": "modified", "type": "Datetime"},
    {"fieldname": "modified_by", "type": "Link", "links_to": "User"},
    {"fieldname": "docstatus", "type": "Int", "note": "0=Draft 1=Submitted 2=Cancelled"},
    {"fieldname": "idx", "type": "Int"},
]


def api_get(url, key, secret, path, params=None):
    """GET a Frappe REST endpoint and return the parsed 'data' payload."""
    full = url.rstrip("/") + path
    if params:
        full += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(full)
    req.add_header("Authorization", f"token {key}:{secret}")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        raise RuntimeError(f"HTTP {e.code} for {path}: {body}") from None
    return payload.get("data", payload)


def list_doctypes(url, key, secret):
    """Return all DocType names."""
    data = api_get(url, key, secret, "/api/resource/DocType",
                   {"limit_page_length": 0})
    return [d["name"] for d in data]


def simplify_field(f):
    """Turn a raw DocField into a compact, learning-friendly dict."""
    ftype = f.get("fieldtype")
    out = {
        "fieldname": f.get("fieldname"),
        "label": f.get("label"),
        "type": ftype,
    }
    options = (f.get("options") or "").strip()
    if ftype == "Link" and options:
        out["links_to"] = options
    elif ftype in ("Table", "Table MultiSelect") and options:
        out["child_table"] = options
    elif ftype == "Dynamic Link" and options:
        out["target_from_field"] = options  # options = fieldname holding the DocType
    elif ftype == "Select" and options:
        out["choices"] = [o for o in options.split("\n") if o != ""]
    if f.get("reqd"):
        out["required"] = True
    if f.get("unique"):
        out["unique"] = True
    if f.get("read_only"):
        out["read_only"] = True
    if f.get("in_list_view"):
        out["in_list_view"] = True
    if f.get("fetch_from"):
        out["fetch_from"] = f.get("fetch_from")
    default = f.get("default")
    if default not in (None, ""):
        out["default"] = default
    return out


def build_layout(raw_fields):
    """Build the nested form layout: Tab -> Section -> Column -> [fieldnames].

    Frappe fields are an ordered list where "Tab Break", "Section Break" and
    "Column Break" mark the visual grouping. This reconstructs that tree so you
    can see how ERPNext arranges data on each form. Only fieldname references
    are stored here; full field details live in the flat "fields" list.
    """
    def new_tab(f=None):
        return {"tab": (f or {}).get("label"), "fieldname": (f or {}).get("fieldname"), "sections": []}

    def new_section(f=None):
        return {"section": (f or {}).get("label"), "fieldname": (f or {}).get("fieldname"), "columns": []}

    def new_column(f=None):
        return {"column": (f or {}).get("label"), "fieldname": (f or {}).get("fieldname"), "fields": []}

    tabs, tab, section, column = [], new_tab(), new_section(), new_column()

    def close_column():
        if column["fields"] or column["column"]:
            section["columns"].append(column)

    def close_section():
        close_column()
        if section["columns"] or section["section"]:
            tab["sections"].append(section)

    def close_tab():
        close_section()
        if tab["sections"] or tab["tab"]:
            tabs.append(tab)

    for f in raw_fields:
        ft = f.get("fieldtype")
        if ft == "Tab Break":
            close_tab()
            tab, section, column = new_tab(f), new_section(), new_column()
        elif ft == "Section Break":
            close_section()
            section, column = new_section(f), new_column()
        elif ft == "Column Break":
            close_column()
            column = new_column(f)
        elif ft not in LAYOUT_FIELDTYPES:
            column["fields"].append(f.get("fieldname"))
        # other layout-only types (HTML, Heading, Button...) are ignored here
    close_tab()
    return tabs


def export(url, key, secret, modules=None, include_layout=False):
    names = list_doctypes(url, key, secret)
    total = len(names)
    doctypes = {}
    relationships = []
    skipped = []

    for i, name in enumerate(names, 1):
        print(f"[{i}/{total}] {name}", file=sys.stderr)
        try:
            doc = api_get(url, key, secret,
                          "/api/resource/DocType/" + urllib.parse.quote(name))
        except RuntimeError as e:
            skipped.append({"doctype": name, "error": str(e)})
            continue

        if modules and doc.get("module") not in modules:
            continue

        fields = []
        for f in doc.get("fields", []):
            ftype = f.get("fieldtype")
            if not include_layout and ftype in LAYOUT_FIELDTYPES:
                continue
            sf = simplify_field(f)
            fields.append(sf)
            # record relationship edges
            if "links_to" in sf:
                relationships.append(
                    {"from": name, "field": sf["fieldname"],
                     "kind": "link", "to": sf["links_to"]})
            elif "child_table" in sf:
                relationships.append(
                    {"from": name, "field": sf["fieldname"],
                     "kind": "child_table", "to": sf["child_table"]})

        doctypes[name] = {
            "module": doc.get("module"),
            "is_child_table": bool(doc.get("istable")),
            "is_single": bool(doc.get("issingle")),
            "is_submittable": bool(doc.get("is_submittable")),
            "autoname": doc.get("autoname"),
            "field_count": len(fields),
            "fields": fields,
            # nested Tab -> Section -> Column -> [fieldnames] arrangement
            "layout": build_layout(doc.get("fields", [])),
        }

    return {
        "site": url,
        "doctype_count": len(doctypes),
        "relationship_count": len(relationships),
        "standard_fields": STANDARD_FIELDS,
        "doctypes": doctypes,
        "relationships": relationships,
        "skipped": skipped,
    }


def main():
    p = argparse.ArgumentParser(description="Export ERPNext schema to JSON")
    p.add_argument("--url", default=os.environ.get("ERPNEXT_URL"))
    p.add_argument("--key", default=os.environ.get("ERPNEXT_API_KEY"))
    p.add_argument("--secret", default=os.environ.get("ERPNEXT_API_SECRET"))
    p.add_argument("--modules", nargs="*", default=None,
                   help="Only export DocTypes in these modules (e.g. Accounts Selling Stock)")
    p.add_argument("--include-layout", action="store_true",
                   help="Also include layout-only fields (Section/Column Break, HTML...)")
    p.add_argument("-o", "--output", default="erpnext_schema.json")
    args = p.parse_args()

    if not (args.url and args.key and args.secret):
        p.error("Provide --url/--key/--secret or the ERPNEXT_URL/ERPNEXT_API_KEY/"
                "ERPNEXT_API_SECRET env vars.")

    schema = export(args.url, args.key, args.secret,
                    modules=args.modules, include_layout=args.include_layout)

    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(schema, fh, ensure_ascii=False, indent=2)

    print(f"\nWrote {args.output}: {schema['doctype_count']} doctypes, "
          f"{schema['relationship_count']} relationships, "
          f"{len(schema['skipped'])} skipped.", file=sys.stderr)


if __name__ == "__main__":
    main()
