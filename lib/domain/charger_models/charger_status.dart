class ChargerStatus {
  const ChargerStatus({
    required this.voltageHundredths,
    required this.currentTenths,
    required this.percentRaw,
    required this.timeRaw,
    required this.powerRaw,
    required this.capacityRaw,
    required this.temperatureRaw,
    required this.batteryStateRaw,
    required this.faultRaw,
  });

  final int voltageHundredths;
  final int currentTenths;

  // These fields retain their protocol values because their physical units
  // have not been confirmed on a real charger.
  final int percentRaw;
  final int timeRaw;
  final int powerRaw;
  final int capacityRaw;
  final int temperatureRaw;
  final int batteryStateRaw;
  final int faultRaw;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChargerStatus &&
          voltageHundredths == other.voltageHundredths &&
          currentTenths == other.currentTenths &&
          percentRaw == other.percentRaw &&
          timeRaw == other.timeRaw &&
          powerRaw == other.powerRaw &&
          capacityRaw == other.capacityRaw &&
          temperatureRaw == other.temperatureRaw &&
          batteryStateRaw == other.batteryStateRaw &&
          faultRaw == other.faultRaw;

  @override
  int get hashCode => Object.hash(
    voltageHundredths,
    currentTenths,
    percentRaw,
    timeRaw,
    powerRaw,
    capacityRaw,
    temperatureRaw,
    batteryStateRaw,
    faultRaw,
  );
}
