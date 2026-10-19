import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'application/presets/preset_service.dart';
import 'application/session/charger_session_actor.dart';
import 'features/app_shell.dart';
import 'infrastructure/ble/flutter_reactive_ble_driver.dart';
import 'infrastructure/storage/parameter_write_journal.dart';
import 'infrastructure/storage/shared_preferences_key_value_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferencesKeyValueStore.create();
  final presets = PresetService(preferences);
  final journal = await ParameterWriteJournal.create();
  final session = ChargerSessionActor(
    driver: FlutterReactiveBleDriver(ble: FlutterReactiveBle()),
    journal: journal,
  );
  await session.initialize();
  runApp(AdsChargerApp(session: session, presets: presets));
}

class AdsChargerApp extends StatelessWidget {
  const AdsChargerApp({
    super.key,
    required this.session,
    required this.presets,
  });

  final ChargerSessionActor session;
  final PresetService presets;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ADS 充电器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff006b5f),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          margin: EdgeInsets.symmetric(vertical: 6),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: AppShell(session: session, presets: presets),
    );
  }
}
