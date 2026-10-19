import 'dart:typed_data';

import '../charger_models/charger_parameters.dart';
import '../charger_models/charger_status.dart';
import '../charger_models/lithium_parameter_target.dart';
import '../charger_models/lock_target.dart';
import '../validation/charger_parameter_validator.dart';
import 'charger_protocol_exception.dart';
import 'crc8.dart';

/// Result of decoding command `04`/`05`/`06`, the acknowledgements the mini
/// program treats as UI hints for force activation and lock adjustment.
///
/// These frames are not execution proof. Command `05` additionally carries the
/// timer value the mini program stores from offsets 17..18.
class ChargerControlAcknowledgement {
  const ChargerControlAcknowledgement({required this.command, this.timerRaw});

  /// The acknowledgement command byte: `04` activate, `05` lock, `06` unlock.
  final int command;

  /// Big-endian value at offsets 17..18 of a `05` reply, or `null` when the
  /// reply is too short or the command carries no timer field. The physical
  /// unit is unconfirmed, so this stays raw.
  final int? timerRaw;
}

class ChargerProtocol {
  const ChargerProtocol._();

  static const int frameLength = 13;
  static const int payloadLength = 9;
  static const int statusMinimumLength = 18;
  static const int parametersMinimumLength = 27;
  static const int activateAckCommand = 0x04;
  static const int lockAckCommand = 0x05;
  static const int unlockAckCommand = 0x06;

  /// Offsets 17..18 of a `05` reply; the mini program reads the timer here.
  static const int lockAckTimerOffset = 17;
  static const int lockAckTimerLength = 2;

  static Uint8List encodeStatusRequest() => _encodeFrame(0x01, const [0xAA]);

  static Uint8List encodeParametersRequest() =>
      _encodeFrame(0x02, const [0xAA]);

  static ChargerStatus parseStatusReply(List<int> frame) {
    _validateReply(frame, command: 0x01, minimumLength: statusMinimumLength);
    return ChargerStatus(
      voltageHundredths: _readBe16(frame, 3),
      currentTenths: _readBe16(frame, 5),
      percentRaw: frame[7],
      timeRaw: _readBe16(frame, 8),
      powerRaw: _readBe16(frame, 10),
      capacityRaw: _readBe16(frame, 12),
      temperatureRaw: frame[14],
      batteryStateRaw: frame[15],
      faultRaw: frame[16],
    );
  }

  static ChargerParameters parseParametersReply(List<int> frame) {
    _validateReply(
      frame,
      command: 0x02,
      minimumLength: parametersMinimumLength,
    );
    return ChargerParameters(
      voltageHundredths: _readBe16(frame, 3),
      currentTenths: _readBe16(frame, 5),
      modeRaw: frame[7],
      language: frame[8],
      maxCurrentRaw: frame[9],
      lockRaw: frame[12],
      versionRaw: _readBe16(frame, 24),
    );
  }

  /// Encodes command 03 for lithium mode only.
  ///
  /// The public API intentionally has no mode or language argument. Mode is
  /// fixed to 1 and language/max-current validation are taken from the latest
  /// valid 02 reply. The optional max-current byte is not written by this
  /// normal parameter update.
  static Uint8List encodeLithiumParameters({
    required int voltageHundredths,
    required int currentTenths,
    required ChargerParameters currentParameters,
  }) {
    ChargerParameterValidator.validateForCharger(
      voltageHundredths: voltageHundredths,
      currentTenths: currentTenths,
      maxCurrentRaw: currentParameters.maxCurrentRaw,
    );
    ChargerParameterValidator.validateLanguage(currentParameters.language);

    return _encodeFrame(0x03, [
      voltageHundredths >> 8,
      voltageHundredths & 0xFF,
      currentTenths >> 8,
      currentTenths & 0xFF,
      0x01,
      currentParameters.language,
    ]);
  }

