"""Compare a recorded JSON body with a spec schema: undeclared keys,
required keys missing, nulls in non-nullable properties, enum misses."""
import json, sys
spec = json.load(open(sys.argv[1]))
schemas = spec["components"]["schemas"]

def resolve(s):
    while "$ref" in s:
        s = schemas[s["$ref"].split("/")[-1]]
    return s

def walk(value, schema, path, out, depth=0):
    schema = resolve(schema)
    for key in ("allOf", "anyOf", "oneOf"):
        if key in schema and isinstance(value, dict):
            props = {}
            req = []
            for sub in schema[key]:
                sub = resolve(sub)
                props.update(sub.get("properties", {}))
                req += sub.get("required", []) if key == "allOf" else []
            schema = {"type": "object", "properties": props, "required": req, "nullable": schema.get("nullable")}
    if value is None:
        if not schema.get("nullable"):
            out.append(f"NULL-NOT-NULLABLE {path}")
        return
    if "enum" in schema and value not in schema["enum"]:
        out.append(f"ENUM-MISS {path} = {value!r} not in {schema['enum']}")
    if isinstance(value, dict) and "properties" in schema:
        props = schema["properties"]
        for k in value:
            if k not in props:
                out.append(f"UNDECLARED {path}.{k}")
        for k in schema.get("required", []):
            if k not in value:
                out.append(f"MISSING-REQUIRED {path}.{k}")
        if depth < 6:
            for k, v in value.items():
                if k in props:
                    walk(v, props[k], f"{path}.{k}", out, depth + 1)
    elif isinstance(value, list) and "items" in schema and depth < 6:
        for i, v in enumerate(value[:3]):
            walk(v, schema["items"], f"{path}[{i}]", out, depth + 1)

body_path, schema_name = sys.argv[2], sys.argv[3]
raw = open(body_path, "rb").read()
if body_path.endswith(".http"):
    raw = raw.split(b"\n\n", 1)[1]
value = json.loads(raw)
if len(sys.argv) > 4:
    for key in sys.argv[4].split("."):
        value = value[key]
out = []
walk(value, {"$ref": "#/components/schemas/" + schema_name}, schema_name, out)
print("\n".join(sorted(set(out))) or "(no differences)")
