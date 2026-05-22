import 'package:flutter/material.dart';

import 'models/item_line.dart';
import 'services/transaction_manager.dart';

void main() {
  runApp(const TransactionsApp());
}

class TransactionsApp extends StatelessWidget {
  const TransactionsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Transactions',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.orange,
        useMaterial3: true,
      ),
      home: const TransactionsHomePage(),
    );
  }
}

class TransactionsHomePage extends StatefulWidget {
  const TransactionsHomePage({super.key});

  @override
  State<TransactionsHomePage> createState() => _TransactionsHomePageState();
}

class _TransactionsHomePageState extends State<TransactionsHomePage> {
  final TransactionManager _manager = TransactionManager();
  final TextEditingController _dayController = TextEditingController(
    text: DateTime.now().toIso8601String().split('T').first,
  );
  final TextEditingController _startingCashController = TextEditingController();
  final TextEditingController _adjustmentController = TextEditingController();
  final TextEditingController _itemController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _partyController = TextEditingController();

  TransactionKind _kind = TransactionKind.sale;
  double _remainingCash = 0;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _refreshCash();
  }

  @override
  void dispose() {
    _manager.close();
    _dayController.dispose();
    _startingCashController.dispose();
    _adjustmentController.dispose();
    _itemController.dispose();
    _priceController.dispose();
    _quantityController.dispose();
    _partyController.dispose();
    super.dispose();
  }

  Future<void> _refreshCash() async {
    final day = _dayController.text.trim();
    final value = await _manager.remainingCash(day: day);
    if (!mounted) {
      return;
    }
    setState(() {
      _remainingCash = value;
    });
  }

  Future<void> _setStartingCash() async {
    final amount = double.tryParse(_startingCashController.text.trim());
    if (amount == null) {
      return;
    }
    await _manager.setStartingCash(amount, day: _dayController.text.trim());
    await _refreshCash();
  }

  Future<void> _addAdjustment() async {
    final amount = double.tryParse(_adjustmentController.text.trim());
    if (amount == null) {
      return;
    }
    await _manager.addAdjustment(amount, day: _dayController.text.trim());
    await _refreshCash();
  }

  Future<void> _createAndFinalizeTransaction() async {
    final price = double.tryParse(_priceController.text.trim());
    final qty = double.tryParse(_quantityController.text.trim());
    final item = _itemController.text.trim();
    if (price == null || qty == null || item.isEmpty) {
      return;
    }

    setState(() {
      _isBusy = true;
    });
    try {
      final id = await _manager.createDraftTransaction(
        kind: _kind,
        itemLines: <ItemLine>[
          ItemLine(itemName: item, price: price, quantity: qty),
        ],
        partyName: _partyController.text.trim().isEmpty
            ? null
            : _partyController.text.trim(),
        day: _dayController.text.trim(),
      );
      await _manager.finalizeTransaction(id);
      await _refreshCash();
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Transactions')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('Remaining Cash', style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 8),
                Text(
                  '₱${_remainingCash.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
              ],
            ),
          ),
          _Card(
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _dayController,
                  decoration: const InputDecoration(labelText: 'Day (YYYY-MM-DD)'),
                  onChanged: (_) => _refreshCash(),
                ),
                TextField(
                  controller: _startingCashController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Starting Cash'),
                ),
                FilledButton(
                  onPressed: _setStartingCash,
                  child: const Text('Set Starting Cash'),
                ),
                TextField(
                  controller: _adjustmentController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Adjustment'),
                ),
                FilledButton(
                  onPressed: _addAdjustment,
                  child: const Text('Add Adjustment'),
                ),
              ],
            ),
          ),
          _Card(
            child: Column(
              children: <Widget>[
                DropdownButtonFormField<TransactionKind>(
                  value: _kind,
                  items: TransactionKind.values
                      .map(
                        (kind) => DropdownMenuItem<TransactionKind>(
                          value: kind,
                          child: Text(kind.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _kind = value;
                    });
                  },
                  decoration: const InputDecoration(labelText: 'Type'),
                ),
                TextField(
                  controller: _partyController,
                  decoration: const InputDecoration(labelText: 'Party Name'),
                ),
                TextField(
                  controller: _itemController,
                  decoration: const InputDecoration(labelText: 'Item'),
                ),
                TextField(
                  controller: _priceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Price'),
                ),
                TextField(
                  controller: _quantityController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
                FilledButton(
                  onPressed: _isBusy ? null : _createAndFinalizeTransaction,
                  child: Text(_isBusy ? 'Saving...' : 'Create & Finalize'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}
