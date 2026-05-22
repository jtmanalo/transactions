import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:transactions/models/item_line.dart';
import 'package:transactions/services/transaction_manager.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late TransactionManager manager;

  setUp(() async {
    final db = await openDatabase(inMemoryDatabasePath);
    manager = TransactionManager(database: db);
  });

  tearDown(() async {
    await manager.close();
  });

  test('remaining cash formula', () async {
    const day = '2026-05-22';
    await manager.setStartingCash(1000, day: day);
    await manager.addAdjustment(200, day: day);

    final purchase = await manager.createDraftTransaction(
      kind: TransactionKind.purchase,
      itemLines: const <ItemLine>[ItemLine(itemName: 'Rice', price: 10, quantity: 5)],
      partyType: 'Seller Type',
      partyName: 'Seller Name',
      day: day,
    );
    final sale = await manager.createDraftTransaction(
      kind: TransactionKind.sale,
      itemLines: const <ItemLine>[ItemLine(itemName: 'Rice', price: 20, quantity: 3)],
      partyType: 'Buyer Type',
      partyName: 'Buyer Name',
      day: day,
    );
    final expense = await manager.createExpenseDraft(
      amount: 100,
      notes: 'Transport',
      day: day,
    );

    await manager.finalizeTransaction(purchase);
    await manager.finalizeTransaction(sale);
    await manager.finalizeTransaction(expense);

    expect(await manager.remainingCash(day: day), 1110);
  });

  test('daily reset is date based', () async {
    await manager.setStartingCash(500, day: '2026-05-21');
    await manager.setStartingCash(1000, day: '2026-05-22');
    expect(await manager.remainingCash(day: '2026-05-21'), 500);
    expect(await manager.remainingCash(day: '2026-05-22'), 1000);
  });
}
