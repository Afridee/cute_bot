/// Model-file install helpers: progress/ETA copy, the isolate-wide install
/// gate, a Wi-Fi wait, and a one-time sweep of leftover SmartDownloader
/// temps (`com.bbflight.background_downloader*`).
///
/// New installs go through [downloadModelFile] + `fromFile`, not
/// flutter_gemma `fromNetwork` / the `smart_downloads` group. Collapse is
/// only here so an upgrade from that path does not leave WorkManager
/// writing into abandoned temps.
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../shared/log.dart';
import 'chunked_download.dart';

export 'chunked_download.dart'
    show
        ChunkedDownloadCancelled,
        downloadModelFile,
        kGemmaModelMinBytes,
        kModelDownloadChunks,
        localModelLooksComplete,
        modelFilenameFromUrl,
        percentFromBytes,
        planChunkRanges;

const String _tag = 'ModelDownload';

/// flutter_gemma [SmartDownloader.downloadGroup]. Cancel/reset must match
/// or leftover WorkManager jobs from older builds keep writing.
const String kGemmaDownloadGroup = 'smart_downloads';

/// Filename prefix background_downloader gives every partial temp.
const String kDownloadTempPrefix = 'com.bbflight.background_downloader';

/// Isolate-wide gate: two [GemmaBrain] instances share one install.
@visibleForTesting
Future<void>? exclusiveModelInstallInFlight;

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

/// Wi-Fi (or ethernet) only — the 2.6 GB pull must not start on cellular.
bool wifiAllowsDownload(List<ConnectivityResult> results) {
  return results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet);
}

/// Block until the device is on Wi-Fi/ethernet, or [isCancelled] trips.
Future<void> waitUntilWifi({
  Future<bool> Function()? isWifi,
  bool Function()? isCancelled,
  Duration poll = const Duration(seconds: 2),
}) async {
  isWifi ??= _deviceIsWifi;
  var logged = false;
  while (true) {
    if (isCancelled?.call() ?? false) {
      throw const ChunkedDownloadCancelled();
    }
    if (await isWifi()) return;
    if (!logged) {
      Log.i(_tag, 'waiting for Wi-Fi before downloading the model');
      logged = true;
    }
    await Future<void>.delayed(poll);
  }
}

Future<bool> _deviceIsWifi() async {
  try {
    return wifiAllowsDownload(await Connectivity().checkConnectivity());
  } catch (e) {
    Log.w(_tag, 'Wi-Fi check failed: $e');
    return false;
  }
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

/// Cancel leftover `smart_downloads` workers and delete
/// `com.bbflight.background_downloader*` temps. One-time upgrade cleanup;
/// we do not enqueue that group anymore.
Future<void> collapseLeftoverModelDownloads({
  Future<void> Function()? cancelTracked,
  Future<int> Function()? deleteTemps,
}) async {
  final injecting = cancelTracked != null || deleteTemps != null;
  try {
    await (cancelTracked ?? (injecting ? () async {} : _cancelTracked))();
  } catch (e) {
    Log.w(_tag, 'cancel leftover downloads failed: $e');
  }
  try {
    final n = await (deleteTemps ??
        (injecting ? () async => 0 : _deleteDefaultTemps))();
    if (n > 0) Log.i(_tag, 'deleted $n leftover download temps');
  } catch (e) {
    Log.w(_tag, 'temp sweep failed: $e');
  }
}

Future<int> _deleteDefaultTemps() async {
  return deleteDownloadTempsIn(await modelDownloadTempDirs());
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
