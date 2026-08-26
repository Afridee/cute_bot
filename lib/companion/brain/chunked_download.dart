/// Parallel Range GET of a model file, then [GemmaBrain] registers it with
/// flutter_gemma `fromFile`. Replaces `installModel().fromNetwork()` so we
/// own resume, concurrency, and request headers (no `Cache-Control: no-store`).
///
/// Requires the origin to advertise `Accept-Ranges: bytes` and a
/// `Content-Length`. A strong ETag lets a later warm-up keep part files;
/// a mismatch discards them and starts clean.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../shared/log.dart';

const String _tag = 'ChunkedDownload';

/// Parallel connections. 4–8 saturates a typical CDN without melting a phone.
const int kModelDownloadChunks = 6;

/// Truncated HTML / leftover SmartDownloader partials fail this. The E2B
/// bundle on our CDN is 2,588,147,712 bytes.
const int kGemmaModelMinBytes = 2500000000;

final class ChunkedDownloadCancelled implements Exception {
  const ChunkedDownloadCancelled();

  @override
  String toString() => 'ChunkedDownloadCancelled';
}

final class RemoteFileInfo {
  const RemoteFileInfo({
    required this.contentLength,
    required this.acceptRanges,
    this.etag,
  });

  final int contentLength;
  final bool acceptRanges;
  final String? etag;
}

/// Inclusive byte ranges covering `[0, totalBytes)`.
List<({int start, int end})> planChunkRanges(int totalBytes, int chunkCount) {
  if (totalBytes <= 0) return const [];
  final n = math.max(1, math.min(chunkCount, totalBytes));
  final size = totalBytes ~/ n;
  final ranges = <({int start, int end})>[];
  var start = 0;
  for (var i = 0; i < n; i++) {
    final end = i == n - 1 ? totalBytes - 1 : start + size - 1;
    ranges.add((start: start, end: end));
    start = end + 1;
  }
  return ranges;
}

int percentFromBytes(int written, int total) {
  if (total <= 0) return 0;
  if (written >= total) return 100;
  return (written * 100 ~/ total).clamp(0, 99);
}

bool isStrongEtag(String? etag) {
  if (etag == null) return false;
  final t = etag.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('W/') || t.startsWith('w/')) return false;
  return t.startsWith('"') && t.endsWith('"') && t.length > 2;
}

bool localModelLooksComplete(
  File dest, {
  int minBytes = kGemmaModelMinBytes,
}) {
  return dest.existsSync() && dest.lengthSync() >= minBytes;
}

String modelFilenameFromUrl(String url) {
  final segments =
      Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ??
          const [];
  final name = segments.isEmpty ? null : segments.last;
  if (name == null || !name.contains('.')) {
    return 'gemma-4-E2B-it.litertlm';
  }
  return name;
}

