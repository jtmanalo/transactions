# transactions

Offline-first Flutter financial and transaction manager with local SQLite persistence.

## What is implemented

- Flutter app entrypoint at `lib/main.dart`
- SQLite-backed Dart `TransactionManager` at `lib/services/transaction_manager.dart` for:
  - Daily starting cash and same-day adjustments
  - Purchase, sale, and expense draft/finalized transactions
  - Real-time remaining cash formula:
    - `Remaining Cash = (Starting Cash + Sales + Adjustments) - (Purchases + Expenses)`
  - Receipt generation and date-based receipt lookup
  - CSV price-list import with columns: `Item Name`, `Regular Price`, `Extra Price`
- Flutter widget test coverage for domain manager behavior at `test/transaction_manager_test.dart`

## Run

```bash
flutter pub get
flutter run
```

## Run tests

```bash
flutter test
```
