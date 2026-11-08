#!/usr/bin/env python3
"""Run the shipped FTS5 schema on SQLite, without claiming Swift/XCTest execution.

The schema is extracted directly from FTSIndex.swift. Fixtures exercise SQLite's
tokenizer, ranking, bound MATCH arguments, filtering and transaction semantics.
The small Python reconciliation harness checks the same intended authoritative
snapshot behavior; native FTSIndexTests cover the Swift implementation on iOS.
No application database is read or modified.
"""
from __future__ import annotations

from pathlib import Path
import hashlib
import json
import re
import sqlite3
import tempfile
import textwrap
import unicodedata
import unittest


ROOT = Path(__file__).resolve().parents[1]


def shipped_schema() -> str:
    source = (ROOT / "ArhitektOffice/Services/FTSIndex.swift").read_text()
    match = re.search(r"static\s+let\s+schemaSQL\s*=\s*\"\"\"\n(.*?)\n\s*\"\"\"", source, re.S)
    if not match:
        raise AssertionError("FTSIndex.swift must expose the actual static schemaSQL literal")
    schema = textwrap.dedent(match.group(1))
    if "\\(" in schema:
        raise AssertionError("Interpolated schema cannot be safely executed by this test")
    return schema


def escaped_prefix_query(value: str) -> str:
    """Reference input escaping, not execution of the Swift query parser."""
    normalized = "".join(
        character for character in unicodedata.normalize("NFD", value.lower())
        if not unicodedata.combining(character)
    )
    words = re.findall(r"[^\W_]+", normalized)
    words = [word[:4] for word in words if len(word) >= 3]
    return " OR ".join('"' + word.replace('"', '""') + '"*' for word in dict.fromkeys(words))


