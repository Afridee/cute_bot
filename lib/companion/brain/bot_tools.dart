/// Tool schemas registered with Gemma 4 (M3).
///
/// Native function calling needs the JSON-schema tools at `createChat` time
/// so LiteRT-LM can constrain-decode `<|tool_call>` tokens. Full dispatch
/// through a `BotActuator` is M4; until then the service maps the
/// [ToolCall] events onto the existing BLE control writes, and the brain
/// feeds a stub result back so the model can finish the spoken turn.
library;

import 'package:flutter_gemma/flutter_gemma.dart';

/// The bot's body, as the model sees it. Names match the M4 table.
const List<Tool> kBotTools = [
  Tool(
    name: 'set_led',
    description:
        'Set the robot eye/LED color and pattern. Use this to show emotion '
        'or react — pink when happy, blue when thinking, red when startled.',
    parameters: {
      'type': 'object',
      'properties': {
        'color': {
          'type': 'string',
          'enum': [
            'red',
            'green',
            'blue',
            'pink',
            'purple',
            'yellow',
            'orange',
            'white',
            'cyan',
            'off',
          ],
          'description': 'LED color name',
        },
        'pattern': {
          'type': 'string',
          'enum': ['solid', 'blink', 'breathe', 'off'],
          'description': 'How the LED moves',
        },
      },
      'required': ['color', 'pattern'],
    },
  ),
  Tool(
    name: 'wiggle',
    description: 'Wiggle the robot body. A little physical yes / excitement.',
    parameters: {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  ),
  Tool(
    name: 'play_sound',
    description: 'Play a short on-robot sound.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'enum': ['chirp', 'beep', 'purr'],
          'description': 'Which sound',
        },
      },
      'required': ['name'],
    },
  ),
  Tool(
    name: 'set_timer',
    description:
        'Start a countdown on the phone. The robot will announce when it '
        'fires. Persistence of pending timers is M4; the call is accepted now.',
    parameters: {
      'type': 'object',
      'properties': {
        'minutes': {
          'type': 'integer',
          'description': 'Minutes until the timer fires',
        },
        'label': {
          'type': 'string',
          'description': 'What the timer is for',
        },
      },
      'required': ['minutes'],
    },
  ),
  Tool(
    name: 'get_battery',
    description: "Read the robot's battery level.",
    parameters: {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  ),
];

/// Stub tool result fed back into the chat so the model can produce a
/// spoken follow-up. Real results (battery %, timer id) land in M4.
Map<String, dynamic> stubToolResult(String name, Map<String, dynamic> args) {
  return switch (name) {
    'set_led' => {
        'status': 'ok',
        'color': args['color'],
        'pattern': args['pattern'],
      },
    'wiggle' => {'status': 'ok'},
    'play_sound' => {'status': 'ok', 'name': args['name']},
    'set_timer' => {
        'status': 'accepted',
        'minutes': args['minutes'],
        'label': args['label'],
        'note': 'timer persistence lands in M4',
      },
    'get_battery' => {
        'status': 'unknown',
        'note': 'battery telemetry is not wired into the brain yet (M4)',
      },
    _ => {'error': 'unknown tool $name'},
  };
}