  static LithiumParameterTarget lithiumTarget({
    required int voltageHundredths,
    required int currentTenths,
    required ChargerParameters currentParameters,
  }) {
    ChargerParameterValidator.validateForCharger(
      voltageHundredths: voltageHundredths,
      currentTenths: currentTenths,
      maxCurrentRaw: currentParameters.maxCurrentRaw,
    );
    ChargerParameterValidator.validateLanguage(currentParameters.language);
    return LithiumParameterTarget(
      voltageHundredths: voltageHundredths,
      currentTenths: currentTenths,
      language: currentParameters.language,
    );
  }

  static bool hasValidEnvelope(List<int> frame) {
    if (frame.length < 4 || frame[0] != 0xA5 || frame[1] != 0x5A) {
      return false;
    }
    for (final byte in frame) {
      if (byte < 0 || byte > 0xFF) return false;
    }
    return ChargerCrc8.compute(frame.take(frame.length - 1)) == frame.last;
  }

  /// Encodes command 04, the mini program's force-activation request.
  ///
  /// The mini program sends this only after a 3 second long press on the home
  /// page and uses the same `AA` padding as the 01/02 queries. There is no
  /// variant of this request and no payload parameter.
  static Uint8List encodeActivateRequest() => _encodeFrame(0x04, const [0xAA]);

  /// Encodes command 09, the mini program's manual button lock adjustment.
  ///
  /// The public API takes a closed [LockTarget] instead of a raw byte so the
  /// caller cannot send an arbitrary direction or a toggled guess.
  static Uint8List encodeLockRequest(LockTarget target) =>
      _encodeFrame(0x09, [target.wireByte]);

  /// Decodes a command [expectedCommand] acknowledgement frame.
  ///
  /// Only the envelope, CRC, length and command byte are checked; the mini
  /// program ignores all other fields. A mismatch throws, so a late reply for a
  /// different command can never be reported as this command's acknowledgement.
  ///
  /// The timer field is only read when the reply is long enough to contain it,
  /// because the mini program reads offsets 17..18 unconditionally while the
  /// request/ack frame length is not confirmed on real hardware.
  static ChargerControlAcknowledgement parseControlAcknowledgement(
    List<int> frame, {
    required int expectedCommand,
  }) {
    if (frame.length < frameLength) {
      throw ChargerProtocolException(
        'command ${_hex(expectedCommand)} acknowledgement is shorter than '
        '$frameLength bytes',
      );
    }
    if (!hasValidEnvelope(frame)) {
      throw const ChargerProtocolException('invalid frame header or CRC');
    }
    if (frame[2] != expectedCommand) {
      throw ChargerProtocolException('unexpected command ${_hex(frame[2])}');
    }
    final timerRaw =
        expectedCommand == lockAckCommand &&
            frame.length >= lockAckTimerOffset + lockAckTimerLength
        ? _readBe16(frame, lockAckTimerOffset)
        : null;
    return ChargerControlAcknowledgement(
      command: expectedCommand,
      timerRaw: timerRaw,
    );
  }

  static String _hex(int value) =>
      value.toRadixString(16).padLeft(2, '0').toUpperCase();

  static Uint8List _encodeFrame(int command, List<int> payload) {
    if (payload.length > payloadLength) {
      throw const ChargerProtocolException('payload exceeds 9 bytes');
    }
    final frame = Uint8List(frameLength);
    frame[0] = 0xA5;
    frame[1] = 0x5A;
    frame[2] = command;
    frame.setRange(3, 3 + payload.length, payload);
    frame[frameLength - 1] = ChargerCrc8.compute(frame.take(frameLength - 1));
    return frame;
  }

  static void _validateReply(
    List<int> frame, {
    required int command,
    required int minimumLength,
  }) {
    if (frame.length < minimumLength) {
      throw ChargerProtocolException(
        'command ${_hex(command)} reply is shorter '
        'than $minimumLength bytes',
      );
    }
    if (!hasValidEnvelope(frame)) {
      throw const ChargerProtocolException('invalid frame header or CRC');
    }
    if (frame[2] != command) {
      throw ChargerProtocolException('unexpected command ${_hex(frame[2])}');
    }
  }

  static int _readBe16(List<int> bytes, int offset) =>
      (bytes[offset] << 8) | bytes[offset + 1];
}
