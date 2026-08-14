/// Audio framing / reassembly layer on top of the BLE protocol (M1).
///
/// KEEP THIS FILE DEPENDENCY-FREE PLAIN DART (dart:typed_data only) — the
/// ESP32 firmware ports both halves of this: the chunker for its mic path,
/// the reassembler for its speaker path.
///
/// AUDIO PLANE — PROVISIONAL until the M1 bandwidth gate passes
/// (see ble_protocol.dart).
///
/// Two classes:
///
/// - [UtteranceChunker] (sender): PCM stream in, [AudioChunkMessage] frames
///   out, with block size derived from the negotiated MTU so every frame
///   fits a single notification / write-without-response.
/// - [UtteranceReassembler] (receiver): frames in — possibly with losses,
///   duplicates and reordering — decoded PCM out, in playback order, with
///   silence substituted for lost frames so timing is preserved.
///
/// Both sides maintain an FNV-1a checksum over the ADPCM payload bytes so a
/// human test can confirm byte-identical delivery by comparing two hex
/// values on two screens.
library;

import 'dart:typed_data';

import 'adpcm.dart';
import 'ble_protocol.dart';

// ---------------------------------------------------------------------------
// Checksum
// ---------------------------------------------------------------------------

/// Incremental FNV-1a 32-bit checksum. Cheap, dependency-free, and trivially
/// portable to C. Not cryptographic — this is a "same bytes?" check, not
/// integrity protection.
final class Fnv32 {
  static const int _offsetBasis = 0x811c9dc5;
  static const int _prime = 0x01000193;

  int _hash = _offsetBasis;

  /// Current checksum value.
  int get value => _hash;

  /// Current checksum as 8 hex digits, for on-screen comparison.
  String get hex => _hash.toRadixString(16).padLeft(8, '0');

  void add(Uint8List bytes) {
    var hash = _hash;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * _prime) & 0xFFFFFFFF;
    }
    _hash = hash;
  }

  void reset() => _hash = _offsetBasis;
}

// ---------------------------------------------------------------------------
// Sender: PCM -> framed ADPCM chunks sized to the negotiated MTU
// ---------------------------------------------------------------------------

/// Splits a PCM-16 stream into [AudioChunkMessage] frames whose encoded size
/// fits one BLE write/notification at the given ATT MTU.
///
/// Usage per utterance: construct (or [reset]), feed PCM with [addSamples]
/// (returns zero or more ready frames), then [finish] to flush the tail and
/// emit the end-of-utterance frame.
final class UtteranceChunker {
  UtteranceChunker({required int mtu, SequenceCounter? sequence})
      : samplesPerFrame = samplesPerFrameForMtu(mtu),
        _sequence = sequence ?? SequenceCounter();

  /// Largest even sample count whose ADPCM block + frame header fits in a
  /// single ATT write at [mtu], capped at the nominal
  /// [AudioWireFormat.samplesPerFrame]. Throws [ArgumentError] if even a
  /// 2-sample block cannot fit (protocol floor: MTU >= 12).
  static int samplesPerFrameForMtu(int mtu) {
    // ATT op header is 3 bytes; the rest is ours.
    final maxFramePayload = mtu - 3 - FrameHeader.byteLength;
    final maxSamples = (maxFramePayload - kAdpcmBlockHeaderBytes) * 2;
    if (maxSamples < 2) {
      throw ArgumentError('MTU $mtu cannot carry an audio frame');
    }
    final samples = maxSamples < AudioWireFormat.samplesPerFrame
        ? maxSamples & ~1
        : AudioWireFormat.samplesPerFrame;
    return samples;
  }

  /// Samples carried per frame at the MTU this chunker was built for.
  final int samplesPerFrame;

  final SequenceCounter _sequence;
  final ImaAdpcmEncoder _encoder = ImaAdpcmEncoder();
  final Fnv32 checksum = Fnv32();

  final List<int> _pending = [];
  bool _started = false;
  bool _finished = false;
  int _framesEmitted = 0;

  /// Frames emitted so far this utterance (including the end frame).
  int get framesEmitted => _framesEmitted;

