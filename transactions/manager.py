from __future__ import annotations

import csv
import json
import sqlite3
from dataclasses import dataclass
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Iterable, Optional


@dataclass(frozen=True)
class ItemLine:
    item_name: str
    price: float
    quantity: float

    @property
    def total(self) -> float:
        return round(self.price * self.quantity, 2)


class TransactionManager:
    """Offline-first local financial and transaction manager backed by SQLite."""

    def __init__(self, db_path: str | Path = "transactions.db") -> None:
        self.db_path = str(db_path)
        self._conn = sqlite3.connect(self.db_path)
        self._conn.row_factory = sqlite3.Row
        self._init_db()

    def _init_db(self) -> None:
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS daily_cash (
                day TEXT PRIMARY KEY,
                starting_cash REAL NOT NULL DEFAULT 0,
                adjustments REAL NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS transactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL CHECK(kind IN ('purchase', 'sale', 'expense')),
                party_type TEXT,
                party_name TEXT,
                notes TEXT,
                branch TEXT,
                user_name TEXT,
                status TEXT NOT NULL CHECK(status IN ('draft', 'finalized')),
                total REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                finalized_at TEXT,
                day TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS transaction_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                transaction_id INTEGER NOT NULL,
                item_name TEXT NOT NULL,
                price REAL NOT NULL,
                quantity REAL NOT NULL,
                line_total REAL NOT NULL,
                FOREIGN KEY(transaction_id) REFERENCES transactions(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS receipts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                transaction_id INTEGER NOT NULL UNIQUE,
                receipt_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY(transaction_id) REFERENCES transactions(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS price_list (
                item_name TEXT PRIMARY KEY,
                regular_price REAL NOT NULL,
                extra_price REAL NOT NULL
            );
            """
        )
        self._conn.commit()

    @staticmethod
    def _day(day: Optional[str] = None) -> str:
        return day or date.today().isoformat()

    def close(self) -> None:
        self._conn.close()

    def set_starting_cash(self, amount: float, day: Optional[str] = None) -> None:
        day_value = self._day(day)
        self._conn.execute(
            """
            INSERT INTO daily_cash (day, starting_cash, adjustments)
            VALUES (?, ?, COALESCE((SELECT adjustments FROM daily_cash WHERE day = ?), 0))
            ON CONFLICT(day) DO UPDATE SET starting_cash = excluded.starting_cash
            """,
            (day_value, float(amount), day_value),
        )
        self._conn.commit()

    def add_adjustment(self, amount: float, day: Optional[str] = None) -> None:
        day_value = self._day(day)
        self._conn.execute(
            """
            INSERT INTO daily_cash (day, starting_cash, adjustments)
            VALUES (?, 0, ?)
            ON CONFLICT(day) DO UPDATE SET adjustments = daily_cash.adjustments + excluded.adjustments
            """,
            (day_value, float(amount)),
        )
        self._conn.commit()

    def create_draft_transaction(
        self,
        kind: str,
        item_lines: Iterable[ItemLine],
        party_type: Optional[str] = None,
        party_name: Optional[str] = None,
        notes: str = "",
        branch: str = "Default Branch",
        user_name: str = "Default User",
        day: Optional[str] = None,
    ) -> int:
        day_value = self._day(day)
        created_at = datetime.now(UTC).isoformat()
        total = round(sum(item.total for item in item_lines), 2)
        cur = self._conn.execute(
            """
            INSERT INTO transactions (
                kind, party_type, party_name, notes, branch, user_name,
                status, total, created_at, day
            ) VALUES (?, ?, ?, ?, ?, ?, 'draft', ?, ?, ?)
            """,
            (kind, party_type, party_name, notes, branch, user_name, total, created_at, day_value),
        )
        transaction_id = int(cur.lastrowid)
        for item in item_lines:
            self._conn.execute(
                """
                INSERT INTO transaction_items (transaction_id, item_name, price, quantity, line_total)
                VALUES (?, ?, ?, ?, ?)
                """,
                (transaction_id, item.item_name, float(item.price), float(item.quantity), item.total),
            )
        self._conn.commit()
        return transaction_id

    def create_expense_draft(self, amount: float, notes: str, day: Optional[str] = None) -> int:
        return self.create_draft_transaction(
            kind="expense",
            item_lines=[ItemLine(item_name="Expense", price=float(amount), quantity=1)],
            notes=notes,
            day=day,
        )

    def finalize_transaction(self, transaction_id: int) -> dict:
        tx = self._conn.execute(
            "SELECT * FROM transactions WHERE id = ?",
            (transaction_id,),
        ).fetchone()
        if tx is None:
            raise ValueError(f"Transaction {transaction_id} does not exist")
        if tx["status"] == "finalized":
            return self.get_receipt(transaction_id)

        finalized_at = datetime.now(UTC).isoformat()
        self._conn.execute(
            "UPDATE transactions SET status = 'finalized', finalized_at = ? WHERE id = ?",
            (finalized_at, transaction_id),
        )
        receipt = self._build_receipt(transaction_id)
        self._conn.execute(
            "INSERT INTO receipts (transaction_id, receipt_json, created_at) VALUES (?, ?, ?)",
            (transaction_id, json.dumps(receipt), finalized_at),
        )
        self._conn.commit()
        return receipt

    def _build_receipt(self, transaction_id: int) -> dict:
        tx = self._conn.execute("SELECT * FROM transactions WHERE id = ?", (transaction_id,)).fetchone()
        items = self._conn.execute(
            "SELECT item_name, price, quantity, line_total FROM transaction_items WHERE transaction_id = ? ORDER BY id",
            (transaction_id,),
        ).fetchall()
        itemized = [
            {
                "item_name": row["item_name"],
                "price": row["price"],
                "quantity": row["quantity"],
                "line_total": row["line_total"],
            }
            for row in items
        ]
        return {
            "date": tx["day"],
            "branch": tx["branch"],
            "user": tx["user_name"],
            "kind": tx["kind"],
            "party_type": tx["party_type"],
            "party_name": tx["party_name"],
            "notes": tx["notes"],
            "items": itemized,
            "subtotal": tx["total"],
            "total": tx["total"],
        }

    def get_receipt(self, transaction_id: int) -> dict:
        row = self._conn.execute(
            "SELECT receipt_json FROM receipts WHERE transaction_id = ?",
            (transaction_id,),
        ).fetchone()
        if row is None:
            raise ValueError(f"Receipt for transaction {transaction_id} does not exist")
        return json.loads(row["receipt_json"])

    def list_drafts(self) -> list[sqlite3.Row]:
        rows = self._conn.execute(
            "SELECT * FROM transactions WHERE status = 'draft' ORDER BY created_at DESC"
        ).fetchall()
        return list(rows)

    def remaining_cash(self, day: Optional[str] = None) -> float:
        day_value = self._day(day)
        daily = self._conn.execute(
            "SELECT starting_cash, adjustments FROM daily_cash WHERE day = ?",
            (day_value,),
        ).fetchone()
        start_cash = float(daily["starting_cash"]) if daily else 0.0
        adjustments = float(daily["adjustments"]) if daily else 0.0

        sums = self._conn.execute(
            """
            SELECT
                COALESCE(SUM(CASE WHEN kind = 'sale' THEN total END), 0) AS sales,
                COALESCE(SUM(CASE WHEN kind = 'purchase' THEN total END), 0) AS purchases,
                COALESCE(SUM(CASE WHEN kind = 'expense' THEN total END), 0) AS expenses
            FROM transactions
            WHERE day = ? AND status = 'finalized'
            """,
            (day_value,),
        ).fetchone()

        remaining = (start_cash + adjustments + float(sums["sales"])) - (
            float(sums["purchases"]) + float(sums["expenses"])
        )
        return round(remaining, 2)

    def import_price_list_csv(self, csv_path: str | Path) -> int:
        csv_path = Path(csv_path)
        imported = 0
        with csv_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            required = {"Item Name", "Regular Price", "Extra Price"}
            if not required.issubset(set(reader.fieldnames or [])):
                raise ValueError("CSV must contain Item Name, Regular Price, Extra Price")
            for row in reader:
                self._conn.execute(
                    """
                    INSERT INTO price_list (item_name, regular_price, extra_price)
                    VALUES (?, ?, ?)
                    ON CONFLICT(item_name) DO UPDATE SET
                        regular_price = excluded.regular_price,
                        extra_price = excluded.extra_price
                    """,
                    (
                        row["Item Name"].strip(),
                        float(row["Regular Price"]),
                        float(row["Extra Price"]),
                    ),
                )
                imported += 1
        self._conn.commit()
        return imported

    def export_receipts_by_date(self, day: str, output_dir: str | Path) -> list[Path]:
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        rows = self._conn.execute(
            "SELECT transaction_id, receipt_json FROM receipts r JOIN transactions t ON t.id = r.transaction_id WHERE t.day = ?",
            (day,),
        ).fetchall()
        files = []
        for row in rows:
            target = output_path / f"receipt-{row['transaction_id']}.json"
            target.write_text(row["receipt_json"], encoding="utf-8")
            files.append(target)
        return files
