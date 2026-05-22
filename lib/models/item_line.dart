class ItemLine {
  const ItemLine({
    required this.itemName,
    required this.price,
    required this.quantity,
  });

  final String itemName;
  final double price;
  final double quantity;

  double get total => (price * quantity).toPrecision2();
}

extension _MoneyRound on num {
  double toPrecision2() => (this * 100).roundToDouble() / 100;
}