  /// Feeds PCM samples in; returns every frame that became ready.
  List<AudioChunkMessage> addSamples(Int16List samples) {
    if (_finished) {
      throw StateError('chunker already finished; call reset()');
    }
    _pending.addAll(samples);
    final frames = <AudioChunkMessage>[];
    while (_pending.length >= samplesPerFrame) {
      final block = Int16List.fromList(
          _pending.sublist(0, samplesPerFrame));
      _pending.removeRange(0, samplesPerFrame);
      frames.add(_emit(block, isEnd: false));
    }
    return frames;
  }

  /// Flushes any tail samples (zero-padded to an even count) and emits the
  /// end-of-utterance frame. The end frame carries the tail if there is
  /// one, otherwise an empty payload — receivers must accept both.
  List<AudioChunkMessage> finish() {
    if (_finished) {
      throw StateError('chunker already finished; call reset()');
    }
    _finished = true;
    final frames = <AudioChunkMessage>[];
    if (_pending.isNotEmpty) {
      if (_pending.length.isOdd) _pending.add(0);
      frames.add(_emit(Int16List.fromList(_pending), isEnd: true));
      _pending.clear();
    } else {
      _framesEmitted += 1;
      frames.add(AudioChunkMessage(
        sequence: _sequence.next(),
        adpcmBlock: Uint8List(0),
        isUtteranceStart: !_started,
        isUtteranceEnd: true,
      ));
    }
    return frames;
  }

  AudioChunkMessage _emit(Int16List samples, {required bool isEnd}) {
    final block = _encoder.encodeBlock(samples);
    checksum.add(block);
    final frame = AudioChunkMessage(
      sequence: _sequence.next(),
      adpcmBlock: block,
      isUtteranceStart: !_started,
      isUtteranceEnd: isEnd,
    );
    _started = true;
    _framesEmitted += 1;
    return frame;
  }

  /// Rearms for a new utterance. The sequence counter keeps counting —
  /// per-characteristic sequence is continuous across utterances.
  void reset() {
    _pending.clear();
    _encoder.reset();
    checksum.reset();
    _started = false;
    _finished = false;
    _framesEmitted = 0;
  }
}

// ---------------------------------------------------------------------------
// Receiver: framed ADPCM chunks -> decoded PCM in playback order
// ---------------------------------------------------------------------------

/// Everything known about one completed utterance.
final class UtteranceResult {
  const UtteranceResult({
    required this.pcm,
    required this.framesReceived,
    required this.framesLost,
    required this.duplicateFrames,
    required this.staleFrames,
    required this.sawStart,
    required this.sawEnd,
    required this.checksum,
    required this.checksumHex,
  });

  /// Decoded audio, with silence substituted for lost frames.
  final Int16List pcm;

  /// Data-carrying frames accepted (excludes an empty end frame).
  final int framesReceived;

  /// Frames the sequence numbers say we never got.
  final int framesLost;

  /// Frames dropped because the same sequence number was already accepted.
  final int duplicateFrames;

  /// Frames dropped because they arrived after a later frame was accepted
  /// (reordering; the slot was already filled with silence or skipped).
  final int staleFrames;

  /// False if the utterance began without a start-of-utterance flag
  /// (i.e. the first frame was lost).
  final bool sawStart;

  /// False if the utterance was finalized without an end-of-utterance flag
  /// (a new utterance started, or the reassembler was reset).
  final bool sawEnd;

  /// FNV-1a over the accepted ADPCM payload bytes, in sequence order.
  /// Matches the sender's [UtteranceChunker.checksum] iff delivery was
  /// byte-identical and complete.
  final int checksum;
  final String checksumHex;

  Duration get audioDuration => Duration(
      milliseconds: pcm.length * 1000 ~/ AudioWireFormat.sampleRate);
}

/// Reassembles utterances from [AudioChunkMessage] frames.
///
/// Tolerates loss (silence substitution, counted), duplicates and stale
/// reordered frames (dropped, counted), sequence wrap-around, a lost first
/// frame (utterance still starts, [UtteranceResult.sawStart] is false) and
/// a lost end frame (finalized when the next utterance starts).
final class UtteranceReassembler {
  UtteranceReassembler({this.onPcm, this.onUtterance});

  /// Called with each decoded (or substituted-silence) PCM span, in
  /// playback order — feed this straight to a speaker for live monitoring.
  final void Function(Int16List pcm)? onPcm;

  /// Called when an utterance completes (end flag, or implicitly when a new
  /// one starts).
  final void Function(UtteranceResult result)? onUtterance;

