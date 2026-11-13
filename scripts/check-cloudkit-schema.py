#!/usr/bin/env python3
"""Compares an exported CloudKit Development schema with a schema snapshot (docs/development/release.md, M3).

Before the maintainer deploys the Development schema to Production, which copies every record type, field and
index and can never be undone, the export is compared with the frozen snapshot `schema-v1.txt`. The export is
a CloudKit Schema Language file (`xcrun cktool export-schema ... --output-file <file>`, or the CloudKit
Console's export pasted as text). The script passes only if:

- the record types are exactly `Users`, `CD_<Entity>` for every entity of the snapshot, and `CDMR` when the
  snapshot has a many-to-many relationship (NSPersistentCloudKitContainer keeps those in `CDMR` records);
- every field of a `CD_` type is one of: a system field (`___...`); `CD_entityName` (STRING); `CD_<attribute>`
  for an attribute of that entity, with the type of TYPES; `CD_<relationship>` (STRING, the record name) for
  a to-one relationship; `CD_<attribute>_ckAsset` (ASSET) for a variable-length attribute (`string` or
  `binary`; never for `uuid`, `date`, `int64` or `bool`). Apple, "Reading CloudKit Records for Core Data":
  "All variable length attribute types—String, Binary Data, and Transformable—generate an additional field
  with a key in the form CD_[attribute.name]_ckAsset";
- a field with the type `NUMBER` (bare or `PREFERRED AS INT64`) is what CloudKit Development creates when a
  save adds a numeric field implicitly, before the schema is initialized (Apple, "Integrating a Text-Based
  Schema into Your Workflow"). It is accepted only for an `int64` or `bool` attribute of the snapshot, whose
  expected type is INT64, and listed separately as "implicit"; anywhere else it fails like any other field
  (`PREFERRED AS DOUBLE` on an INT64 field is a wrong type, a NUMBER field outside the snapshot is a stray
  field). `ENCRYPTED <type>` is read, and fails wherever it appears: V1 has no encrypted field;
- every attribute that is not transient and every to-one relationship of the snapshot has its field;
- `CDMR` has only system fields, `CD_entityName` and its own fields (CDMR_FIELDS), and `Users` only system
  fields and `roles LIST<INT64>`;
- the file is read completely: `DEFINE SCHEMA`, then `CREATE ROLE` and `RECORD TYPE` statements, each record
  type with fields (a type from PRIMITIVES, `ENCRYPTED <type>`, `NUMBER [PREFERRED AS INT64|DOUBLE]` or
  `LIST<...>`, then the index qualifiers `QUERYABLE`, `SORTABLE`, `SEARCHABLE`) and
  `GRANT READ|CREATE|WRITE[, ...] TO <role>` lines. Any statement, type, qualifier or token it does not know
  fails the check, and so does a custom role (Dokumentum defines none) or a grant to an unknown role. `//`
  and `--` start a comment to the end of the line, `/* ... */` a comment over several lines.

The output lists every record type field by field, the indexes, the roles and the grants, for the M3 comment
on the issue. TYPES, CDMR_FIELDS, the asset rule and the language follow Apple's two articles named above,
written before the first real export. If the first real export differs in what the mirroring or the language
produces, the difference is reported on the issue and a PR changes this script before the deploy; a mismatch
is never adjusted silently (release.md, M3, "Classifying a failed comparison").

    python3 scripts/check-cloudkit-schema.py <export.ckdb>                     # from the repository root
    python3 scripts/check-cloudkit-schema.py <export.ckdb> --snapshot <schema-vN.txt>
    python3 scripts/check-cloudkit-schema.py --self-test

Exit status: 0 clean, 1 the comparison or the file failed, 2 wrong arguments or an unreadable file.
"""
import importlib.util
import os
import re
import stat
import sys
import tempfile

SNAPSHOT = "Packages/DokumentumCore/Tests/DokumentumCoreTests/Schema/schema-v1.txt"
# An export is a few kilobytes; a larger file is not a schema export.
MAX_BYTES = 1_000_000

