import 'package:ads_charger/domain/charger_models/charger_models.dart';
import 'package:ads_charger/domain/charger_protocol/protocol.dart';
import 'package:ads_charger/domain/validation/validation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds an acknowledgement frame long enough to carry the `05` timer field so
/// the parser's offset handling is exercised, not just the trailer CRC.
List<int> _controlAckFrame(int command) {
  final frame = List<int>.filled(20, 0);
  frame[0] = 0xA5;
  frame[1] = 0x5A;
  frame[2] = command;
  frame[19] = ChargerCrc8.compute(frame.take(19));
  return frame;
}

void main() {
  const query01 = <int>[0xA5, 0x5A, 0x01, 0xAA, 0, 0, 0, 0, 0, 0, 0, 0, 0x97];
  const query02 = <int>[0xA5, 0x5A, 0x02, 0xAA, 0, 0, 0, 0, 0, 0, 0, 0, 0xDC];
  const statusReply = <int>[
    0xA5,
    0x5A,
    0x01,
    0x14,
    0xC8,
    0x00,
    0x15,
    0x44,
    0x00,
    0x0A,
    0x00,
    0x70,
    0x00,
    0x0F,
    0x1B,
    0x01,
    0x00,
    0x58,
  ];
  const parametersReply = <int>[
    0xA5,
    0x5A,
    0x02,
    0x15,
    0x54,
    0x00,
    0x1E,
    0x01,
    0x00,
    0x1E,
    0x00,
    0x00,
    0xA0,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x3C,
    0xAF,
  ];

  group('golden vectors', () {
    test('CRC8 and 01/02 requests match C++ and Python baselines', () {
      expect(ChargerCrc8.compute(const []), 0);
      expect(ChargerCrc8.compute(query01.take(12)), 0x97);
      expect(ChargerProtocol.encodeStatusRequest(), query01);
      expect(ChargerProtocol.encodeParametersRequest(), query02);
    });

    test('parses the golden 01 reply using integer/raw fields', () {
      final status = ChargerProtocol.parseStatusReply(statusReply);
      expect(status.voltageHundredths, 5320);
      expect(status.currentTenths, 21);
      expect(status.percentRaw, 68);
      expect(status.timeRaw, 10);
      expect(status.powerRaw, 112);
      expect(status.capacityRaw, 15);
      expect(status.temperatureRaw, 27);
      expect(status.batteryStateRaw, 1);
      expect(status.faultRaw, 0);
    });

    test('parses the golden 02 reply using protocol integers', () {
      final parameters = ChargerProtocol.parseParametersReply(parametersReply);
      expect(parameters.voltageHundredths, 5460);
      expect(parameters.currentTenths, 30);
      expect(parameters.modeRaw, 1);
      expect(parameters.language, 0);
      expect(parameters.maxCurrentRaw, 30);
      expect(parameters.lockRaw, 0xA0);
      expect(parameters.isLocked, isTrue);
      expect(parameters.versionRaw, 60);
    });

    test('encodes 03 with internal mode=1 and no max-current byte', () {
      final current = ChargerProtocol.parseParametersReply(parametersReply);
      expect(
        ChargerProtocol.encodeLithiumParameters(
          voltageHundredths: 5460,
          currentTenths: 30,
          currentParameters: current,
        ),
        const <int>[
          0xA5,
          0x5A,
          0x03,
          0x15,
          0x54,
          0x00,
          0x1E,
          0x01,
          0x00,
          0x00,
          0x00,
          0x00,
          0xEF,
        ],
      );
    });

    test('encodes 04 and 09 exactly like the mini program home page', () {
      expect(
        ChargerProtocol.encodeActivateRequest(),
        const <int>[
          0xA5,
          0x5A,
          0x04,
          0xAA,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x4A,
        ],
      );
      expect(
        ChargerProtocol.encodeLockRequest(LockTarget.lock),
        const <int>[
          0xA5,
          0x5A,
          0x09,
          0xA0,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0xBD,
        ],
      );
      expect(
        ChargerProtocol.encodeLockRequest(LockTarget.unlock),
        const <int>[
          0xA5,
          0x5A,
          0x09,
          0x0A,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x71,
        ],
      );
    });

    test('resolves the 09 direction from the 02 lock flag', () {
      expect(LockTarget.fromLockRaw(0xA0), LockTarget.lock);
      expect(LockTarget.fromLockRaw(0x0A), LockTarget.unlock);
      expect(LockTarget.lock.wireByte, 0xA0);
      expect(LockTarget.unlock.wireByte, 0x0A);
      expect(LockTarget.fromWireByte(0xA0), LockTarget.lock);
      expect(LockTarget.fromWireByte(0x0A), LockTarget.unlock);
      expect(LockTarget.fromWireByte(0x00), isNull);
    });

    test('parses 04/05/06 acknowledgements and the 05 timer field', () {
      final activate = ChargerProtocol.parseControlAcknowledgement(
        _controlAckFrame(0x04),
        expectedCommand: ChargerProtocol.activateAckCommand,
      );
      expect(activate.command, 0x04);
      expect(activate.timerRaw, isNull);

      final unlock = ChargerProtocol.parseControlAcknowledgement(
        _controlAckFrame(0x06),
        expectedCommand: ChargerProtocol.unlockAckCommand,
      );
      expect(unlock.command, 0x06);
      expect(unlock.timerRaw, isNull);

      final lockReply = _controlAckFrame(0x05);
      lockReply[17] = 0x00;
      lockReply[18] = 0x78;
      lockReply[19] = ChargerCrc8.compute(lockReply.take(19));
      final lock = ChargerProtocol.parseControlAcknowledgement(
        lockReply,
        expectedCommand: ChargerProtocol.lockAckCommand,
      );
      expect(lock.command, 0x05);
      expect(lock.timerRaw, 120);
    });
  });

  group('control acknowledgement rejection', () {
    test('rejects a short, bad-CRC or wrong-command acknowledgement', () {
      expect(
        () => ChargerProtocol.parseControlAcknowledgement(
          const <int>[0xA5, 0x5A, 0x04],
          expectedCommand: 0x04,
        ),
        throwsA(isA<ChargerProtocolException>()),
      );
      final broken = _controlAckFrame(0x04)..[12] ^= 1;
      expect(
        () => ChargerProtocol.parseControlAcknowledgement(
          broken,
          expectedCommand: 0x04,
        ),
        throwsA(isA<ChargerProtocolException>()),
      );
      expect(
        () => ChargerProtocol.parseControlAcknowledgement(
          _controlAckFrame(0x05),
          expectedCommand: ChargerProtocol.activateAckCommand,
        ),
        throwsA(isA<ChargerProtocolException>()),
      );
    });
  });

  group('reply rejection', () {
    test('rejects bad CRC', () {
      final broken = [...statusReply]..[17] ^= 1;
      expect(
        () => ChargerProtocol.parseStatusReply(broken),
        throwsA(isA<ChargerProtocolException>()),
      );
    });

    test('rejects short frames before reading fields', () {
      expect(
        () => ChargerProtocol.parseStatusReply(query01),
        throwsA(isA<ChargerProtocolException>()),
      );
      expect(
        () => ChargerProtocol.parseParametersReply(statusReply),
        throwsA(isA<ChargerProtocolException>()),
      );
    });

    test('rejects a valid frame carrying the wrong command', () {
      expect(
        () => ChargerProtocol.parseStatusReply(parametersReply),
        throwsA(isA<ChargerProtocolException>()),
      );
    });
  });

  group('validation boundaries', () {
    const unrestricted = ChargerParameters(
      voltageHundredths: 5460,
      currentTenths: 30,
      modeRaw: 1,
      language: 0,
      maxCurrentRaw: 0,
      lockRaw: 0,
      versionRaw: 60,
    );

    test('accepts inclusive 10/93 V and 3/30 A static boundaries', () {
      expect(
        ChargerProtocol.encodeLithiumParameters(
          voltageHundredths: 1000,
          currentTenths: 30,
          currentParameters: unrestricted,
        ),
        const <int>[
          0xA5,
          0x5A,
          0x03,
          0x03,
          0xE8,
          0x00,
          0x1E,
          0x01,
          0x00,
          0x00,
          0x00,
          0x00,
          0xF7,
        ],
      );
      expect(
        () => ChargerProtocol.encodeLithiumParameters(
          voltageHundredths: 9300,
          currentTenths: 300,
          currentParameters: unrestricted,
        ),
        returnsNormally,
      );
    });

    test('rejects values immediately outside static boundaries', () {
      for (final voltage in const [999, 9301]) {
        expect(
          () => ChargerProtocol.encodeLithiumParameters(
            voltageHundredths: voltage,
            currentTenths: 30,
            currentParameters: unrestricted,
          ),
          throwsA(isA<ChargerValidationException>()),
        );
      }
      for (final current in const [29, 301]) {
        expect(
          () => ChargerProtocol.encodeLithiumParameters(
            voltageHundredths: 5460,
            currentTenths: current,
            currentParameters: unrestricted,
          ),
          throwsA(isA<ChargerValidationException>()),
        );
      }
    });

    test('maxCurrentRaw=25 applies the 25/22/20 A voltage segments', () {
      expect(
        ChargerParameterValidator.effectiveMaxCurrentTenths(
          voltageHundredths: 6599,
          maxCurrentRaw: 25,
        ),
        250,
      );
      expect(
        ChargerParameterValidator.effectiveMaxCurrentTenths(
          voltageHundredths: 6600,
          maxCurrentRaw: 25,
        ),
        220,
      );
      expect(
        ChargerParameterValidator.effectiveMaxCurrentTenths(
          voltageHundredths: 7499,
          maxCurrentRaw: 25,
        ),
        220,
      );
      expect(
        ChargerParameterValidator.effectiveMaxCurrentTenths(
          voltageHundredths: 7500,
          maxCurrentRaw: 25,
        ),
        200,
      );
    });

    test('dynamic maximum is enforced inclusively', () {
      const limited = ChargerParameters(
        voltageHundredths: 7500,
        currentTenths: 200,
        modeRaw: 1,
        language: 1,
        maxCurrentRaw: 25,
        lockRaw: 0,
        versionRaw: 60,
      );
      expect(
        () => ChargerProtocol.encodeLithiumParameters(
          voltageHundredths: 7500,
          currentTenths: 200,
          currentParameters: limited,
        ),
        returnsNormally,
      );
      expect(
        () => ChargerProtocol.encodeLithiumParameters(
          voltageHundredths: 7500,
          currentTenths: 201,
          currentParameters: limited,
        ),
        throwsA(isA<ChargerValidationException>()),
      );
    });
  });

  test('write readback comparison uses exact integers and requires mode=1', () {
    const target = LithiumParameterTarget(
      voltageHundredths: 5460,
      currentTenths: 30,
      language: 0,
    );
    final exact = ChargerProtocol.parseParametersReply(parametersReply);
    expect(exact.matchesLithiumTarget(target), isTrue);
    expect(
      ChargerParameters(
        voltageHundredths: 5459,
        currentTenths: exact.currentTenths,
        modeRaw: exact.modeRaw,
        language: exact.language,
        maxCurrentRaw: exact.maxCurrentRaw,
        lockRaw: exact.lockRaw,
        versionRaw: exact.versionRaw,
      ).matchesLithiumTarget(target),
      isFalse,
    );
    expect(
      ChargerParameters(
        voltageHundredths: exact.voltageHundredths,
        currentTenths: exact.currentTenths,
        modeRaw: 2,
        language: exact.language,
        maxCurrentRaw: exact.maxCurrentRaw,
        lockRaw: exact.lockRaw,
        versionRaw: exact.versionRaw,
      ).matchesLithiumTarget(target),
      isFalse,
    );
  });
}