  /// Sequence-number distance up to which a gap counts as loss; anything
  /// further back is a stale/duplicate frame from the past.
  static const int _forwardWindow = 0x8000;

  /// Cap on silence substituted per gap, in frames, so a corrupt sequence
  /// number cannot balloon memory. 50 frames = 1 s at the nominal rate.
  static const int _maxSilenceFramesPerGap = 50;

  bool _inUtterance = false;
  bool _sawStart = false;
  int _expectedSeq = 0;
  int _framesReceived = 0;
  int _framesLost = 0;
  int _duplicateFrames = 0;
  int _staleFrames = 0;
  int _lastBlockSamples = AudioWireFormat.samplesPerFrame;
  final BytesBuilder _pcmBytes = BytesBuilder(copy: true);
  final Fnv32 _checksum = Fnv32();

  bool get inUtterance => _inUtterance;

  /// Feeds one frame from the radio.
  void add(AudioChunkMessage message) {
    if (message.isUtteranceStart) {
      if (_inUtterance) {
        // Previous utterance never got its end frame — close it out.
        _finalize(sawEnd: false);
      }
      _begin(sawStart: true, firstSeq: message.sequence);
    } else if (!_inUtterance) {
      // Mid-utterance frame with no utterance open: the start frame was
      // lost. Begin anyway so audio still flows.
      _begin(sawStart: false, firstSeq: message.sequence);
    }

    final gap = (message.sequence - _expectedSeq) & FrameHeader.maxSequence;
    if (gap == 0) {
      _accept(message);
    } else if (gap < _forwardWindow) {
      // Forward jump: `gap` frames lost. Substitute silence to keep the
      // playback timeline honest, then accept this one.
      _framesLost += gap;
      final silenceFrames = gap > _maxSilenceFramesPerGap
          ? _maxSilenceFramesPerGap
          : gap;
      final silence = Int16List(silenceFrames * _lastBlockSamples);
      _emitPcm(silence);
      _accept(message);
    } else {
      // Behind the expected sequence: a duplicate or a late reordered
      // frame. Its slot has already been filled — drop it. An end flag is
      // still honored so a reordered end frame cannot wedge the utterance.
      if (gap == FrameHeader.maxSequence) {
        _duplicateFrames += 1;
      } else {
        _staleFrames += 1;
      }
      if (message.isUtteranceEnd) _finalize(sawEnd: true);
      return;
    }

    if (message.isUtteranceEnd) _finalize(sawEnd: true);
  }

  /// Abandons any utterance in progress (e.g. on disconnect), finalizing it
  /// with [UtteranceResult.sawEnd] false.
  void reset() {
    if (_inUtterance) _finalize(sawEnd: false);
  }

  void _begin({required bool sawStart, required int firstSeq}) {
    _inUtterance = true;
    _sawStart = sawStart;
    _expectedSeq = firstSeq;
    _framesReceived = 0;
    _framesLost = 0;
    _duplicateFrames = 0;
    _staleFrames = 0;
    _pcmBytes.clear();
    _checksum.reset();
  }

  void _accept(AudioChunkMessage message) {
    if (message.adpcmBlock.isNotEmpty) {
      final pcm = decodeAdpcmBlock(message.adpcmBlock);
      _lastBlockSamples = pcm.length;
      _checksum.add(message.adpcmBlock);
      _framesReceived += 1;
      _emitPcm(pcm);
    }
    _expectedSeq = (message.sequence + 1) & FrameHeader.maxSequence;
  }

  void _emitPcm(Int16List pcm) {
    if (pcm.isEmpty) return;
    _pcmBytes.add(pcm16SamplesToBytes(pcm));
    onPcm?.call(pcm);
  }

  void _finalize({required bool sawEnd}) {
    final result = UtteranceResult(
      pcm: pcm16BytesToSamples(_pcmBytes.takeBytes()),
      framesReceived: _framesReceived,
      framesLost: _framesLost,
      duplicateFrames: _duplicateFrames,
      staleFrames: _staleFrames,
      sawStart: _sawStart,
      sawEnd: sawEnd,
      checksum: _checksum.value,
      checksumHex: _checksum.hex,
    );
    _inUtterance = false;
    onUtterance?.call(result);
  }
}