class FTSSQLTests(unittest.TestCase):
    def setUp(self) -> None:
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(shipped_schema())

    def tearDown(self) -> None:
        self.db.close()

    def insert(self, identifier: str, body: str, *, title: str = "Projekt", project: str = "cerje",
               kind: str = "note", status: str | None = None, created: float = 1_000,
               due: float | None = None, start: int = 0) -> None:
        self.db.execute(
            "INSERT INTO source_fts(title,body,source_id,record_type,project_id,created_at,due_at,status,source_start,source_end) "
            "VALUES(?,?,?,?,?,?,?,?,?,?)",
            (title, body, identifier, kind, project, created, due, status, start, start + len(body.encode("utf-16-le")) // 2),
        )

    def matches(self, query: str, extra_sql: str = "", extra_values: tuple = ()) -> list[str]:
        return [row[0] for row in self.db.execute(
            "SELECT source_id FROM source_fts WHERE source_fts MATCH ? " + extra_sql +
            " ORDER BY bm25(source_fts,2.0,1.0),CAST(created_at AS REAL) DESC",
            (query,) + extra_values,
        )]

    def test_croatian_diacritics_and_four_character_prefix(self) -> None:
        self.insert("one", "Geodeta zanima projekt u Čakovcu. Trebam nazvati statičara.")
        self.assertEqual(self.matches('"cako"*'), ["one"])
        self.assertEqual(self.matches('"stat"*'), ["one"])
        self.assertEqual(self.matches('"geod"*'), ["one"])
        self.assertEqual(self.matches('"fasad"*'), [])

    def test_bm25_prioritizes_relevant_title(self) -> None:
        self.insert("body", "Geodet mora dostaviti podlogu.", title="Sastanak")
        self.insert("title", "Podloga još nije stigla.", title="Geodet za Cerje")
        self.assertEqual(self.matches('"geod"*')[0], "title")

    def test_bound_escaped_match_cannot_inject_sql_or_fts_operators(self) -> None:
        self.insert("safe", "Geodet šalje podlogu.")
        hostile = 'geodet\" OR 1=1; DROP TABLE source_fts; -- NOT ("'
        self.assertIn("safe", self.matches(escaped_prefix_query(hostile)))
        self.assertEqual(self.db.execute("SELECT count(*) FROM source_fts").fetchone()[0], 1)
        self.assertEqual(self.matches('"literal"*'), [])

    def test_all_long_transcript_chunks_are_searchable_with_source_offsets(self) -> None:
        text = "Početak razgovora. " * 2_000 + "Zadnji dogovor: geodet šalje podlogu u petak."
        # Fixtures index every overlapping window; SQLite must find the ending,
        # unlike the former 1,600-character prefix-only context implementation.
        for start in range(0, len(text), 800):
            self.insert("long", text[start:start + 1_000], kind="transcript", start=start)
        hits = self.db.execute(
            "SELECT body,source_start,source_end FROM source_fts WHERE source_fts MATCH ?",
            ('"geod"*',),
        ).fetchall()
        self.assertTrue(hits)
        self.assertTrue(any("Zadnji dogovor" in body for body, _, _ in hits))
        for body, start, end in hits:
            self.assertEqual(text[start:end], body)
            self.assertGreater(start, 1_600)

    def test_current_open_status_does_not_return_resolved_issue_or_old_transcript(self) -> None:
        self.insert("open", "Nedostaje podloga geodeta.", kind="issue", status="open")
        self.insert("resolved", "Nedostaje podloga geodeta.", kind="issue", status="closed")
        self.insert("history", "Problem s geodetom bio je otvoren.", kind="transcript")
        self.assertEqual(self.matches('"geod"*', "AND record_type IN ('task','issue') AND status = ?", ("open",)), ["open"])

    def test_project_filter_uses_bound_identity(self) -> None:
        self.insert("cerje", "Geodet čeka dogovor.", project="cerje")
        self.insert("petrinja", "Geodet čeka dogovor.", project="petrinja")
        self.assertEqual(self.matches('"geod"*', "AND project_id = ?", ("cerje",)), ["cerje"])
        self.assertEqual(self.matches('"geod"*', "AND project_id = ?", ("cerje' OR 1=1 --",)), [])

    def test_task_week_filter_uses_due_date_with_half_open_bounds(self) -> None:
        self.insert("old-created-due-now", "Nazvati geodeta.", kind="task", status="open", created=10, due=150)
        self.insert("new-created-due-later", "Nazvati geodeta.", kind="task", status="open", created=150, due=300)
        self.insert("no-date", "Nazvati geodeta.", kind="task", status="open", created=150)
        self.insert("at-end", "Nazvati geodeta.", kind="task", status="open", created=150, due=200)
        self.assertEqual(self.matches('"geod"*', "AND record_type='task' AND status='open' AND due_at >= ? AND due_at < ?", (100, 200)), ["old-created-due-now"])

    def test_mixed_week_filter_uses_issue_creation_and_task_due_dates(self) -> None:
        self.insert("task-due-this-week", "Geodet.", kind="task", status="open", created=10, due=150)
        self.insert("task-created-this-week", "Geodet.", kind="task", status="open", created=150, due=300)
        self.insert("issue-created-this-week", "Geodet.", kind="issue", status="open", created=150)
        self.insert("old-issue", "Geodet.", kind="issue", status="open", created=10)
        field = "CASE WHEN record_type='task' THEN CAST(due_at AS REAL) ELSE CAST(created_at AS REAL) END"
        matches = self.matches('"geod"*', f"AND status='open' AND {field} >= ? AND {field} < ?", (100, 200))
        self.assertEqual(set(matches), {"task-due-this-week", "issue-created-this-week"})

    def test_failed_write_rolls_back_fts_changes(self) -> None:
        self.insert("existing", "Izvorni geodet.")
        self.db.execute("INSERT INTO documents(source_id,fingerprint) VALUES (?,?)", ("existing", "original-fingerprint"))
        self.db.commit()
        with self.assertRaises(sqlite3.Error):
            with self.db:
                self.db.execute("DELETE FROM source_fts")
                self.db.execute("DELETE FROM documents")
                self.insert("new", "Drugi geodet.")
                self.db.execute("INSERT INTO documents(source_id,fingerprint) VALUES (?,?)", ("new", "new-fingerprint"))
                self.db.execute("INSERT INTO documents(source_id,fingerprint) VALUES (?,?)", ("new", "duplicate-must-fail"))
        self.assertEqual(self.matches('"geod"*'), ["existing"])
        self.assertEqual(self.db.execute("SELECT source_id,fingerprint FROM documents").fetchall(), [("existing", "original-fingerprint")])

    def test_index_survives_disk_connection_reopen(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fts.sqlite"
            with sqlite3.connect(path) as db:
                db.executescript(shipped_schema())
                db.execute(
                    "INSERT INTO source_fts(title,body,source_id,record_type,project_id,created_at,due_at,status,source_start,source_end) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    ("Cerje", "Geodet čeka.", "durable", "note", "cerje", 1_000, None, None, 0, 12),
                )
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT source_id FROM source_fts WHERE source_fts MATCH ?", ('"geod"*',)).fetchall(), [("durable",)])

    def test_authoritative_restore_removes_stale_sources_and_updates_same_uuid(self) -> None:
        # An index is a cache, never the authority after a SwiftData restore.
        def reconcile(snapshot: dict[str, str]) -> int:
            updated = 0
            with self.db:
                existing = dict(self.db.execute("SELECT source_id,fingerprint FROM documents"))
                for identifier in existing.keys() - snapshot.keys():
                    self.db.execute("DELETE FROM source_fts WHERE source_id = ?", (identifier,))
                    self.db.execute("DELETE FROM documents WHERE source_id = ?", (identifier,))
                for identifier, body in snapshot.items():
                    fingerprint = hashlib.sha256(json.dumps({"id": identifier, "text": body}, sort_keys=True).encode()).hexdigest()
                    if existing.get(identifier) == fingerprint:
                        continue
                    self.db.execute("DELETE FROM source_fts WHERE source_id = ?", (identifier,))
                    self.db.execute("DELETE FROM documents WHERE source_id = ?", (identifier,))
                    self.insert(identifier, body)
                    self.db.execute("INSERT INTO documents(source_id,fingerprint) VALUES (?,?)", (identifier, fingerprint))
                    updated += 1
            return updated
        initial = {"same": "Stari dogovor s geodetom.", "removed": "Obrisani geodet."}
        self.assertEqual(reconcile(initial), 2)
        self.assertEqual(reconcile(initial), 0)
        self.assertEqual(reconcile({"same": "Novi dogovor sa statičarom."}), 1)
        self.assertEqual(self.matches('"geod"*'), [])
        self.assertEqual(self.matches('"stat"*'), ["same"])
        self.assertEqual(self.db.execute("SELECT count(*) FROM source_fts").fetchone()[0], 1)
        self.assertEqual([row[0] for row in self.db.execute("SELECT source_id FROM documents")], ["same"])


if __name__ == "__main__":
    print(f"SQLite {sqlite3.sqlite_version}; executing schema extracted from FTSIndex.swift")
    unittest.main(verbosity=2)
