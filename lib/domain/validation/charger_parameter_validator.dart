class ChargerValidationException implements Exception {
  const ChargerValidationException(this.field, this.message);

  final String field;
  final String message;

  @override
  String toString() => 'ChargerValidationException($field): $message';
}

class ChargerParameterValidator {
  const ChargerParameterValidator._();

  static const int minVoltageHundredths = 1000;
  static const int maxVoltageHundredths = 9300;
  static const int minCurrentTenths = 30;
  static const int maxCurrentTenths = 300;

  static int effectiveMaxCurrentTenths({
    required int voltageHundredths,
    required int maxCurrentRaw,
  }) {
    _validateVoltage(voltageHundredths);
    if (maxCurrentRaw < 0 || maxCurrentRaw > 30) {
      throw const ChargerValidationException(
        'maxCurrentRaw',
        'must be in the range 0..30',
      );
    }

    if (maxCurrentRaw == 25) {
      if (voltageHundredths <= 6599) return 250;
      if (voltageHundredths <= 7499) return 220;
      return 200;
    }
    return maxCurrentRaw == 0 ? maxCurrentTenths : maxCurrentRaw * 10;
  }

  static void validateStatic({
    required int voltageHundredths,
    required int currentTenths,
  }) {
    _validateVoltage(voltageHundredths);
    if (currentTenths < minCurrentTenths || currentTenths > maxCurrentTenths) {
      throw const ChargerValidationException(
        'currentTenths',
        'must be in the range 30..300',
      );
    }
  }

  static void validateForCharger({
    required int voltageHundredths,
    required int currentTenths,
    required int maxCurrentRaw,
  }) {
    validateStatic(
      voltageHundredths: voltageHundredths,
      currentTenths: currentTenths,
    );
    final effectiveMaximum = effectiveMaxCurrentTenths(
      voltageHundredths: voltageHundredths,
      maxCurrentRaw: maxCurrentRaw,
    );
    if (currentTenths > effectiveMaximum) {
      throw ChargerValidationException(
        'currentTenths',
        'exceeds the dynamic maximum $effectiveMaximum',
      );
    }
  }

  static void validateLanguage(int language) {
    if (language < 0 || language > 1) {
      throw const ChargerValidationException('language', 'must be 0 or 1');
    }
  }

  static void _validateVoltage(int voltageHundredths) {
    if (voltageHundredths < minVoltageHundredths ||
        voltageHundredths > maxVoltageHundredths) {
      throw const ChargerValidationException(
        'voltageHundredths',
        'must be in the range 1000..9300',
      );
    }
  }
}
