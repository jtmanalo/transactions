import csv
import tempfile
import unittest
from pathlib import Path

from transactions import ItemLine, TransactionManager


class TransactionManagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temp_dir.name) / "test.db"
        self.manager = TransactionManager(self.db_path)

    def tearDown(self) -> None:
        self.manager.close()
        self.temp_dir.cleanup()

    def test_remaining_cash_formula(self) -> None:
        day = "2026-05-22"
        self.manager.set_starting_cash(1000, day)
        self.manager.add_adjustment(200, day)

        purchase = self.manager.create_draft_transaction(
            kind="purchase",
            item_lines=[ItemLine("Rice", 10, 5)],
            party_type="Seller Type",
            party_name="Seller Name",
            day=day,
        )
        sale = self.manager.create_draft_transaction(
            kind="sale",
            item_lines=[ItemLine("Rice", 20, 3)],
            party_type="Buyer Type",
            party_name="Buyer Name",
            day=day,
        )
        expense = self.manager.create_expense_draft(100, "Transport", day=day)

        self.manager.finalize_transaction(purchase)
        self.manager.finalize_transaction(sale)
        self.manager.finalize_transaction(expense)

        self.assertEqual(self.manager.remaining_cash(day), 1110.0)

    def test_daily_reset_is_date_based(self) -> None:
        self.manager.set_starting_cash(500, "2026-05-21")
        self.manager.set_starting_cash(1000, "2026-05-22")
        self.assertEqual(self.manager.remaining_cash("2026-05-21"), 500.0)
        self.assertEqual(self.manager.remaining_cash("2026-05-22"), 1000.0)

    def test_draft_persistence_and_receipt_generation(self) -> None:
        day = "2026-05-22"
        tx_id = self.manager.create_draft_transaction(
            kind="sale",
            item_lines=[ItemLine("Water", 15.5, 2)],
            party_type="Buyer Type",
            party_name="Client",
            branch="Main",
            user_name="Alice",
            day=day,
        )

        manager2 = TransactionManager(self.db_path)
        drafts = manager2.list_drafts()
        self.assertEqual(len(drafts), 1)
        self.assertEqual(drafts[0]["id"], tx_id)

        receipt = manager2.finalize_transaction(tx_id)
        self.assertEqual(receipt["branch"], "Main")
        self.assertEqual(receipt["user"], "Alice")
        self.assertEqual(receipt["total"], 31.0)
        manager2.close()

    def test_csv_import_and_bulk_export(self) -> None:
        csv_path = Path(self.temp_dir.name) / "prices.csv"
        with csv_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=["Item Name", "Regular Price", "Extra Price"])
            writer.writeheader()
            writer.writerow({"Item Name": "Apple", "Regular Price": "12", "Extra Price": "15"})

        imported = self.manager.import_price_list_csv(csv_path)
        self.assertEqual(imported, 1)

        day = "2026-05-22"
        tx_id = self.manager.create_draft_transaction(
            kind="sale",
            item_lines=[ItemLine("Apple", 12, 2)],
            day=day,
        )
        self.manager.finalize_transaction(tx_id)

        files = self.manager.export_receipts_by_date(day, Path(self.temp_dir.name) / "exports")
        self.assertEqual(len(files), 1)
        self.assertTrue(files[0].exists())


if __name__ == "__main__":
    unittest.main()
