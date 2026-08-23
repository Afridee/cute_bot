/// Collapse leftover flutter_gemma / background_downloader workers so
/// [GemmaBrain] cannot enqueue a second 2.6 GB pull of the same file.
///
/// Observed on device: one task id, many `com.bbflight.background_downloader*`
/// temps growing at once. HuggingFace cannot resume (weak ETags), so every
/// service restart / retry allocated a new temp next to the old workers.
/// Dart's download DB can be empty while WorkManager is still writing.
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../shared/log.dart';

const String _tag = 'ModelDownload';

/// flutter_gemma [SmartDownloader.downloadGroup]. Must match or reset/cancel
/// no-ops and the leftover workers keep going.
const String kGemmaDownloadGroup = 'smart_downloads';

/// Filename prefix background_downloader gives every partial temp.
const String kDownloadTempPrefix = 'com.bbflight.background_downloader';

/// How long we re-cancel / re-delete after a collapse before enqueueing.
/// WorkManager can keep writing for a beat after `cancelAll`.
const int kCollapseIdleAttempts = 12;
const Duration kCollapseIdleGap = Duration(milliseconds: 250);

/// Extra quiet time after workers look idle. `cancelAll` is keyed by the
/// same deterministic task id `installModel` will reuse; a late native
/// cancel otherwise kills the new enqueue at 0%.
const Duration kCollapseSettle = Duration(milliseconds: 1500);

/// Isolate-wide gate: two [GemmaBrain] instances share one install.
@visibleForTesting
Future<void>? exclusiveModelInstallInFlight;

/// Whether leftover native state must be torn down before `installModel`.
///
/// A temp with no tracked Dart task is the storm we saw: WorkManager writing
/// while `installModel` would enqueue another pull of the same path.
enum ModelDownloadPrep { enqueue, attach, collapseThenEnqueue }

ModelDownloadPrep decideModelDownloadPrep({
  required int trackedTaskCount,
  required int liveTempCount,
}) {
  if (trackedTaskCount > 1 || liveTempCount > 1) {
    return ModelDownloadPrep.collapseThenEnqueue;
  }
  if (liveTempCount == 1 && trackedTaskCount == 0) {
    return ModelDownloadPrep.collapseThenEnqueue;
  }
  if (trackedTaskCount == 1) return ModelDownloadPrep.attach;
  return ModelDownloadPrep.enqueue;
}

/// `installModel` attaches only when `taskForId` hits. Otherwise it takes
/// the fresh-enqueue path on the same task id and a second temp starts
/// growing — the 2% / 6% log fight.
ModelDownloadPrep refineModelDownloadPrep({
  required ModelDownloadPrep prep,
  required bool trackedTaskVisible,
}) {
  if (prep == ModelDownloadPrep.attach && !trackedTaskVisible) {
    return ModelDownloadPrep.collapseThenEnqueue;
  }
  return prep;
}

bool modelDownloadWorkersIdle({
  required int trackedTaskCount,
  required int liveTempCount,
}) =>
    trackedTaskCount == 0 && liveTempCount == 0;

/// Keep the UI bar from bouncing when two workers report the same task id.
/// A drop to 0–1% is treated as a real restart.
int holdDownloadPercent(int? previous, int incoming) {
  if (previous == null || incoming >= previous || incoming <= 1) {
    return incoming;
  }
  return previous;
}

/// Wait until a couple of percent have landed so 0% does not say
/// "years left". Integer percent makes this jumpy early; it settles.
const int kDownloadEtaMinPercent = 3;
const Duration kDownloadEtaMinElapsed = Duration(seconds: 8);

/// Linear ETA from [percent] and time already spent. Null until the
/// sample is large enough to be worth showing.
Duration? estimateDownloadRemaining({
  required int percent,
  required Duration elapsed,
}) {
  if (percent >= 100) return Duration.zero;
  if (percent < kDownloadEtaMinPercent || elapsed < kDownloadEtaMinElapsed) {
    return null;
  }
  return Duration(
    microseconds: elapsed.inMicroseconds * (100 - percent) ~/ percent,
  );
}

/// Short copy for the setup wait and Brain card.
String formatDownloadRemaining(Duration remaining) {
  final seconds = remaining.inSeconds;
  if (seconds < 45) return 'less than a minute left';
  final minutes = (seconds + 30) ~/ 60;
  if (minutes == 1) return 'about 1 minute left';
  if (minutes < 90) return 'about $minutes minutes left';
  final hours = (minutes + 30) ~/ 60;
  if (hours == 1) return 'about 1 hour left';
  return 'about $hours hours left';
}

