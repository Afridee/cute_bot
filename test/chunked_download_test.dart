import 'dart:io';
import 'dart:typed_data';

import 'package:cute_bot/companion/brain/chunked_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('planChunkRanges', () {
    test('covers the file without overlap or gaps', () {
      final ranges = planChunkRanges(1000, 4);
      expect(ranges, hasLength(4));
      expect(ranges.first.start, 0);
      expect(ranges.last.end, 999);
      for (var i = 1; i < ranges.length; i++) {
        expect(ranges[i].start, ranges[i - 1].end + 1);
      }
      final covered =
          ranges.fold<int>(0, (n, r) => n + (r.end - r.start + 1));
      expect(covered, 1000);
    });

    test('gives remainder to the last chunk', () {
      final ranges = planChunkRanges(10, 3);
      expect(ranges.map((r) => r.end - r.start + 1).toList(), [3, 3, 4]);
    });

    test('clamps chunk count to file size', () {
      expect(planChunkRanges(2, 8), hasLength(2));
      expect(planChunkRanges(0, 6), isEmpty);
    });
  });

  group('percentFromBytes', () {
    test('stays at 99 until the last byte', () {
      expect(percentFromBytes(0, 100), 0);
      expect(percentFromBytes(50, 100), 50);
      expect(percentFromBytes(99, 100), 99);
      expect(percentFromBytes(100, 100), 100);
      expect(percentFromBytes(0, 0), 0);
    });
  });

  group('isStrongEtag', () {
    test('rejects weak and empty validators', () {
      expect(isStrongEtag('"8309b67ca4f8772b14b51b3cda392d53-39"'), isTrue);
      expect(isStrongEtag('W/"abc"'), isFalse);
      expect(isStrongEtag('w/"abc"'), isFalse);
      expect(isStrongEtag('abc'), isFalse);
      expect(isStrongEtag(''), isFalse);
      expect(isStrongEtag(null), isFalse);
    });
  });

  group('modelFilenameFromUrl', () {
    test('takes the last path segment', () {
      expect(
        modelFilenameFromUrl(
          'https://models.afridee.dev/gemma-4-E2B-it.litertlm',
        ),
        'gemma-4-E2B-it.litertlm',
      );
      expect(modelFilenameFromUrl('https://example.com/'), 'gemma-4-E2B-it.litertlm');
    });
  });

  group('localModelLooksComplete', () {
    test('rejects missing and tiny files', () async {
      final dir = await Directory.systemTemp.createTemp('cute_bot_complete_');
      addTearDown(() => dir.delete(recursive: true));
      final missing = File('${dir.path}/nope.litertlm');
      expect(localModelLooksComplete(missing, minBytes: 10), isFalse);
      final tiny = File('${dir.path}/tiny.litertlm');
      await tiny.writeAsBytes(List<int>.filled(9, 1));
      expect(localModelLooksComplete(tiny, minBytes: 10), isFalse);
      await tiny.writeAsBytes(List<int>.filled(10, 1));
      expect(localModelLooksComplete(tiny, minBytes: 10), isTrue);
    });
  });

  group('downloadModelFile', () {
    test('pulls in parallel Range GETs and reports bytes written', () async {
      final payload = Uint8List.fromList(
        List<int>.generate(32 * 1024, (i) => i & 0xff),
      );
      final server = await _serve(payload, hold: const Duration(milliseconds: 80));
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('cute_bot_dl_');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/model.litertlm');
      final progress = <(int, int)>[];

      await downloadModelFile(
        url: 'http://127.0.0.1:${server.port}/model.litertlm',
        dest: dest,
        chunkCount: 4,
        onProgress: (written, total) => progress.add((written, total)),
      );

      expect(dest.readAsBytesSync(), payload);
      expect(server.maxInFlight, greaterThan(1));
      expect(progress, isNotEmpty);
      expect(progress.last, (payload.length, payload.length));
      expect(
        server.rangeGets,
        greaterThanOrEqualTo(4),
        reason: 'each chunk should Range-GET',
      );
      expect(server.sawNoStore, isFalse);
      expect(server.sawIdentityAcceptEncoding, isTrue);
      expect(File('${dest.path}.part0').existsSync(), isFalse);
    });

    test('resumes leftover part files', () async {
      final payload = Uint8List.fromList(
        List<int>.generate(8000, (i) => i & 0xff),
      );
      final server = await _serve(payload, etag: 'abc');
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('cute_bot_resume_');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/model.litertlm');
      await File('${dest.path}.meta').writeAsString(
        '{"url":"http://127.0.0.1:${server.port}/model.litertlm",'
        '"etag":"abc","length":8000,"chunks":2}',
      );
      final ranges = planChunkRanges(payload.length, 2);
      final firstLen = ranges[0].end - ranges[0].start + 1;
      await File('${dest.path}.part0').writeAsBytes(payload.sublist(0, 100));
      await File('${dest.path}.part1')
          .writeAsBytes(payload.sublist(ranges[1].start, payload.length));

      await downloadModelFile(
        url: 'http://127.0.0.1:${server.port}/model.litertlm',
        dest: dest,
        chunkCount: 2,
      );

      expect(dest.readAsBytesSync(), payload);
      expect(server.bytesServed, firstLen - 100);
      expect(firstLen, greaterThan(100));
    });

    test('discards parts when the ETag changes', () async {
      final payload = Uint8List.fromList(List<int>.filled(4000, 7));
      final server = await _serve(payload, etag: 'new');
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('cute_bot_etag_');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/model.litertlm');
      await File('${dest.path}.meta').writeAsString(
        '{"url":"http://127.0.0.1:${server.port}/model.litertlm",'
        '"etag":"old","length":4000,"chunks":2}',
      );
      await File('${dest.path}.part0').writeAsBytes(List<int>.filled(200, 1));

      await downloadModelFile(
        url: 'http://127.0.0.1:${server.port}/model.litertlm',
        dest: dest,
        chunkCount: 2,
      );

      expect(dest.readAsBytesSync(), payload);
      expect(server.bytesServed, payload.length);
    });

    test('skips the network when dest already looks complete', () async {
      final dir = await Directory.systemTemp.createTemp('cute_bot_skip_');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/model.litertlm');
      await dest.writeAsBytes(List<int>.filled(64, 9));
      var hits = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) {
        hits += 1;
        req.response.statusCode = 500;
        req.response.close();
      });

      final got = await downloadModelFile(
        url: 'http://127.0.0.1:${server.port}/model.litertlm',
        dest: dest,
        minCompleteBytes: 64,
      );
      expect(got.path, dest.path);
      expect(hits, 0);
    });

    test('stops when cancelled', () async {
      final payload = Uint8List.fromList(List<int>.filled(64 * 1024, 3));
      final server = await _serve(payload, stallAfter: 16);
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('cute_bot_cancel_');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/model.litertlm');
      var cancel = false;

      final future = downloadModelFile(
        url: 'http://127.0.0.1:${server.port}/model.litertlm',
        dest: dest,
        chunkCount: 1,
        isCancelled: () => cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancel = true;
      await expectLater(future, throwsA(isA<ChunkedDownloadCancelled>()));
    });
  });
}