# Snapshot type -> CloudKit field type of NSPersistentCloudKitContainer's mirroring (plan of #9, part 3).
TYPES = {
    "string": "STRING",
    "uuid": "STRING",
    "date": "TIMESTAMP",
    "int64": "INT64",
    "bool": "INT64",
    "binary": "BYTES",
}
PRIMITIVES = {"ASSET", "BYTES", "DOUBLE", "INT64", "LOCATION", "STRING", "TIMESTAMP", "REFERENCE"}
ENCRYPTABLE = {"BYTES", "STRING", "DOUBLE", "INT64", "LOCATION", "TIMESTAMP"}
# Snapshot types whose attributes get a `CD_<attribute>_ckAsset` field (variable length).
ASSET_TYPES = {"string", "binary"}
# NUMBER forms accepted where the snapshot expects INT64 (an implicitly created field).
IMPLICIT_INT64 = {"NUMBER", "NUMBER PREFERRED AS INT64"}
QUALIFIERS = {"QUERYABLE", "SORTABLE", "SEARCHABLE"}
PERMISSIONS = {"READ", "CREATE", "WRITE"}
BUILT_IN_ROLES = {"_world", "_icloud", "_creator"}
ENTITY_NAME_FIELD = ("CD_entityName", "STRING")
CDMR = "CDMR"
CDMR_FIELDS = {"CD_entityNames": "STRING", "CD_recordNames": "STRING", "CD_relationships": "STRING"}
USERS = "Users"
USERS_FIELDS = {"roles": "LIST<INT64>"}
ASSET_SUFFIX = "_ckAsset"

TOKEN = re.compile(
    r'(?P<space>\s+)|(?P<comment>(?://|--)[^\n]*|/\*.*?\*/)|"(?P<quoted>[^"\n]*)"'
    r'|(?P<word>[A-Za-z_][A-Za-z0-9_]*)|(?P<symbol>[(),;<>])|(?P<other>.)',
    re.DOTALL,
)


class SchemaError(Exception):
    """The export cannot be read: an unknown statement, type, qualifier or token."""


