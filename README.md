# transactions

Offline-first financial and transaction manager with local persistence.

## What is implemented

- Local SQLite-backed `TransactionManager` for:
  - Daily starting cash and same-day adjustments
  - Purchase, sale, and expense draft/finalized transactions
  - Real-time remaining cash formula:
    - `Remaining Cash = (Starting Cash + Sales) - (Purchases + Expenses)`
  - Receipt generation and date-based bulk receipt export
  - CSV price-list import with columns: `Item Name`, `Regular Price`, `Extra Price`
- Date-based daily cash separation (supports daily reset behavior by day key)
- Draft persistence across restarts (stored in SQLite)
- Minimal iOS-style offline UI mock at `ui/index.html` with live balance updates

## Run tests

```bash
python -m unittest discover -v
```

## Notes

This repository currently contains a lightweight Python implementation of the required offline domain behavior and a static UI mock.
