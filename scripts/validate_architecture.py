#!/usr/bin/env python3
"""Check architecture artifacts with stdlib; not full OpenAPI or runtime validation."""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE_ENTITIES = (
    "users profiles sessions devices friendships follows blocks posts post_media "
    "comments reactions stories story_views conversations conversation_members "
    "messages message_reactions notifications communities community_members events "
    "reports moderation_actions user_interests recommendations"
).split()
METHODS = {"get", "post", "put", "patch", "delete", "options", "head", "trace"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def walk(value, location=""):
    yield location, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, location + "/" + str(key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, location + "/" + str(index))


def resolve(document, reference):
    require(reference.startswith("#/"), f"Unexpected external reference: {reference}")
    result = document
    for part in reference[2:].split("/"):
        result = result[part.replace("~1", "/").replace("~0", "~")]
    return result


def check_documents():
    documents = [ROOT / "README.md", *sorted((ROOT / "docs").rglob("*.md"))]
    link_count = 0
    for document in documents:
        content = document.read_text()
        require(content.count("```") % 2 == 0, f"Unclosed code fence: {document}")
        for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", content):
            if target.startswith(("https://", "http://", "#")):
                continue
            require((document.parent / target.split("#", 1)[0]).exists(),
                    f"Broken document link: {document.name} -> {target}")
            link_count += 1
    design = (ROOT / "docs/database/03-database-design.md").read_text()
    sections = re.split(r"(?=^### \d+\.\d+ `)", design, flags=re.M)
    by_name = {}
    for section in sections:
        heading = re.match(r"### \d+\.\d+ `([^`]+)`", section)
        if heading:
            by_name[heading.group(1)] = section
    require(set(by_name) == set(CORE_ENTITIES), "Core database entity set differs from brief")
    for name in CORE_ENTITIES:
        section = by_name[name].lower()
        for label in ("purpose", "columns", "foreign keys", "indexes", "partitioning", "expected growth"):
            require(label in section, f"Missing {label} in entity {name}")
        require("primary key" in section or "pk" in section, f"Missing PK in {name}")
    return len(documents), link_count


def check_openapi():
    spec = json.loads((ROOT / "docs/api/openapi-mvp.json").read_text())
    require(spec["openapi"] == "3.1.1", "Unexpected OpenAPI version")
    require("placeholder.invalid" in spec["servers"][0]["url"], "Undeclared deployed host")
    references = 0
    for location, item in walk(spec):
        if isinstance(item, dict) and "$ref" in item:
            resolve(spec, item["$ref"])
            references += 1

    operation_ids = set()
    for path, path_item in spec["paths"].items():
        for method, operation in path_item.items():
            require(method in METHODS, f"Unknown operation key {method}: {path}")
            name = operation["operationId"]
            require(name not in operation_ids, f"Duplicate operation ID {name}")
            operation_ids.add(name)
            require(operation.get("x-authorization-policy"), f"Missing policy {name}")
            require(operation.get("x-release") == "mvp", f"Unlabeled release {name}")
            require("429" in operation["responses"], f"Missing rate limit {name}")
            params = [resolve(spec, item["$ref"]) if "$ref" in item else item
                      for item in operation.get("parameters", [])]
            unique = {(item["name"], item["in"]) for item in params}
            require(len(unique) == len(params), f"Duplicate parameter {name}")
            path_names = {item["name"] for item in params if item["in"] == "path"}
            require(path_names == set(re.findall(r"{(\w+)}", path)), f"Path parameters {name}")
            require(all(item.get("required") for item in params if item["in"] == "path"),
                    f"Optional path parameter {name}")
            if operation["x-idempotency"] == "required-header-and-body-hash":
                require(any(item["name"] == "Idempotency-Key" and item.get("required")
                            for item in params), f"Missing retry header {name}")
            if any(item["name"] == "If-Match" for item in params):
                require({"412", "428"} <= operation["responses"].keys(),
                        f"Missing version failure responses {name}")
            for security in operation["security"]:
                require(set(security) <= spec["components"]["securitySchemes"].keys(),
                        f"Unknown authentication scheme {name}")
            if "requestBody" in operation:
                body = operation["requestBody"]["content"]["application/json"]["schema"]
                require("$ref" in body, f"Untyped body {name}")
                body_schema = resolve(spec, body["$ref"])
                require(body_schema.get("additionalProperties") is False,
                        f"Unknown fields accepted in body {name}")
            for status, response in operation["responses"].items():
                require(re.fullmatch(r"[1-5][0-9]{2}", status), f"Invalid status {name}/{status}")
                if status == "204":
                    require("content" not in response, f"Unexpected 204 body {name}")
                elif status.startswith("2"):
                    require("schema" in response["content"]["application/json"],
                            f"Untyped response {name}/{status}")

    for schema_name, schema in spec["components"]["schemas"].items():
        for location, node in walk(schema, schema_name):
            if not isinstance(node, dict):
                continue
            node_type = node.get("type")
            node_types = node_type if isinstance(node_type, list) else [node_type]
            if "string" in node_types and "enum" not in node:
                require("maxLength" in node or node.get("format") in {"uuid", "date-time"},
                        f"Unbounded string {location}")
            if "array" in node_types:
                require("maxItems" in node and "items" in node, f"Unbounded array {location}")
            if "integer" in node_types or "number" in node_types:
                require("minimum" in node and "maximum" in node, f"Unbounded number {location}")
            if "object" in node_types and node.get("additionalProperties") is not False:
                require("maxProperties" in node, f"Unbounded object {location}")

    for name in ("SelfProfile", "PrivacySettings", "Post", "Comment", "Message",
                 "Conversation", "Highlight", "InterestPassport", "NotificationPreferences"):
        require("version" in spec["components"]["schemas"][name]["properties"],
                f"Missing resource version {name}")
    forbidden = {"body", "text", "language", "replyToSequence", "reactionType", "mediaIds",
                 "attachmentKey", "filename"}
    for name in ("MessageCreate", "MessagePatch", "Message"):
        properties = spec["components"]["schemas"][name]["properties"]
        require(not forbidden.intersection(properties), f"Plaintext chat field in {name}")
        require("deviceEnvelopes" in properties or "ciphertext" in properties,
                f"Missing ciphertext contract in {name}")
    for name in ("MessageRequestCreate", "MessageRequest", "FriendRequestCreate"):
        properties = spec["components"]["schemas"][name]["properties"]
        require(not {"intro", "body", "message", "text"}.intersection(properties),
                f"Private plaintext before chat consent in {name}")
    reaction = spec["paths"]["/conversations/{conversationId}/messages/{messageId}/reactions"]["post"]
    reaction_schema = reaction["requestBody"]["content"]["application/json"]["schema"]
    require(reaction_schema["$ref"] == "#/components/schemas/MessageCreate",
            "Chat reaction transport must use encrypted control envelopes")
    require("encryptionMode" in spec["components"]["schemas"]["UploadCreate"]["required"],
            "Upload encryption mode must be explicit")
    return len(spec["paths"]), len(operation_ids), len(spec["components"]["schemas"]), references


def main():
    documents, links = check_documents()
    paths, operations, schemas, references = check_openapi()
    print(f"PASS: {documents} Markdown documents; {links} resolved local links; "
          f"{len(CORE_ENTITIES)} core entities.")
    print(f"PASS: {paths} API paths; {operations} unique operations; {schemas} schemas; "
          f"{references} resolved references; bounds/auth/retry/version checks.")
    print("PASS: ciphertext-only chat schemas, encrypted reaction commands and explicit upload modes.")
    print("Scope: structural artifact checks only; no full OpenAPI validator or application tests.")


if __name__ == "__main__":
    main()