String downloadProgressLabel(int percent, int? remainingSec) {
  if (remainingSec == null) return 'Downloading $percent%';
  return 'Downloading $percent% · '
      '${formatDownloadRemaining(Duration(seconds: remainingSec))}';
}

bool isCuteBotModelTask({required String url, required String filename}) {
  return filename.endsWith('.litertlm') ||
      url.contains('gemma-4-E2B-it.litertlm');
}

/// Plugin cancel (`DownloadException: Download was canceled`) and our
/// [CancelToken] both mean "try once more", not a hard warm-up failure.
bool isRecoverableModelDownloadCancel(Object error) {
  final text = error.toString();
  return text.contains('Download was canceled') ||
      text.contains('DownloadCancelled') ||
      text.contains('forked download');
}

/// Shared by overlapping [GemmaBrain.warmUp] calls in one isolate.
Future<void> runExclusiveModelInstall(Future<void> Function() body) {
  return exclusiveModelInstallInFlight ??= body().whenComplete(() {
    exclusiveModelInstallInFlight = null;
  });
}

@visibleForTesting
void resetExclusiveModelInstallGate() {
  exclusiveModelInstallInFlight = null;
}

/// Resume native workers, then cancel + delete only when [decideModelDownloadPrep]
/// says this is a storm (or an untracked leftover temp).
Future<void> collapseLeftoverModelDownloads({
  Future<void> Function()? resumeFromBackground,
  Future<void> Function()? cancelTracked,
  Future<int> Function()? deleteTemps,
}) async {
  if (resumeFromBackground != null ||
      cancelTracked != null ||
      deleteTemps != null) {
    await _runCollapsePipeline(
      resumeFromBackground: resumeFromBackground ?? () async {},
      cancelTracked: cancelTracked ?? () async {},
      deleteTemps: deleteTemps ?? () async => 0,
    );
    return;
  }
  await _collapseDefault();
}

Future<void> _runCollapsePipeline({
  required Future<void> Function() resumeFromBackground,
  required Future<void> Function() cancelTracked,
  required Future<int> Function() deleteTemps,
}) async {
  try {
    await resumeFromBackground();
  } catch (e) {
    Log.w(_tag, 'resumeFromBackground failed: $e');
  }
  try {
    await cancelTracked();
  } catch (e) {
    Log.w(_tag, 'cancel leftover downloads failed: $e');
  }
  try {
    final n = await deleteTemps();
    if (n > 0) Log.i(_tag, 'deleted $n leftover download temps');
  } catch (e) {
    Log.w(_tag, 'temp sweep failed: $e');
  }
}

Future<void> _collapseDefault() async {
  // Do not resumeFromBackground before this decision. That wakes the
  // leftover WorkManager job so cancelAll and the new enqueue share a
  // task id while the native cancel is still in flight.
  final downloader = FileDownloader();
  List<Task> ours = const [];
  try {
    ours = (await downloader.allTasks(allGroups: true))
        .where((t) =>
            t.group == kGemmaDownloadGroup ||
            isCuteBotModelTask(url: t.url, filename: t.filename))
        .toList();
  } catch (e) {
    Log.w(_tag, 'allTasks failed: $e');
  }

  var dirs = <Directory>[];
  var temps = 0;
  try {
    dirs = await modelDownloadTempDirs();
    temps = await countDownloadTempsIn(dirs);
  } catch (e) {
    Log.w(_tag, 'temp count failed: $e');
  }

  var visible = false;
  if (ours.length == 1) {
    try {
      visible = await downloader.taskForId(ours.first.taskId) != null;
    } catch (e) {
      Log.w(_tag, 'taskForId failed: $e');
    }
  }

  final prep = refineModelDownloadPrep(
    prep: decideModelDownloadPrep(
      trackedTaskCount: ours.length,
      liveTempCount: temps,
    ),
    trackedTaskVisible: visible,
  );
  Log.i(
    _tag,
    'prep ${prep.name} (tracked=${ours.length} visible=$visible temps=$temps)',
  );
  if (prep == ModelDownloadPrep.attach) {
    Log.i(_tag, 'attaching ${ours.first.taskId}');
    try {
      await _resumeFromBackground();
    } catch (e) {
      Log.w(_tag, 'resumeFromBackground failed: $e');
    }
    return;
  }

  // enqueue too: WorkManager can still hold a persisted job after we
  // deleted its temp. cancelAll is a no-op when nothing is there.

  await _runCollapsePipeline(
    resumeFromBackground: () async {},
    cancelTracked: _cancelTracked,
    deleteTemps: () => deleteDownloadTempsIn(dirs),
  );

  final idle = await waitForModelDownloadIdle(
    countTemps: () => countDownloadTempsIn(dirs),
    countTasks: _countOurs,
    cancelTracked: _cancelTracked,
    deleteTemps: () => deleteDownloadTempsIn(dirs),
  );
  if (!idle) {
    Log.w(_tag, 'workers still alive after collapse; enqueueing anyway');
  }
  await Future<void>.delayed(kCollapseSettle);
}

