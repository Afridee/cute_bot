import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cute_bot/companion/brain/model_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(resetExclusiveModelInstallGate);

  group('holdDownloadPercent', () {
    test('keeps the high-water mark unless the download restarts', () {
      expect(holdDownloadPercent(null, 2), 2);
      expect(holdDownloadPercent(6, 7), 7);
      expect(holdDownloadPercent(7, 3), 7);
      expect(holdDownloadPercent(7, 1), 1);
      expect(holdDownloadPercent(7, 0), 0);
    });
  });

  group('estimateDownloadRemaining', () {
    test('waits for enough percent and elapsed', () {
      expect(
        estimateDownloadRemaining(
          percent: 2,
          elapsed: const Duration(seconds: 20),
        ),
        isNull,
      );
      expect(
        estimateDownloadRemaining(
          percent: 10,
          elapsed: const Duration(seconds: 4),
        ),
        isNull,
      );
    });

    test('scales remaining from elapsed and percent', () {
      expect(
        estimateDownloadRemaining(
          percent: 25,
          elapsed: const Duration(seconds: 60),
        ),
        const Duration(seconds: 180),
      );
      expect(
        estimateDownloadRemaining(
          percent: 100,
          elapsed: const Duration(minutes: 10),
        ),
        Duration.zero,
      );
    });
  });

  group('formatDownloadRemaining', () {
    test('uses short spoken units', () {
      expect(
        formatDownloadRemaining(const Duration(seconds: 20)),
        'less than a minute left',
      );
      expect(
        formatDownloadRemaining(const Duration(seconds: 60)),
        'about 1 minute left',
      );
      expect(
        formatDownloadRemaining(const Duration(minutes: 10)),
        'about 10 minutes left',
      );
      expect(
        formatDownloadRemaining(const Duration(minutes: 95)),
        'about 2 hours left',
      );
    });

    test('downloadProgressLabel omits ETA until one exists', () {
      expect(downloadProgressLabel(8, null), 'Downloading 8%');
      expect(
        downloadProgressLabel(42, 600),
        'Downloading 42% · about 10 minutes left',
      );
    });
  });

  group('wifiAllowsDownload', () {
    test('allows wifi and ethernet, not cellular', () {
      expect(wifiAllowsDownload([ConnectivityResult.wifi]), isTrue);
      expect(wifiAllowsDownload([ConnectivityResult.ethernet]), isTrue);
      expect(
        wifiAllowsDownload(
          [ConnectivityResult.mobile, ConnectivityResult.wifi],
        ),
        isTrue,
      );
      expect(wifiAllowsDownload([ConnectivityResult.mobile]), isFalse);
      expect(wifiAllowsDownload([ConnectivityResult.none]), isFalse);
    });
  });

  group('waitUntilWifi', () {
    test('returns once isWifi becomes true', () async {
      var checks = 0;
      await waitUntilWifi(
        isWifi: () async => ++checks >= 3,
        poll: Duration.zero,
      );
      expect(checks, 3);
    });

    test('throws when cancelled before wifi appears', () async {
      await expectLater(
        waitUntilWifi(
          isWifi: () async => false,
          isCancelled: () => true,
          poll: Duration.zero,
        ),
        throwsA(isA<ChunkedDownloadCancelled>()),
      );
    });
  });

  test('countDownloadTempsIn sums every scanned dir', () async {
    final a = await Directory.systemTemp.createTemp('cute_bot_dl_a_');
    final b = await Directory.systemTemp.createTemp('cute_bot_dl_b_');
    addTearDown(() => a.delete(recursive: true));
    addTearDown(() => b.delete(recursive: true));
    await File('${a.path}/com.bbflight.background_downloader1').writeAsString('a');
    await File('${b.path}/com.bbflight.background_downloader2').writeAsString('b');
    await File('${b.path}/keep_me').writeAsString('c');

    expect(await countDownloadTempsIn([a, b]), 2);
    expect(await deleteDownloadTempsIn([a, b]), 2);
    expect(File('${b.path}/keep_me').existsSync(), isTrue);
  });

  group('isCuteBotModelTask', () {
    test('matches the E2B bundle by filename or URL', () {
      expect(
        isCuteBotModelTask(url: '', filename: 'gemma-4-E2B-it.litertlm'),
        isTrue,
      );
      expect(
        isCuteBotModelTask(url: 'https://example.com/other.bin', filename: 'other.bin'),
        isFalse,
      );
      expect(
        isCuteBotModelTask(
          url:
              'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
          filename: 'partial',
        ),
        isTrue,
      );
    });
  });

  test('deleteDownloadTemps removes only bbflight partials', () async {
    final dir = await Directory.systemTemp.createTemp('cute_bot_dl_');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/com.bbflight.background_downloader123').writeAsString('a');
    await File('${dir.path}/com.bbflight.background_downloader-9').writeAsString('b');
    await File('${dir.path}/keep_me').writeAsString('c');
    await Directory('${dir.path}/subdir').create();

    expect(await countDownloadTemps(dir), 2);
    expect(await deleteDownloadTemps(dir), 2);
    expect(File('${dir.path}/keep_me').existsSync(), isTrue);
    expect(
      File('${dir.path}/com.bbflight.background_downloader123').existsSync(),
      isFalse,
    );
  });

  test('runExclusiveModelInstall shares one in-flight body', () async {
    var runs = 0;
    Future<void> body() async {
      runs += 1;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    await Future.wait([
      runExclusiveModelInstall(body),
      runExclusiveModelInstall(body),
    ]);
    expect(runs, 1);
  });

  test('collapseLeftoverModelDownloads cancels then deletes leftover temps',
      () async {
    final log = <String>[];
    await collapseLeftoverModelDownloads(
      cancelTracked: () async => log.add('cancel'),
      deleteTemps: () async {
        log.add('delete');
        return 3;
      },
    );
    expect(log, ['cancel', 'delete']);
  });
}
