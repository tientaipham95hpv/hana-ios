import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';

import '../manifest/manifest_models.dart';
import 'character_integrity_verifier.dart';

class VaultCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadHttpResult {
  const DownloadHttpResult(this.statusCode, this.bytesWritten);
  final int statusCode;
  final int bytesWritten;
}

abstract interface class CharacterMediaTransport {
  Future<DownloadHttpResult> download(
    Uri uri,
    File partial, {
    required int startAt,
    required VaultCancelToken cancelToken,
  });
}

class DioCharacterMediaTransport implements CharacterMediaTransport {
  DioCharacterMediaTransport(this.dio);
  final Dio dio;

  @override
  Future<DownloadHttpResult> download(
    Uri uri,
    File partial, {
    required int startAt,
    required VaultCancelToken cancelToken,
  }) async {
    late final Response<ResponseBody> response;
    try {
      response = await dio.get<ResponseBody>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: startAt > 0 ? {'Range': 'bytes=$startAt-'} : null,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 600,
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw DownloadFailure(
        error.message ?? error.type.name,
        retryable: status == null || _retryableStatus(status),
      );
    }
    final status = response.statusCode ?? 0;
    if (status != 200 && status != 206) {
      throw DownloadFailure(
        'HTTP $status',
        retryable: _retryableStatus(status),
      );
    }
    var offset = startAt;
    if (startAt > 0 && status == 200) {
      offset = 0;
      await partial.writeAsBytes(const [], flush: true);
    }
    final sink = partial.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var written = 0;
    try {
      await for (final chunk in response.data!.stream) {
        if (cancelToken.isCancelled) {
          throw const DownloadInterrupted();
        }
        sink.add(chunk);
        written += chunk.length;
      }
      await sink.flush();
    } on DioException catch (error) {
      throw DownloadFailure(error.message ?? error.type.name, retryable: true);
    } finally {
      await sink.close();
    }
    return DownloadHttpResult(status, written);
  }

  static bool _retryableStatus(int status) =>
      status == 408 || status == 429 || status >= 500;
}

class DownloadFailure implements Exception {
  const DownloadFailure(this.message, {required this.retryable});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

class DownloadInterrupted implements Exception {
  const DownloadInterrupted();
}

class DownloadJob {
  const DownloadJob({
    required this.asset,
    required this.uri,
    required this.partial,
    required this.destination,
  });
  final CharacterAsset asset;
  final Uri uri;
  final File partial;
  final File destination;
}

enum DownloadOutcome { completed, paused, cancelled, failed, integrityError }

typedef DownloadEvent = Future<void> Function(
  CharacterAsset asset,
  DownloadOutcome outcome,
  int attempts,
  String? message,
);

class CharacterDownloadManager {
  CharacterDownloadManager({
    required this.transport,
    this.verifier = const CharacterIntegrityVerifier(),
    this.maxConcurrent = 2,
    this.maxAttempts = 3,
    this.sleep = _defaultSleep,
  });

  final CharacterMediaTransport transport;
  final CharacterIntegrityVerifier verifier;
  final int maxConcurrent;
  final int maxAttempts;
  final Future<void> Function(Duration) sleep;
  final Map<String, VaultCancelToken> _tokens = {};
  final Set<String> _discardOnCancel = {};
  final Set<String> _cancelledIds = {};
  bool _paused = false;
  Completer<void>? _resumeGate;

  bool get isPaused => _paused;

  void pause() {
    if (_paused) return;
    _paused = true;
    _resumeGate = Completer<void>();
    for (final token in _tokens.values) {
      token.cancel();
    }
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _resumeGate?.complete();
    _resumeGate = null;
  }

  Future<void> cancel(String assetId, {bool discardPartial = true}) async {
    _cancelledIds.add(assetId);
    if (discardPartial) _discardOnCancel.add(assetId);
    _tokens[assetId]?.cancel();
  }

