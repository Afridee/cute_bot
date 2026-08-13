// Companion (central) mode — the actual app. Built in M1: scan for the bot
// service, auto-connect, negotiate MTU, chunk framing, reconnect backoff.

import 'package:flutter/material.dart';

class CompanionPage extends StatelessWidget {
  const CompanionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Companion (central)')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Companion mode arrives in M1:\n'
            'scan, auto-connect, MTU negotiation, audio framing.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