/// Probe [url] then pull it into [dest] with parallel Range GETs.
///
/// Skips the network when [dest] already looks complete. Part files sit
/// next to [dest] (`*.part0` …) so a killed service can resume.
Future<File> downloadModelFile({
  required String url,
  required File dest,
  String? token,
  int chunkCount = kModelDownloadChunks,
  int minCompleteBytes = kGemmaModelMinBytes,
  void Function(int bytesWritten, int totalBytes)? onProgress,
  bool Function()? isCancelled,
  HttpClient? client,
}) async {
  bool cancelled() => isCancelled?.call() ?? false;
  if (cancelled()) throw const ChunkedDownloadCancelled();

  if (localModelLooksComplete(dest, minBytes: minCompleteBytes)) {
    final n = dest.lengthSync();
    onProgress?.call(n, n);
    return dest;
  }

  final ownedClient = client == null;
  final http = client ??
      (HttpClient()
        ..autoUncompress = false
        ..maxConnectionsPerHost = chunkCount
        ..connectionTimeout = const Duration(seconds: 20)
        ..userAgent = 'CuteBot/1.0');
  try {
    final uri = Uri.parse(url);
    final info = await probeRemoteFile(http, uri, token: token);
    if (info.contentLength <= 0) {
      throw StateError('no Content-Length for $url');
    }
    if (dest.existsSync() && dest.lengthSync() == info.contentLength) {
      onProgress?.call(info.contentLength, info.contentLength);
      return dest;
    }
    if (dest.existsSync()) {
      Log.w(
        _tag,
        'discarding incomplete dest (${dest.lengthSync()} of ${info.contentLength})',
      );
      await dest.delete();
    }

    final n = info.acceptRanges ? chunkCount : 1;
    final ranges = planChunkRanges(info.contentLength, n);
    final meta = _metaFile(dest);
    await _reconcileParts(
      dest: dest,
      meta: meta,
      url: url,
      info: info,
      chunkCount: ranges.length,
    );

    final have = List<int>.filled(ranges.length, 0);
    for (var i = 0; i < ranges.length; i++) {
      final part = _partFile(dest, i);
      final expected = ranges[i].end - ranges[i].start + 1;
      have[i] = part.existsSync() ? part.lengthSync() : 0;
      if (have[i] > expected) {
        await part.delete();
        have[i] = 0;
      }
    }
    void emit() {
      final written = have.fold<int>(0, (a, b) => a + b);
      onProgress?.call(written, info.contentLength);
    }

    emit();
    Log.i(
      _tag,
      'GET $url (${info.contentLength} bytes, '
      '${ranges.length} chunk${ranges.length == 1 ? '' : 's'}, '
      'etag=${info.etag ?? 'none'})',
    );

    await Future.wait([
      for (var i = 0; i < ranges.length; i++)
        _downloadChunk(
          client: http,
          uri: uri,
          partFile: _partFile(dest, i),
          start: ranges[i].start,
          endInclusive: ranges[i].end,
          token: token,
          onHave: (bytes) {
            have[i] = bytes;
            emit();
          },
          isCancelled: cancelled,
        ),
    ]);

    if (cancelled()) throw const ChunkedDownloadCancelled();
    await _assemble(dest, ranges.length, info.contentLength);
    try {
      await meta.delete();
    } catch (_) {}
    onProgress?.call(info.contentLength, info.contentLength);
    return dest;
  } finally {
    if (ownedClient) http.close(force: true);
  }
}

Future<RemoteFileInfo> probeRemoteFile(
  HttpClient client,
  Uri uri, {
  String? token,
}) async {
  try {
    final req = await client.headUrl(uri);
    _applyHeaders(req, token: token);
    final res = await req.close().timeout(const Duration(seconds: 20));
    await res.drain<void>();
    final length = _contentLengthOf(res);
    final etag = res.headers.value(HttpHeaders.etagHeader);
    final ranges = _acceptsRanges(res);
    if (res.statusCode == 200 && length > 0) {
      return RemoteFileInfo(
        contentLength: length,
        acceptRanges: ranges,
        etag: etag,
      );
    }
    Log.w(_tag, 'HEAD ${res.statusCode}, falling back to Range 0-0');
  } catch (e) {
    Log.w(_tag, 'HEAD failed, falling back to Range 0-0: $e');
  }

  final req = await client.getUrl(uri);
  _applyHeaders(req, token: token);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
  final res = await req.close().timeout(const Duration(seconds: 20));
  final etag = res.headers.value(HttpHeaders.etagHeader);
  final length = _totalFromContentRange(res) ?? _contentLengthOf(res);
  final ranges = res.statusCode == 206 || _acceptsRanges(res);
  await res.drain<void>();
  if (length <= 0) {
    throw StateError('could not probe $uri (${res.statusCode})');
  }
  return RemoteFileInfo(
    contentLength: length,
    acceptRanges: ranges,
    etag: etag,
  );
}

