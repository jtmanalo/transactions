import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/item_line.dart';

enum TransactionKind { purchase, sale, expense }

class TransactionManager {
  TransactionManager({Database? database}) : _dbOverride = database;

  Database? _dbOverride;
  Database? _db;
  bool _isInitialized = false;

  Future<Database> _database() async {
    final existing = _dbOverride ?? _db;
    if (existing != null) {
      if (!_isInitialized) {
        await _createTables(existing);
        _isInitialized = true;
      }
      return existing;
    }

    final dbPath = await getDatabasesPath();
    final opened = await openDatabase(
      p.join(dbPath, 'transactions.db'),
      version: 1,
      onCreate: (db, _) async => _createTables(db),
    );
    _db = opened;
    if (!_isInitialized) {
      await _createTables(opened);
      _isInitialized = true;
    }
    return opened;
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS daily_cash (
        day TEXT PRIMARY KEY,
        starting_cash REAL NOT NULL DEFAULT 0,
        adjustments REAL NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
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
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS transaction_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id INTEGER NOT NULL,
        item_name TEXT NOT NULL,
        price REAL NOT NULL,
        quantity REAL NOT NULL,
        line_total REAL NOT NULL,
        FOREIGN KEY(transaction_id) REFERENCES transactions(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS receipts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id INTEGER NOT NULL UNIQUE,
        receipt_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(transaction_id) REFERENCES transactions(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS price_list (
        item_name TEXT PRIMARY KEY,
        regular_price REAL NOT NULL,
        extra_price REAL NOT NULL
      )
    ''');
  }

  String _day([String? day]) {
    if (day != null && day.isNotEmpty) {
      return day;
    }
    return DateTime.now().toUtc().toIso8601String().split('T').first;
  }

  Future<void> close() async {
    if (_dbOverride != null) {
      await _dbOverride!.close();
      _dbOverride = null;
      _isInitialized = false;
      return;
    }
    if (_db != null) {
      await _db!.close();
      _db = null;
      _isInitialized = false;
    }
  }

  Future<void> setStartingCash(double amount, {String? day}) async {
    final db = await _database();
    final dayValue = _day(day);
    await db.rawInsert(
      '''
      INSERT INTO daily_cash (day, starting_cash, adjustments)
      VALUES (?, ?, COALESCE((SELECT adjustments FROM daily_cash WHERE day = ?), 0))
      ON CONFLICT(day) DO UPDATE SET starting_cash = excluded.starting_cash
      ''',
      <Object?>[dayValue, amount, dayValue],
    );
  }

  Future<void> addAdjustment(double amount, {String? day}) async {
    final db = await _database();
    final dayValue = _day(day);
    await db.rawInsert(
      '''
      INSERT INTO daily_cash (day, starting_cash, adjustments)
      VALUES (?, 0, ?)
      ON CONFLICT(day) DO UPDATE SET adjustments = daily_cash.adjustments + excluded.adjustments
      ''',
      <Object?>[dayValue, amount],
    );
  }

  Future<int> createDraftTransaction({
    required TransactionKind kind,
    required List<ItemLine> itemLines,
    String? partyType,
    String? partyName,
    String notes = '',
    String branch = 'Default Branch',
    String userName = 'Default User',
    String? day,
  }) async {
    final db = await _database();
    final dayValue = _day(day);
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final total =
        itemLines.fold<double>(0, (sum, item) => sum + item.total).toPrecision2();

    return db.transaction((txn) async {
      final transactionId = await txn.insert('transactions', <String, Object?>{
        'kind': kind.name,
        'party_type': partyType,
        'party_name': partyName,
        'notes': notes,
        'branch': branch,
        'user_name': userName,
        'status': 'draft',
        'total': total,
        'created_at': createdAt,
        'day': dayValue,
      });
      for (final item in itemLines) {
        await txn.insert('transaction_items', <String, Object?>{
          'transaction_id': transactionId,
          'item_name': item.itemName,
          'price': item.price,
          'quantity': item.quantity,
          'line_total': item.total,
        });
      }
      return transactionId;
    });
  }

  Future<int> createExpenseDraft({
    required double amount,
    required String notes,
    String? day,
  }) {
    return createDraftTransaction(
      kind: TransactionKind.expense,
      itemLines: <ItemLine>[
        ItemLine(itemName: 'Expense', price: amount, quantity: 1),
      ],
      notes: notes,
      day: day,
    );
  }

  Future<Map<String, Object?>> finalizeTransaction(int transactionId) async {
    final db = await _database();
    final txRows = await db.query(
      'transactions',
      where: 'id = ?',
      whereArgs: <Object?>[transactionId],
      limit: 1,
    );
    if (txRows.isEmpty) {
      throw ArgumentError('Transaction $transactionId does not exist');
    }
    final tx = txRows.first;
    if (tx['status'] == 'finalized') {
      return getReceipt(transactionId);
    }

    final finalizedAt = DateTime.now().toUtc().toIso8601String();
    await db.update(
      'transactions',
      <String, Object?>{
        'status': 'finalized',
        'finalized_at': finalizedAt,
      },
      where: 'id = ?',
      whereArgs: <Object?>[transactionId],
    );

    final receipt = await _buildReceipt(transactionId);
    await db.insert(
      'receipts',
      <String, Object?>{
        'transaction_id': transactionId,
        'receipt_json': jsonEncode(receipt),
        'created_at': finalizedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return receipt;
  }

  Future<Map<String, Object?>> _buildReceipt(int transactionId) async {
    final db = await _database();
    final tx = (await db.query(
      'transactions',
      where: 'id = ?',
      whereArgs: <Object?>[transactionId],
      limit: 1,
    ))
        .first;

    final items = await db.query(
      'transaction_items',
      columns: <String>['item_name', 'price', 'quantity', 'line_total'],
      where: 'transaction_id = ?',
      whereArgs: <Object?>[transactionId],
      orderBy: 'id ASC',
    );

    return <String, Object?>{
      'date': tx['day'],
      'branch': tx['branch'],
      'user': tx['user_name'],
      'kind': tx['kind'],
      'party_type': tx['party_type'],
      'party_name': tx['party_name'],
      'notes': tx['notes'],
      'items': items,
      'subtotal': tx['total'],
      'total': tx['total'],
    };
  }

  Future<Map<String, Object?>> getReceipt(int transactionId) async {
    final db = await _database();
    final rows = await db.query(
      'receipts',
      columns: <String>['receipt_json'],
      where: 'transaction_id = ?',
      whereArgs: <Object?>[transactionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError('Receipt for transaction $transactionId does not exist');
    }
    return (jsonDecode(rows.first['receipt_json']! as String) as Map)
        .cast<String, Object?>();
  }

  Future<List<Map<String, Object?>>> listDrafts() async {
    final db = await _database();
    final rows = await db.query(
      'transactions',
      where: "status = 'draft'",
      orderBy: 'created_at DESC',
    );
    return rows;
  }

  Future<double> remainingCash({String? day}) async {
    final db = await _database();
    final dayValue = _day(day);
    final daily = await db.query(
      'daily_cash',
      columns: <String>['starting_cash', 'adjustments'],
      where: 'day = ?',
      whereArgs: <Object?>[dayValue],
      limit: 1,
    );

    final startCash = daily.isEmpty
        ? 0
        : (daily.first['starting_cash'] as num).toDouble();
    final adjustments = daily.isEmpty
        ? 0
        : (daily.first['adjustments'] as num).toDouble();

    final sums = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN kind = 'sale' THEN total END), 0) AS sales,
        COALESCE(SUM(CASE WHEN kind = 'purchase' THEN total END), 0) AS purchases,
        COALESCE(SUM(CASE WHEN kind = 'expense' THEN total END), 0) AS expenses
      FROM transactions
      WHERE day = ? AND status = 'finalized'
      ''',
      <Object?>[dayValue],
    );
    final row = sums.first;
    final sales = (row['sales'] as num).toDouble();
    final purchases = (row['purchases'] as num).toDouble();
    final expenses = (row['expenses'] as num).toDouble();

    return ((startCash + adjustments + sales) - (purchases + expenses))
        .toPrecision2();
  }

  Future<int> importPriceListCsv(String csvContent) async {
    final db = await _database();
    final lines = const LineSplitter().convert(csvContent);
    if (lines.isEmpty) {
      throw ArgumentError('CSV must contain Item Name, Regular Price, Extra Price');
    }

    final headers = lines.first.split(',').map((v) => v.trim()).toList();
    final itemNameIndex = headers.indexOf('Item Name');
    final regularPriceIndex = headers.indexOf('Regular Price');
    final extraPriceIndex = headers.indexOf('Extra Price');
    if (itemNameIndex < 0 || regularPriceIndex < 0 || extraPriceIndex < 0) {
      throw ArgumentError('CSV must contain Item Name, Regular Price, Extra Price');
    }

    var imported = 0;
    await db.transaction((txn) async {
      for (final rowLine in lines.skip(1)) {
        if (rowLine.trim().isEmpty) {
          continue;
        }
        final columns = rowLine.split(',');
        if (columns.length < headers.length) {
          continue;
        }
        await txn.rawInsert(
          '''
          INSERT INTO price_list (item_name, regular_price, extra_price)
          VALUES (?, ?, ?)
          ON CONFLICT(item_name) DO UPDATE SET
            regular_price = excluded.regular_price,
            extra_price = excluded.extra_price
          ''',
          <Object?>[
            columns[itemNameIndex].trim(),
            double.parse(columns[regularPriceIndex].trim()),
            double.parse(columns[extraPriceIndex].trim()),
          ],
        );
        imported += 1;
      }
    });
    return imported;
  }

  Future<List<Map<String, Object?>>> receiptsByDate(String day) async {
    final db = await _database();
    final rows = await db.rawQuery(
      '''
      SELECT r.transaction_id, r.receipt_json
      FROM receipts r
      JOIN transactions t ON t.id = r.transaction_id
      WHERE t.day = ?
      ORDER BY r.transaction_id ASC
      ''',
      <Object?>[day],
    );
    return rows
        .map((row) => <String, Object?>{
              'transaction_id': row['transaction_id'] as int,
              'receipt': (jsonDecode(row['receipt_json']! as String) as Map)
                  .cast<String, Object?>(),
            })
        .toList();
  }
}

extension _MoneyRound on num {
  double toPrecision2() => (this * 100).roundToDouble() / 100;
}
