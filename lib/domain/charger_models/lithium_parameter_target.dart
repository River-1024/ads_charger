class LithiumParameterTarget {
  const LithiumParameterTarget({
    required this.voltageHundredths,
    required this.currentTenths,
    required this.language,
  });

  final int voltageHundredths;
  final int currentTenths;
  final int language;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LithiumParameterTarget &&
          voltageHundredths == other.voltageHundredths &&
          currentTenths == other.currentTenths &&
          language == other.language;

  @override
  int get hashCode => Object.hash(voltageHundredths, currentTenths, language);
}