def load_snapshot_parser():
    """`parse` of check-schema-snapshots.py, so both scripts read the snapshot format the same way."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-schema-snapshots.py")
    spec = importlib.util.spec_from_file_location("check_schema_snapshots", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.parse


def tokenize(text: str):
    """[(kind, value, line)] with kind `name` (a quoted identifier), `word` (a bare word) or `symbol`."""
    tokens, line = [], 1
    for match in TOKEN.finditer(text):
        kind = match.lastgroup
        value = match.group(kind)
        if kind == "other":
            raise SchemaError(f"line {line}: unknown character {value!r}")
        if kind == "quoted":
            tokens.append(("name", value, line))
        elif kind in ("word", "symbol"):
            tokens.append((kind, value, line))
        line += match.group(0).count("\n")
    return tokens


class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.position = 0

    def peek(self, offset=0):
        index = self.position + offset
        return self.tokens[index] if index < len(self.tokens) else ("end", "", self.tokens[-1][2] if self.tokens else 1)

    def take(self):
        token = self.peek()
        self.position += 1
        return token

    def is_keyword(self, word, offset=0):
        kind, value, _ = self.peek(offset)
        return kind == "word" and value.upper() == word

    def expect_keyword(self, word):
        kind, value, line = self.take()
        if kind != "word" or value.upper() != word:
            raise SchemaError(f"line {line}: expected {word}, found {value or 'the end of the file'!r}")

    def expect_symbol(self, symbol):
        kind, value, line = self.take()
        if kind != "symbol" or value != symbol:
            raise SchemaError(f"line {line}: expected {symbol!r}, found {value or 'the end of the file'!r}")

    def name(self, what):
        kind, value, line = self.take()
        if kind not in ("name", "word") or not value:
            raise SchemaError(f"line {line}: expected {what}, found {value or 'the end of the file'!r}")
        return value, line

    def schema(self):
        """{"roles": {name: line}, "types": {name: {"fields": {...}, "grants": [...], "line": n}}}."""
        result = {"roles": {}, "types": {}}
        self.expect_keyword("DEFINE")
        self.expect_keyword("SCHEMA")
        while self.peek()[0] != "end":
            kind, value, line = self.peek()
            if self.is_keyword("CREATE") and self.is_keyword("ROLE", 1):
                self.position += 2
                role, role_line = self.name("a role name")
                if role in result["roles"]:
                    raise SchemaError(f"line {role_line}: role {role} is created twice")
                result["roles"][role] = role_line
            elif self.is_keyword("RECORD") and self.is_keyword("TYPE", 1):
                self.position += 2
                type_name, type_line = self.name("a record type name")
                if type_name in result["types"]:
                    raise SchemaError(f"line {type_line}: record type {type_name} appears twice")
                result["types"][type_name] = self.record_type(type_line)
            else:
                raise SchemaError(f"line {line}: unknown statement starting with {value!r}")
            # Every statement ends with ";"; the last one may end with the file.
            if self.peek()[0] != "end":
                self.expect_symbol(";")
        return result

    def record_type(self, line):
        record = {"fields": {}, "grants": [], "line": line}
        self.expect_symbol("(")
        while True:
            if self.is_keyword("GRANT"):
                record["grants"].append(self.grant())
            else:
                field, field_line = self.name("a field name or GRANT")
                if field in record["fields"]:
                    raise SchemaError(f"line {field_line}: field {field} appears twice")
                field_type = self.field_type()
                qualifiers = []
                while self.peek()[0] == "word":
                    word = self.peek()[1].upper()
                    if word not in QUALIFIERS:
                        raise SchemaError(f"line {self.peek()[2]}: unknown field qualifier {self.peek()[1]!r}")
                    if word in qualifiers:
                        raise SchemaError(f"line {self.peek()[2]}: qualifier {word} appears twice")
                    qualifiers.append(word)
                    self.position += 1
                record["fields"][field] = {"type": field_type, "indexes": qualifiers, "line": field_line}
            kind, value, line = self.take()
            if kind == "symbol" and value == ")":
                return record
            if kind != "symbol" or value != ",":
                raise SchemaError(f"line {line}: expected ',' or ')', found {value or 'the end of the file'!r}")

    def field_type(self):
        if self.is_keyword("LIST"):
            self.position += 1
            self.expect_symbol("<")
            inner = self.primitive("list element type")
            self.expect_symbol(">")
            return f"LIST<{inner}>"
        return self.primitive("field type")

    def primitive(self, what):
        """A primitive type as one normalized string: `STRING`, `ENCRYPTED STRING`, `NUMBER PREFERRED AS INT64`."""
        kind, value, line = self.take()
        word = value.upper() if kind == "word" else ""
        if word == "ENCRYPTED":
            inner_kind, inner, inner_line = self.take()
            if inner_kind != "word" or inner.upper() not in ENCRYPTABLE:
                raise SchemaError(f"line {inner_line}: unknown encrypted {what} {inner or 'the end of the file'!r}")
            return f"ENCRYPTED {inner.upper()}"
        if word == "NUMBER":
            if not self.is_keyword("PREFERRED"):
                return "NUMBER"
            self.position += 1
            self.expect_keyword("AS")
            preferred_kind, preferred, preferred_line = self.take()
            if preferred_kind != "word" or preferred.upper() not in ("INT64", "DOUBLE"):
                raise SchemaError(f"line {preferred_line}: NUMBER PREFERRED AS takes INT64 or DOUBLE, "
                                  f"found {preferred or 'the end of the file'!r}")
            return f"NUMBER PREFERRED AS {preferred.upper()}"
        if word not in PRIMITIVES:
            raise SchemaError(f"line {line}: unknown {what} {value or 'the end of the file'!r}")
        return word

    def grant(self):
        self.expect_keyword("GRANT")
        permissions = []
        while True:
            kind, value, line = self.take()
            if kind != "word" or value.upper() not in PERMISSIONS:
                raise SchemaError(f"line {line}: unknown permission {value!r}")
            permissions.append(value.upper())
            # "GRANT READ, WRITE TO ..." : a comma followed by a permission continues the list.
            following = self.peek(1)
            if self.peek()[:2] == ("symbol", ",") and following[0] == "word" and following[1].upper() in PERMISSIONS:
                self.position += 1
                continue
            break
        self.expect_keyword("TO")
        role, role_line = self.name("a role name")
        return {"permissions": permissions, "role": role, "line": role_line}


def parse_export(text: str):
    return Parser(tokenize(text)).schema()


def expected_from_snapshot(fields):
    """{record type: {field: (CloudKit type, source)}}, {(record type, asset field): source}, problems."""
    expected, assets, problems = {}, {}, []
    entities = sorted(key.split(" ", 1)[1] for key in fields if key.startswith("entity "))
    many_to_many = False
    for entity in entities:
        expected[f"CD_{entity}"] = {}
    for key, values in sorted(fields.items()):
        kind, name = key.split(" ", 1)
        if kind == "entity":
            continue
        entity, prop = name.split(".", 1)
        record = f"CD_{entity}"
        if record not in expected:
            problems.append(f"snapshot: {name} belongs to no entity")
            continue
        if kind == "attribute":
            if values.get("transient") == "yes":
                continue
            snapshot_type = values["type"]
            if snapshot_type not in TYPES:
                problems.append(f"snapshot: {name} has type {snapshot_type}, which has no CloudKit type in TYPES; "
                                "extend the table only from a real export (release.md, M3)")
                continue
            expected[record][f"CD_{prop}"] = (TYPES[snapshot_type], f"{name}, {snapshot_type}")
            if snapshot_type in ASSET_TYPES:
                assets[(record, f"CD_{prop}{ASSET_SUFFIX}")] = f"{name}, {snapshot_type}, variable length"
        else:
            if values.get("many") == "yes":
                inverse = fields.get(f"relationship {values.get('to')}.{values.get('inverse')}", {})
                many_to_many = many_to_many or inverse.get("many") == "yes"
                continue
            expected[record][f"CD_{prop}"] = ("STRING", f"{name}, to-one")
    if many_to_many:
        expected[CDMR] = {}
    expected[USERS] = {}
    return expected, assets, problems


def compare(schema, snapshot_fields):
    """(problems, report lines) for a parsed export against a parsed snapshot."""
    expected, assets, problems = expected_from_snapshot(snapshot_fields)
    report, implicit = [], []
    for role in sorted(schema["roles"]):
        problems.append(f"role {role} (line {schema['roles'][role]}): Dokumentum defines no security roles")
    known_roles = BUILT_IN_ROLES | set(schema["roles"])
    actual = schema["types"]
    for record in sorted(set(expected) - set(actual)):
        problems.append(f"record type {record} is missing")
    for record in sorted(set(actual) - set(expected)):
        problems.append(f"record type {record} (line {actual[record]['line']}) is not in the snapshot")
    indexes, grants = [], []
    for record in sorted(actual):
        report.append(f"{record}")
        fields = actual[record]["fields"]
        wanted = expected.get(record)
        for field in sorted(fields):
            info = fields[field]
            where = f"{record}.{field} (line {info['line']})"
            if info["indexes"]:
                indexes.append(f"{record}.{field} {' '.join(info['indexes'])}")
            note = ""
            if wanted is None:
                verdict = "extra type"
            elif field.startswith("___"):
                verdict = "system"
            elif record == USERS:
                verdict, note = typed(field, info, USERS_FIELDS.get(field), "Users", where, problems)
            elif field == ENTITY_NAME_FIELD[0]:
                verdict, note = typed(field, info, ENTITY_NAME_FIELD[1], "mirroring", where, problems)
            elif record == CDMR:
                verdict, note = typed(field, info, CDMR_FIELDS.get(field), "many-to-many", where, problems)
            elif field in wanted and wanted[field][0] == "INT64" and info["type"] in IMPLICIT_INT64:
                verdict, note = "implicit", f"{wanted[field][1]}; created by a save, read as INT64"
                implicit.append(f"{record}.{field} {info['type']}")
            elif field in wanted:
                verdict, note = typed(field, info, wanted[field][0], wanted[field][1], where, problems)
            elif (record, field) in assets:
                verdict, note = typed(field, info, "ASSET", assets[(record, field)], where, problems)
            else:
                verdict = "EXTRA"
                hint = ""
                if field.endswith(ASSET_SUFFIX):
                    hint = "; an asset field only for a string or binary attribute"
                problems.append(f"{where}: field {field} {info['type']} is not in the snapshot{hint}")
            qualifiers = f"  [{' '.join(info['indexes'])}]" if info["indexes"] else ""
            note = f"  ({note})" if note else ""
            report.append(f"  {verdict:<10} {field} {info['type']}{qualifiers}{note}")
        for field in sorted(set(wanted or {}) - set(fields)):
            problems.append(f"{record}.{field}: missing ({wanted[field][1]} -> {wanted[field][0]})")
            report.append(f"  {'MISSING':<10} {field} {wanted[field][0]}")
        for grant in actual[record]["grants"]:
            grants.append(f"{record}: GRANT {', '.join(grant['permissions'])} TO {grant['role']}")
            if grant["role"] not in known_roles:
                problems.append(f"{record}: GRANT to the unknown role {grant['role']} (line {grant['line']})")
    report.append("Indexes:")
    report += [f"  {line}" for line in indexes] or ["  none"]
    report.append("Implicit NUMBER fields (created by a save before the schema was initialized):")
    report += [f"  {line}" for line in implicit] or ["  none"]
    report.append("Roles: " + (", ".join(sorted(schema["roles"])) or "none created"))
    report.append("Grants:")
    report += [f"  {line}" for line in grants] or ["  none"]
    return problems, report


def typed(field, info, wanted_type, label, where, problems):
    """(verdict, label) for a known field: `ok`, or a wrong type or a field not allowed, with its problem."""
    if wanted_type is None:
        problems.append(f"{where}: field {field} {info['type']} is not allowed here")
        return "EXTRA", ""
    if info["type"] != wanted_type:
        problems.append(f"{where}: field {field} has type {info['type']}, expected {wanted_type} ({label})")
        return "WRONG TYPE", label
    return "ok", label


def read_text(path: str):
    """The file's text, refusing anything that is not a regular file (a FIFO would block) or too large."""
    try:
        mode = os.stat(path).st_mode
    except OSError as error:
        raise OSError(f"{path}: cannot be read ({error.strerror})")
    if not stat.S_ISREG(mode):
        raise OSError(f"{path}: not a regular file")
    with open(path, "rb") as handle:
        data = handle.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise OSError(f"{path}: larger than {MAX_BYTES} bytes, not a schema export")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise OSError(f"{path}: not UTF-8 text")


