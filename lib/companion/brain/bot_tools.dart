/// Tool schemas registered with Gemma 4 (M3/M4).
///
/// Native function calling needs the JSON-schema tools at `createChat` time
/// so LiteRT-LM can constrain-decode `<|tool_call>` tokens. Live dispatch
/// is `BotBody`; [stubToolResult] is the fallback when no executor is
/// wired (unit tests).
library;

import 'package:flutter_gemma/flutter_gemma.dart';

import '../expressions.dart';
import 'bot_brain.dart';

/// The bot's body, as the model sees it. Mute: `express` is the face;
/// `set_timer` / `cancel_timer` / `pause_timer` / `resume_timer` /
/// `get_battery` are the other verbs. LED / wiggle / sound primitives
/// stay phone-side (debug buttons, warming LEDs).
final List<Tool> kBotTools = [
  Tool(
    name: 'express',
    description:
        'Show a feeling with eyes, a sound, and maybe a wiggle. This is '
        'how you reply — you never speak. Pick the mood that fits.',
    parameters: {
      'type': 'object',
      'properties': {
        'mood': {
          'type': 'string',
          'enum': [for (final m in BotMood.values) m.name],
          'description': 'Which feeling to show',
        },
      },
      'required': ['mood'],
    },
  ),
  Tool(
    name: 'set_timer',
    description:
        'Start a countdown on the phone. If one is already pending, this '
        'replaces it — there is only ever one clock. The phone confirms '
        'with a yes expression, and the robot will express alarm when it '
        'fires. The timer survives a service restart.',
    parameters: {
      'type': 'object',
      'properties': {
        'minutes': {
          'type': 'integer',
          'description':
              'Whole minutes until the timer fires. Combine with seconds '
              'for mixed durations (1 minute 20 seconds → minutes 1, '
              'seconds 20).',
        },
        'seconds': {
          'type': 'integer',
          'description':
              'Seconds until the timer fires, or extra seconds on top of '
              'minutes. Use this for "20 seconds". At least one of '
              'minutes or seconds is required.',
        },
        'label': {
          'type': 'string',
          'description': 'What the timer is for',
        },
      },
    },
  ),
  Tool(
    name: 'cancel_timer',
    description:
        'Cancel the pending phone timer so it will not fire. The phone '
        'confirms with a yes expression, or no if none is pending.',
    parameters: {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  ),
  Tool(
    name: 'pause_timer',
    description:
        'Pause the pending phone timer. Remaining time freezes on the '
        'face until resume_timer.',
    parameters: {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  ),
  Tool(
    name: 'resume_timer',
    description:
        'Resume the paused phone timer. The phone confirms with a yes '
        'expression, or no if none is pending.',
    parameters: {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  ),
  Tool(
    name: 'get_battery',
    description:
        "Read the robot's battery level, then express from the number "
        '(low_battery if low, yes if fine, sleepy if tired).',
    parameters: {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  ),
];

/// Tools whose result the model must see before it can express. `express`
/// and the timer tools are terminal — do not spend a second decode on them.
bool needsToolFollowUp(String name) => name == 'get_battery';

/// Compact few-shot lines the model may leak as text instead of native
/// `<|tool_call>` tokens: `express(curious)`, `set_timer(3, tea)`,
/// `cancel_timer()`, `get_battery()`. Order is left-to-right as they
/// appear in [text].
List<ToolCall> parseLeakedToolCalls(String text) {
  if (text.isEmpty) return const [];
  final calls = <ToolCall>[];
  final re = RegExp(
    r'\b(?:'
    r'express\s*\(\s*([a-z_]+)\s*\)'
    r'|set_timer\s*\(\s*(\d+)\s*(?:,\s*([^)]*?))?\s*\)'
    r'|(cancel_timer|pause_timer|resume_timer)\s*\(\s*([^)]*?)\s*\)'
    r'|get_battery\s*\(\s*\)'
    r')',
    caseSensitive: false,
  );
  for (final match in re.allMatches(text)) {
    final raw = match.group(0)!;
    final lower = raw.toLowerCase();
    if (lower.startsWith('express')) {
      final mood = match.group(1)?.toLowerCase();
      if (mood != null && expressionFor(mood) != null) {
        calls.add(ToolCall('express', {'mood': mood}));
      }
    } else if (lower.startsWith('set_timer')) {
      final minutes = int.tryParse(match.group(2) ?? '');
      if (minutes == null || minutes < 1) continue;
      var label = (match.group(3) ?? 'timer').trim();
      if (label.length >= 2 &&
          ((label.startsWith('"') && label.endsWith('"')) ||
              (label.startsWith("'") && label.endsWith("'")))) {
        label = label.substring(1, label.length - 1).trim();
      }
      calls.add(ToolCall('set_timer', {
        'minutes': minutes,
        'label': label.isEmpty ? 'timer' : label,
      }));
    } else if (lower.startsWith('cancel_timer') ||
        lower.startsWith('pause_timer') ||
        lower.startsWith('resume_timer')) {
      final name = (match.group(4) ?? '').toLowerCase();
      calls.add(ToolCall(name, {}));
    } else {
      calls.add(const ToolCall('get_battery', {}));
    }
  }
  return calls;
}

/// Fallback tool result when no live executor is wired (tests).
Map<String, dynamic> stubToolResult(String name, Map<String, dynamic> args) {
  return switch (name) {
    'express' => {
        'status': 'ok',
        'mood': args['mood'],
      },
    'set_timer' => {
        'status': 'ok',
        'minutes': args['minutes'],
        'seconds': args['seconds'],
        'label': args['label'],
      },
    'cancel_timer' || 'pause_timer' || 'resume_timer' => {
        'status': 'ok',
        'label': args['label'],
      },
    'get_battery' => {
        'status': 'unknown',
        'percent': null,
      },
    _ => {'error': 'unknown tool $name'},
  };
}
