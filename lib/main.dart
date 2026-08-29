// Cute Bot — a phone-brained desk robot companion.
//
// One APK, two modes:
// - Bot Simulator: BLE peripheral, stands in for the ESP32 (run on phone #2)
// - Companion: BLE central + the brain (the actual app, built from M1 on)
//
// State management: plain ChangeNotifier throughout (brief rule 4).

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'bot_simulator/simulator_page.dart';
import 'companion/companion_page.dart';
import 'design/design.dart';

void main() {
  // Receive port for foreground-service -> UI messages (M2). Must be set up
  // before runApp so an already-running service reattaches on app relaunch.
  FlutterForegroundTask.initCommunicationPort();
  runApp(const CuteBotApp());
}

class CuteBotApp extends StatefulWidget {
  const CuteBotApp({super.key});

  @override
  State<CuteBotApp> createState() => _CuteBotAppState();
}

class _CuteBotAppState extends State<CuteBotApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cute Bot',
      theme: CuteBotTheme.light,
      darkTheme: CuteBotTheme.dark,
      themeMode: _themeMode,
      home: ModeSelectPage(
        themeMode: _themeMode,
        onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}

class ModeSelectPage extends StatelessWidget {
  const ModeSelectPage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CuteBotSpace.lg,
            CuteBotSpace.xl,
            CuteBotSpace.lg,
            CuteBotSpace.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CUTE BOT', style: nd.typography.displayLg),
              const SizedBox(height: CuteBotSpace.xxxxl),
              _ModeRow(
                title: 'Companion',
                subtitle: 'The brain: connects to the desk bot or simulator',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CompanionPage(),
                  ),
                ),
              ),
              const SizedBox(height: CuteBotSpace.xl),
              _ModeRow(
                title: 'Bot Simulator',
                subtitle: 'This phone pretends to be the robot (peripheral)',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SimulatorPage(),
                  ),
                ),
              ),
              const Spacer(),
              NdSegmentedControl<ThemeMode>(
                value: themeMode,
                onChanged: onThemeModeChanged,
                segments: const [
                  (ThemeMode.dark, 'Dark'),
                  (ThemeMode.light, 'Light'),
                ],
              ),
              const SizedBox(height: CuteBotSpace.md),
              Text('PHONE BRAIN  ·  BLE EARS', style: nd.typography.label),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: nd.typography.heading),
          const SizedBox(height: CuteBotSpace.xs),
          Text(
            subtitle,
            style: nd.typography.body.copyWith(color: nd.colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