/// Dirs background_downloader may drop a temp into (support vs cache
/// depends on the Content-Length it saw for that worker).
Future<List<Directory>> modelDownloadTempDirs() async {
  final out = <Directory>[];
  for (final getter in [
    getApplicationSupportDirectory,
    getTemporaryDirectory,
    getApplicationDocumentsDirectory,
  ]) {
    try {
      out.add(await getter());
    } catch (_) {}
  }
  return out;
}

Future<int> countLiveModelDownloadTemps() async {
  return countDownloadTempsIn(await modelDownloadTempDirs());
}

Future<int> countDownloadTempsIn(Iterable<Directory> dirs) async {
  var n = 0;
  for (final dir in dirs) {
    n += await countDownloadTemps(dir);
  }
  return n;
}

Future<int> deleteDownloadTempsIn(Iterable<Directory> dirs) async {
  var n = 0;
  for (final dir in dirs) {
    n += await deleteDownloadTemps(dir);
  }
  return n;
}

Future<bool> waitForModelDownloadIdle({
  required Future<int> Function() countTemps,
  required Future<int> Function() countTasks,
  required Future<void> Function() cancelTracked,
  required Future<int> Function() deleteTemps,
  int attempts = kCollapseIdleAttempts,
  Duration gap = kCollapseIdleGap,
}) async {
  for (var i = 0; i < attempts; i++) {
    final temps = await countTemps();
    final tasks = await countTasks();
    if (modelDownloadWorkersIdle(
      trackedTaskCount: tasks,
      liveTempCount: temps,
    )) {
      return true;
    }
    try {
      await cancelTracked();
    } catch (e) {
      Log.w(_tag, 'cancel leftover downloads failed: $e');
    }
    try {
      await deleteTemps();
    } catch (e) {
      Log.w(_tag, 'temp sweep failed: $e');
    }
    if (gap > Duration.zero) {
      await Future<void>.delayed(gap);
    }
  }
  return false;
}

Future<int> countDownloadTemps(Directory dir) async {
  if (!dir.existsSync()) return 0;
  var n = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is File &&
        p.basename(entity.path).startsWith(kDownloadTempPrefix)) {
      n++;
    }
  }
  return n;
}

Future<int> deleteDownloadTemps(Directory dir) async {
  if (!dir.existsSync()) return 0;
  var n = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    if (!p.basename(entity.path).startsWith(kDownloadTempPrefix)) continue;
    try {
      await entity.delete();
      n++;
    } catch (_) {}
  }
  return n;
}

Future<void> _resumeFromBackground() =>
    FileDownloader().resumeFromBackground();

Future<int> _countOurs() async {
  try {
    return (await FileDownloader().allTasks(allGroups: true))
        .where((t) =>
            t.group == kGemmaDownloadGroup ||
            isCuteBotModelTask(url: t.url, filename: t.filename))
        .length;
  } catch (e) {
    Log.w(_tag, 'allTasks failed: $e');
    return -1;
  }
}

Future<void> _cancelTracked() async {
  final downloader = FileDownloader();
  await downloader.cancelAll(group: kGemmaDownloadGroup);
  for (final task in await downloader.allTasks(allGroups: true)) {
    if (isCuteBotModelTask(url: task.url, filename: task.filename)) {
      await downloader.cancelTaskWithId(task.taskId);
    }
  }
  await downloader.reset(group: kGemmaDownloadGroup);
}