def check(export_text: str, snapshot_text: str, snapshot_label="snapshot"):
    """(problems, report lines)."""
    parse_snapshot = load_snapshot_parser()
    _, snapshot_fields, snapshot_problems = parse_snapshot(snapshot_text, snapshot_label)
    if snapshot_problems:
        return snapshot_problems, []
    try:
        schema = parse_export(export_text)
    except SchemaError as error:
        return [f"export: {error}"], []
    return compare(schema, snapshot_fields)


SYSTEM_FIELDS = (
    '        "___createTime" TIMESTAMP,\n'
    '        "___createdBy"  REFERENCE,\n'
    '        "___etag"       STRING,\n'
    '        "___modTime"    TIMESTAMP,\n'
    '        "___modifiedBy" REFERENCE,\n'
    '        "___recordID"   REFERENCE QUERYABLE,\n'
)
GRANTS = (
    '        GRANT WRITE TO "_creator",\n'
    '        GRANT CREATE TO "_icloud",\n'
    '        GRANT READ TO "_world"\n'
)


def render(snapshot_text: str, with_assets=True) -> str:
    """A clean export for a snapshot, in the layout of the CloudKit Console's export (self-test only). With
    `with_assets`, every string and binary attribute has its `_ckAsset` field, as Apple documents."""
    _, fields, problems = load_snapshot_parser()(snapshot_text, "snapshot")
    assert not problems, problems
    expected, assets, problems = expected_from_snapshot(fields)
    assert not problems, problems
    out = ["// A synthetic export for the self-test.", "DEFINE SCHEMA", ""]
    for record in sorted(expected):
        lines = [SYSTEM_FIELDS]
        if record == USERS:
            lines.append("        roles           LIST<INT64>,\n")
        elif record == CDMR:
            lines += [f"        {name} {kind},\n" for name, kind in sorted(CDMR_FIELDS.items())]
            lines.append("        CD_entityName STRING,\n")
        else:
            lines.append("        CD_entityName STRING QUERYABLE,\n")
            for field, (kind, _) in sorted(expected[record].items()):
                index = " QUERYABLE SORTABLE" if kind == "TIMESTAMP" else ""
                lines.append(f"        {field} {kind}{index},\n")
            if with_assets:
                lines += [f"        {field} ASSET,\n" for (owner, field) in sorted(assets) if owner == record]
        out.append(f"    RECORD TYPE {record} (\n" + "".join(lines) + GRANTS + "    );\n")
    return "\n".join(out)


