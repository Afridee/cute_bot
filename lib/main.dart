// Cute Bot — a phone-brained desk robot companion.
//
// One APK, two modes:
// - Bot Simulator: BLE peripheral, stands in for the ESP32 (run on phone #2)
// - Companion: BLE central + the brain (the actual app, built from M1 on)
//
// State management: plain ChangeNotifier throughout (brief rule 4).

import 'package:flutter/material.dart';

import 'bot_simulator/simulator_page.dart';
import 'companion/companion_page.dart';

void main() {
  runApp(const CuteBotApp());
}

class CuteBotApp extends StatelessWidget {
  const CuteBotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cute Bot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.pink),
      ),
      home: const ModeSelectPage(),
    );
  }
}

class ModeSelectPage extends StatelessWidget {
  const ModeSelectPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cute Bot')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ModeButton(
                icon: Icons.smart_toy,
                title: 'Bot Simulator',
                subtitle: 'This phone pretends to be the robot (peripheral)',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SimulatorPage()),
                ),
              ),
              const SizedBox(height: 16),
              _ModeButton(
                icon: Icons.phone_android,
                title: 'Companion',
                subtitle: 'The brain: connects to the bot (central)',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CompanionPage()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, size: 40),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context).textTheme.titleLarge),
                    Text(subtitle,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
