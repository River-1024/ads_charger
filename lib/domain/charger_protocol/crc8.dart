class ChargerCrc8 {
  const ChargerCrc8._();

  static int compute(Iterable<int> bytes) {
    var crc = 0;
    for (final byte in bytes) {
      if (byte < 0 || byte > 0xFF) {
        throw RangeError.range(byte, 0, 0xFF, 'byte');
      }
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1;
      }
    }
    return crc & 0xFF;
  }
}