def self_test() -> None:
    snapshot = (
        "# V1\n"
        "entity Document uniqueness=none\n"
        "attribute Document.title type=string optional=no default=\"\" external=no transient=no\n"
        "attribute Document.createdAt type=date optional=no default=generated external=no transient=no\n"
        "attribute Document.isInbox type=bool optional=no default=true external=no transient=no\n"
        "attribute Document.pageCount type=int64 optional=no default=0 external=no transient=no\n"
        "attribute Document.id type=uuid optional=no default=generated external=no transient=no\n"
        "relationship Document.file to=DocumentFile many=no optional=yes inverse=document delete=cascade ordered=no\n"
        "relationship Document.tags to=Tag many=yes optional=yes inverse=documents delete=nullify ordered=no\n"
        "entity DocumentFile uniqueness=none\n"
        "attribute DocumentFile.pdfData type=binary optional=yes default=none external=yes transient=no\n"
        "relationship DocumentFile.document to=Document many=no optional=yes inverse=file delete=nullify ordered=no\n"
        "entity Tag uniqueness=none\n"
        "attribute Tag.name type=string optional=no default=\"\" external=no transient=no\n"
        "relationship Tag.documents to=Document many=yes optional=yes inverse=tags delete=nullify ordered=no\n"
        "relationship Tag.children to=Tag many=yes optional=yes inverse=parent delete=nullify ordered=no\n"
        "relationship Tag.parent to=Tag many=no optional=yes inverse=children delete=nullify ordered=no\n"
    )
    clean = render(snapshot)
    tag_record = "    RECORD TYPE CD_Tag (\n"
    in_tag = lambda line: clean.replace(tag_record, tag_record + line)  # noqa: E731
    document_record = "    RECORD TYPE CD_Document (\n"
    in_document = lambda line: clean.replace(document_record, document_record + line)  # noqa: E731

    cases = [
        # (description, export text, expected substring or None)
        ("a clean export, every string and binary attribute with its _ckAsset field", clean, None),
        ("a clean export without the asset fields", render(snapshot, with_assets=False), None),
        ("lower-case keywords and comments", clean.replace("DEFINE SCHEMA", "define schema -- exported")
         .replace("RECORD TYPE CD_Tag (", "record type CD_Tag ( // tags"), None),
        ("a comment over several lines",
         clean.replace("DEFINE SCHEMA\n", "/* exported\n   by cktool */\nDEFINE SCHEMA\n"), None),
        ("an unclosed /* comment", clean.replace("DEFINE SCHEMA\n", "DEFINE SCHEMA\n/* open\n"), "unknown character"),
        ("a grant with two permissions", clean.replace('GRANT WRITE TO "_creator"', 'GRANT READ, WRITE TO "_creator"'),
         None),
        ("all three index qualifiers",
         clean.replace("CD_name STRING,", "CD_name STRING QUERYABLE SEARCHABLE SORTABLE,"), None),
        ("no semicolon after the last statement", clean.rstrip().rstrip(";"), None),
        # The three counter-proof cases of the plan: an extra field, a wrong type, an unknown statement.
        ("an extra field", in_tag("        CD_colour STRING,\n"), "CD_colour STRING is not in the snapshot"),
        ("a wrong field type", clean.replace("CD_title STRING", "CD_title BYTES"),
         "CD_title has type BYTES, expected STRING"),
        ("an unknown statement", clean.replace("DEFINE SCHEMA\n", "DEFINE SCHEMA\n    DROP RECORD TYPE CD_Old;\n"),
         "unknown statement"),
        ("an extra record type", clean + "    RECORD TYPE CD_Draft (\n" + SYSTEM_FIELDS + GRANTS + "    );\n",
         "record type CD_Draft"),
        ("a missing record type", clean.replace("RECORD TYPE CDMR", "RECORD TYPE CDMR_gone"),
         "record type CDMR is missing"),
        ("a missing field", clean.replace("        CD_pageCount INT64,\n", ""), "CD_pageCount: missing"),
        ("a missing to-one relationship field", clean.replace("        CD_parent STRING,\n", ""), "CD_parent: missing"),
        # The asset rule: string and binary attributes only (Apple, "Reading CloudKit Records for Core Data").
        ("an asset field on a date attribute", in_document("        CD_createdAt_ckAsset ASSET,\n"),
         "an asset field only for a string or binary attribute"),
        ("an asset field on a uuid attribute", in_document("        CD_id_ckAsset ASSET,\n"),
         "an asset field only for a string or binary attribute"),
        ("an asset field on an int64 attribute", in_document("        CD_pageCount_ckAsset ASSET,\n"),
         "an asset field only for a string or binary attribute"),
        ("an asset field on a bool attribute", in_document("        CD_isInbox_ckAsset ASSET,\n"),
         "an asset field only for a string or binary attribute"),
        ("an asset field of the wrong type", clean.replace("CD_pdfData_ckAsset ASSET", "CD_pdfData_ckAsset BYTES"),
         "expected ASSET"),
        ("a string's asset field of the wrong type", clean.replace("CD_title_ckAsset ASSET", "CD_title_ckAsset STRING"),
         "expected ASSET"),
        # NUMBER: what an implicit save creates (Apple, "Integrating a Text-Based Schema into Your Workflow").
        ("NUMBER on an int64 attribute", clean.replace("CD_pageCount INT64", "CD_pageCount NUMBER"), None),
        ("NUMBER on a bool attribute", clean.replace("CD_isInbox INT64", "CD_isInbox NUMBER QUERYABLE"), None),
        ("NUMBER PREFERRED AS INT64 on an int64 attribute",
         clean.replace("CD_pageCount INT64", "CD_pageCount NUMBER PREFERRED AS INT64"), None),
        ("NUMBER PREFERRED AS DOUBLE on an int64 attribute",
         clean.replace("CD_pageCount INT64", "CD_pageCount NUMBER PREFERRED AS DOUBLE"),
         "CD_pageCount has type NUMBER PREFERRED AS DOUBLE, expected INT64"),
        ("NUMBER on a string attribute", clean.replace("CD_title STRING", "CD_title NUMBER"),
         "CD_title has type NUMBER, expected STRING"),
        ("NUMBER on a date attribute", clean.replace("CD_createdAt TIMESTAMP", "CD_createdAt NUMBER"),
         "CD_createdAt has type NUMBER, expected TIMESTAMP"),
        ("a stray NUMBER field", in_tag("        CD_sortOrder NUMBER,\n"),
         "CD_sortOrder NUMBER is not in the snapshot"),
        ("NUMBER PREFERRED AS STRING", clean.replace("CD_pageCount INT64", "CD_pageCount NUMBER PREFERRED AS STRING"),
         "PREFERRED AS takes INT64 or DOUBLE"),
        ("NUMBER PREFERRED without AS", clean.replace("CD_pageCount INT64", "CD_pageCount NUMBER PREFERRED INT64"),
         "expected AS"),
        # ENCRYPTED: read, never expected in V1.
        ("ENCRYPTED on a string attribute", clean.replace("CD_title STRING", "CD_title ENCRYPTED STRING"),
         "CD_title has type ENCRYPTED STRING, expected STRING"),
        ("a stray ENCRYPTED field", in_tag("        CD_secret ENCRYPTED BYTES,\n"),
         "CD_secret ENCRYPTED BYTES is not in the snapshot"),
        ("ENCRYPTED ASSET", clean.replace("CD_title STRING", "CD_title ENCRYPTED ASSET"),
         "unknown encrypted field type"),
        ("a to-many relationship as a field", in_tag("        CD_documents STRING,\n"), "not in the snapshot"),
        ("a to-one relationship as a reference", clean.replace("CD_parent STRING", "CD_parent REFERENCE"),
         "expected STRING"),
        ("a wrong CD_entityName type", clean.replace("CD_entityName STRING QUERYABLE", "CD_entityName INT64", 1),
         "expected STRING"),
        ("an extra field in CDMR", clean.replace("        CD_recordNames STRING,\n",
                                                 "        CD_recordNames STRING,\n        CD_extra STRING,\n"),
         "not allowed here"),
        ("an extra field in Users", clean.replace("        roles           LIST<INT64>,\n",
                                                  "        roles           LIST<INT64>,\n        nickname STRING,\n"),
         "not allowed here"),
        ("a custom role", clean.replace("DEFINE SCHEMA\n", "DEFINE SCHEMA\n    CREATE ROLE Admin;\n"),
         "defines no security roles"),
        ("a grant to an unknown role", clean.replace('GRANT READ TO "_world"', 'GRANT READ TO "Admin"', 1),
         "unknown role"),
        ("an unknown permission", clean.replace('GRANT CREATE TO', 'GRANT DELETE TO', 1), "unknown permission"),
        ("an unknown index qualifier", clean.replace("CD_name STRING,", "CD_name STRING INDEXED,"),
         "unknown field qualifier"),
        ("an unknown field type", clean.replace("CD_name STRING,", "CD_name ENCRYPTED_STRING,"), "unknown field type"),
        ("an unknown list element type", clean.replace("LIST<INT64>", "LIST<BOOLEAN>"), "unknown list element"),
        ("a field twice", in_tag("        CD_name STRING,\n"), "appears twice"),
        ("a record type twice", clean + "    RECORD TYPE CD_Tag (\n" + SYSTEM_FIELDS + GRANTS + "    );\n",
         "appears twice"),
        ("no DEFINE SCHEMA", clean.replace("DEFINE SCHEMA", ""), "expected DEFINE"),
        ("an unclosed record type", clean.rstrip().rstrip(";").rstrip(")"), "expected ',' or ')'"),
        ("a missing semicolon between statements", clean.replace(");\n", ")\n", 1), "expected ';'"),
        ("an unknown character", clean.replace("CD_name STRING,", "CD_name STRING = 1,"), "unknown character"),
        ("an empty file", "", "expected DEFINE"),
    ]
    for description, text, expected in cases:
        problems, report = check(text, snapshot)
        if expected is None:
            assert problems == [], f"{description}: expected no problems, got {problems}"
        else:
            assert any(expected in problem for problem in problems), \
                f"{description}: expected a problem with {expected!r}, got {problems}"
    # The report lists every field, the indexes and the implicit NUMBER fields.
    problems, report = check(clean, snapshot)
    assert "  ok         CD_title STRING  (Document.title, string)" in report, report
    assert "  ok         CD_title_ckAsset ASSET  (Document.title, string, variable length)" in report, report
    assert "  ok         CD_pdfData_ckAsset ASSET  (DocumentFile.pdfData, binary, variable length)" in report, report
    assert "  system     ___recordID REFERENCE  [QUERYABLE]" in report, report
    assert "  CD_Document.CD_createdAt QUERYABLE SORTABLE" in report, report
    assert "  CD_Tag: GRANT READ TO _world" in report, report
    _, report = check(clean.replace("CD_pageCount INT64", "CD_pageCount NUMBER"), snapshot)
    implicit_line = "  implicit   CD_pageCount NUMBER  (Document.pageCount, int64; created by a save, read as INT64)"
    assert implicit_line in report, report
    assert "  CD_Document.CD_pageCount NUMBER" in report, report
    # The reader refuses what is not a regular file, and a missing file, without blocking.
    with tempfile.TemporaryDirectory() as root:
        fifo = os.path.join(root, "export.ckdb")
        os.mkfifo(fifo)
        for path in (fifo, root, os.path.join(root, "missing.ckdb")):
            try:
                read_text(path)
                raise AssertionError(f"read_text accepted {path}")
            except OSError:
                pass
    count = len(cases) + 3
    # The committed snapshot: a clean export of it passes with Apple's 12 string and 2 binary _ckAsset fields,
    # and fails on an asset field of a date attribute. The cases above therefore use a format that exists.
    if os.path.isfile(SNAPSHOT):
        real = read_text(SNAPSHOT)
        rendered = render(real)
        asset_lines = [line for line in rendered.split("\n") if line.strip().endswith("_ckAsset ASSET,")]
        assert len(asset_lines) == 14, f"{SNAPSHOT}: expected 12 string and 2 binary asset fields, got {asset_lines}"
        problems, _ = check(rendered, real, snapshot_label=SNAPSHOT)
        assert problems == [], f"a clean export of {SNAPSHOT} fails: {problems}"
        record = "    RECORD TYPE CD_Document (\n"
        problems, _ = check(rendered.replace(record, record + "        CD_documentDate_ckAsset ASSET,\n"), real,
                            snapshot_label=SNAPSHOT)
        assert any("CD_documentDate_ckAsset" in problem for problem in problems), problems
        count += 2
    print(f"self-test passed ({count} cases)")


def main(arguments) -> int:
    usage = "usage: check-cloudkit-schema.py <export> [--snapshot <schema-vN.txt>] | --self-test"
    export, snapshot = None, SNAPSHOT
    rest = list(arguments)
    while rest:
        argument = rest.pop(0)
        if argument == "--snapshot" and rest:
            snapshot = rest.pop(0)
        elif not argument.startswith("-") and export is None:
            export = argument
        else:
            print(usage)
            return 2
    if export is None:
        print(usage)
        return 2
    try:
        export_text = read_text(export)
        snapshot_text = read_text(snapshot)
    except OSError as error:
        print(f"error: {error}")
        return 2
    problems, report = check(export_text, snapshot_text, snapshot_label=snapshot)
    print(f"Export {export} against {snapshot}")
    for line in report:
        print(line)
    for problem in problems:
        print(f"error: {problem}")
    if problems:
        print(f"NOT CLEAN: {len(problems)} problem(s); do not deploy, classify them first (release.md, M3)")
        return 1
    print("CLEAN: the export matches the snapshot")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main(sys.argv[1:]))
