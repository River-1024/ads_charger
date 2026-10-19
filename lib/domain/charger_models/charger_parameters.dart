import 'lithium_parameter_target.dart';

class ChargerParameters {
  const ChargerParameters({
    required this.voltageHundredths,
    required this.currentTenths,
    required this.modeRaw,
    required this.language,
    required this.maxCurrentRaw,
    required this.lockRaw,
    required this.versionRaw,
  });

  final int voltageHundredths;
  final int currentTenths;
  final int modeRaw;
  final int language;
  final int maxCurrentRaw;
  final int lockRaw;
  final int versionRaw;

  bool get isLocked => lockRaw == 0xA0;
  bool get isLithiumMode => modeRaw == 1;

  /// A write is verified only when the readback protocol integers match
  /// exactly. No floating-point or formatted-string comparison is involved.
  bool matchesLithiumTarget(LithiumParameterTarget target) =>
      modeRaw == 1 &&
      voltageHundredths == target.voltageHundredths &&
      currentTenths == target.currentTenths &&
      language == target.language;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChargerParameters &&
          voltageHundredths == other.voltageHundredths &&
          currentTenths == other.currentTenths &&
          modeRaw == other.modeRaw &&
          language == other.language &&
          maxCurrentRaw == other.maxCurrentRaw &&
          lockRaw == other.lockRaw &&
          versionRaw == other.versionRaw;

  @override
  int get hashCode => Object.hash(
    voltageHundredths,
    currentTenths,
    modeRaw,
    language,
    maxCurrentRaw,
    lockRaw,
    versionRaw,
  );
}
