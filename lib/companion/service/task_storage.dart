/// KeyValueStore backed by flutter_foreground_task's data store
/// (SharedPreferences under the hood), usable from both isolates.
///
/// Chosen over adding a filesystem dependency: the brief's dependency rule
/// allows flutter_foreground_task, and its store is durable across process
/// death and reboot, which is all the transcript path needs. If transcripts
/// ever outgrow SharedPreferences, swapping the backend touches only this
/// file — TranscriptStore sees the same interface.
library;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../brain/transcript.dart';

final class TaskKeyValueStore implements KeyValueStore {
  const TaskKeyValueStore();

  @override
  Future<String?> read(String key) =>
      FlutterForegroundTask.getData<String>(key: key);

  @override
  Future<void> write(String key, String value) =>
      FlutterForegroundTask.saveData(key: key, value: value);

  @override
  Future<void> remove(String key) =>
      FlutterForegroundTask.removeData(key: key);
}
