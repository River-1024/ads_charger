class ChargerProtocolException implements Exception {
  const ChargerProtocolException(this.message);

  final String message;

  @override
  String toString() => 'ChargerProtocolException: $message';
}