final class _FakeCdn {
  _FakeCdn(this.server);

  final HttpServer server;
  int port = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  int rangeGets = 0;
  int bytesServed = 0;
  bool sawNoStore = false;
  bool sawIdentityAcceptEncoding = false;

  Future<void> close() => server.close(force: true);
}

Future<_FakeCdn> _serve(
  Uint8List payload, {
  String etag = '"cdn"',
  int? stallAfter,
  Duration hold = Duration.zero,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final fake = _FakeCdn(server)..port = server.port;
  server.listen((req) async {
    final cache = req.headers.value(HttpHeaders.cacheControlHeader) ?? '';
    if (cache.contains('no-store') || cache.contains('no-cache')) {
      fake.sawNoStore = true;
    }
    if ((req.headers.value(HttpHeaders.acceptEncodingHeader) ?? '')
        .contains('identity')) {
      fake.sawIdentityAcceptEncoding = true;
    }
    req.response.headers.set(HttpHeaders.etagHeader, etag);
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (req.method == 'HEAD') {
      req.response.headers.contentLength = payload.length;
      await req.response.close();
      return;
    }
    fake.inFlight += 1;
    if (fake.inFlight > fake.maxInFlight) fake.maxInFlight = fake.inFlight;
    if (hold > Duration.zero) {
      await Future<void>.delayed(hold);
    }
    try {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = payload.length - 1;
      if (range != null) {
        fake.rangeGets += 1;
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (match != null) {
          start = int.parse(match.group(1)!);
          end = match.group(2)!.isEmpty
              ? payload.length - 1
              : int.parse(match.group(2)!);
        }
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
      }
      final slice = payload.sublist(start, end + 1);
      fake.bytesServed += slice.length;
      req.response.headers.contentLength = slice.length;
      if (stallAfter != null && slice.length > stallAfter) {
        req.response.add(slice.sublist(0, stallAfter));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        req.response.add(slice.sublist(stallAfter));
      } else {
        req.response.add(slice);
      }
      await req.response.close();
    } finally {
      fake.inFlight -= 1;
    }
  });
  return fake;
}