void _applyHeaders(HttpClientRequest req, {String? token}) {
  req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  if (token != null && token.isNotEmpty) {
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
}

bool _acceptsRanges(HttpClientResponse res) {
  final v = res.headers.value(HttpHeaders.acceptRangesHeader);
  return v != null && v.toLowerCase().contains('bytes');
}

int _contentLengthOf(HttpClientResponse res) {
  final header = res.headers.value(HttpHeaders.contentLengthHeader);
  if (header != null) {
    return int.tryParse(header) ?? 0;
  }
  return res.contentLength < 0 ? 0 : res.contentLength;
}

int? _totalFromContentRange(HttpClientResponse res) {
  final cr = res.headers.value(HttpHeaders.contentRangeHeader);
  if (cr == null) return null;
  final slash = cr.lastIndexOf('/');
  if (slash < 0 || slash == cr.length - 1) return null;
  return int.tryParse(cr.substring(slash + 1));
}

File _partFile(File dest, int index) => File('${dest.path}.part$index');

File _metaFile(File dest) => File('${dest.path}.meta');

Future<void> _reconcileParts({
  required File dest,
  required File meta,
  required String url,
  required RemoteFileInfo info,
  required int chunkCount,
}) async {
  Map<String, dynamic>? saved;
  if (meta.existsSync()) {
    try {
      saved = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      saved = null;
    }
  }
  final same = saved != null &&
      saved['url'] == url &&
      saved['length'] == info.contentLength &&
      saved['chunks'] == chunkCount &&
      (info.etag == null || saved['etag'] == info.etag);
  if (!same) {
    for (var i = 0; i < math.max(chunkCount, 16); i++) {
      final part = _partFile(dest, i);
      if (part.existsSync()) {
        try {
          await part.delete();
        } catch (_) {}
      }
    }
  }
  await meta.writeAsString(jsonEncode({
    'url': url,
    'etag': info.etag,
    'length': info.contentLength,
    'chunks': chunkCount,
  }));
}

Future<void> _downloadChunk({
  required HttpClient client,
  required Uri uri,
  required File partFile,
  required int start,
  required int endInclusive,
  required String? token,
  required void Function(int have) onHave,
  required bool Function() isCancelled,
}) async {
  final expected = endInclusive - start + 1;
  var have = partFile.existsSync() ? partFile.lengthSync() : 0;
  if (have > expected) {
    await partFile.delete();
    have = 0;
  }
  onHave(have);
  if (have == expected) return;

  var attempt = 0;
  const maxAttempts = 5;
  while (have < expected) {
    if (isCancelled()) throw const ChunkedDownloadCancelled();
    try {
      final from = start + have;
      final req = await client.getUrl(uri);
      _applyHeaders(req, token: token);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$endInclusive');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 206) {
        await res.drain<void>();
        throw HttpException(
          'chunk $start-$endInclusive expected 206, got ${res.statusCode}',
          uri: uri,
        );
      }
      final sink = partFile.openWrite(mode: FileMode.append);
      try {
        await for (final data in res) {
          if (isCancelled()) {
            throw const ChunkedDownloadCancelled();
          }
          sink.add(data);
          have += data.length;
          if (have > expected) {
            throw StateError(
              'chunk $start-$endInclusive wrote $have, expected $expected',
            );
          }
          onHave(have);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      attempt = 0;
    } catch (e) {
      if (e is ChunkedDownloadCancelled) rethrow;
      attempt += 1;
      have = partFile.existsSync() ? partFile.lengthSync() : 0;
      onHave(have);
      if (attempt >= maxAttempts) rethrow;
      final wait = Duration(seconds: 1 << (attempt - 1).clamp(0, 4));
      Log.w(_tag, 'chunk $start-$endInclusive retry $attempt/$maxAttempts: $e');
      await Future<void>.delayed(wait);
    }
  }
}

Future<void> _assemble(File dest, int chunkCount, int expected) async {
  final tmp = File('${dest.path}.assembling');
  if (tmp.existsSync()) await tmp.delete();
  final out = tmp.openWrite();
  try {
    for (var i = 0; i < chunkCount; i++) {
      final part = _partFile(dest, i);
      if (!part.existsSync()) {
        throw StateError('missing chunk ${dest.path}.part$i');
      }
      await out.addStream(part.openRead());
    }
  } finally {
    await out.flush();
    await out.close();
  }
  final n = tmp.lengthSync();
  if (n != expected) {
    await tmp.delete();
    throw StateError('assembled $n bytes, expected $expected');
  }
  if (dest.existsSync()) await dest.delete();
  await tmp.rename(dest.path);
  for (var i = 0; i < chunkCount; i++) {
    try {
      await _partFile(dest, i).delete();
    } catch (_) {}
  }
  Log.i(_tag, 'assembled ${dest.path} ($n bytes)');
}