  Future<void> downloadAll(
    List<DownloadJob> jobs,
    DownloadEvent onEvent,
  ) async {
    final queue = Queue<DownloadJob>.of(jobs);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (_paused) await _resumeGate?.future;
        if (queue.isEmpty) return;
        final job = queue.removeFirst();
        await _download(job, onEvent);
      }
    }

    if (jobs.isEmpty) return;
    final workers = maxConcurrent.clamp(1, jobs.length).toInt();
    await Future.wait(List.generate(workers, (_) => worker()));
  }

  Future<void> _download(DownloadJob job, DownloadEvent onEvent) async {
    if (_cancelledIds.remove(job.asset.assetId)) {
      if (_discardOnCancel.remove(job.asset.assetId) &&
          await job.partial.exists()) {
        await job.partial.delete();
      }
      await onEvent(job.asset, DownloadOutcome.cancelled, 0, null);
      return;
    }
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_paused) {
        await onEvent(job.asset, DownloadOutcome.paused, attempt - 1, null);
        await _resumeGate?.future;
      }
      final token = VaultCancelToken();
      _tokens[job.asset.assetId] = token;
      try {
        await job.partial.parent.create(recursive: true);
        var startAt = await job.partial.exists()
            ? await job.partial.length()
            : 0;
        if (startAt > 0) {
          final existing = await verifier.verify(job.asset, job.partial);
          if (existing.valid) {
            await _atomicComplete(job.partial, job.destination);
            await onEvent(job.asset, DownloadOutcome.completed, attempt, null);
            return;
          }
          if (startAt >= job.asset.bytes) {
            await _quarantine(job.partial);
            startAt = 0;
          }
        }
        await transport.download(
          job.uri,
          job.partial,
          startAt: startAt,
          cancelToken: token,
        );
        final verification = await verifier.verify(job.asset, job.partial);
        if (!verification.valid) {
          await _quarantine(job.partial);
          if (attempt < maxAttempts) {
            await sleep(Duration(milliseconds: 250 * (1 << (attempt - 1))));
            continue;
          }
          await onEvent(
            job.asset,
            DownloadOutcome.integrityError,
            attempt,
            verification.reason,
          );
          return;
        }
        await _atomicComplete(job.partial, job.destination);
        await onEvent(job.asset, DownloadOutcome.completed, attempt, null);
        return;
      } on DownloadInterrupted {
        if (_paused) {
          await onEvent(job.asset, DownloadOutcome.paused, attempt, null);
          attempt--;
          await _resumeGate?.future;
          continue;
        }
        if (_discardOnCancel.remove(job.asset.assetId) &&
            await job.partial.exists()) {
          await job.partial.delete();
        }
        _cancelledIds.remove(job.asset.assetId);
        await onEvent(job.asset, DownloadOutcome.cancelled, attempt, null);
        return;
      } on DownloadFailure catch (error) {
        if (!error.retryable || attempt == maxAttempts) {
          await onEvent(
            job.asset,
            DownloadOutcome.failed,
            attempt,
            error.message,
          );
          return;
        }
        await sleep(Duration(milliseconds: 250 * (1 << (attempt - 1))));
      } on Object catch (error) {
        await onEvent(
          job.asset,
          DownloadOutcome.failed,
          attempt,
          error.toString(),
        );
        return;
      } finally {
        _tokens.remove(job.asset.assetId);
      }
    }
  }

  Future<void> _atomicComplete(File partial, File destination) async {
    await destination.parent.create(recursive: true);
    final old = File('${destination.path}.old');
    if (await old.exists()) await old.delete();
    if (await destination.exists()) await destination.rename(old.path);
    try {
      await partial.rename(destination.path);
      if (await old.exists()) await old.delete();
    } on Object {
      if (!await destination.exists() && await old.exists()) {
        await old.rename(destination.path);
      }
      rethrow;
    }
  }

  Future<void> _quarantine(File file) async {
    if (!await file.exists()) return;
    await file.rename(
      '${file.path}.bad-${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  static Future<void> _defaultSleep(Duration duration) =>
      Future<void>.delayed(duration);
}
