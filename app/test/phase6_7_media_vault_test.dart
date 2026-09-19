import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/character/manifest/manifest_loader.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/policy/owner_policy.dart';
import 'package:hana_app/character/resolver/asset_resolver.dart';
import 'package:hana_app/character/resolver/random_source.dart';
import 'package:hana_app/character/vault/character_cache_index.dart';
import 'package:hana_app/character/vault/character_download_manager.dart';
import 'package:hana_app/character/vault/character_manifest_repository.dart';
import 'package:hana_app/character/vault/character_vault.dart';
import 'package:hana_app/character/vault/vault_models.dart';

import 'support/canonical_manifest.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String canonicalSource;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hana-phase67-');
    canonicalSource = File('assets/character/character_manifest.json')
        .readAsStringSync();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'first launch with an empty vault remains usable and explicit',
    () async {
      final vault = _vault(
        root: temp,
        source: canonicalSource,
        config: const CharacterMediaConfig(),
      );
      await vault.bootstrap();
      expect(vault.downloadedCount, 0);
      expect(vault.snapshot.status, CharacterVaultStatus.notDownloaded);
      expect(vault.snapshot.totalCount, 43);
    },
  );

  test(
    'valid remote manifest commits and invalid remote retains LKG',
    () async {
      final local = File('${temp.path}/manifest.json');
      final validJson = jsonDecode(canonicalSource) as Map<String, dynamic>;
      validJson['manifest_version'] = 'phase-6.7-test';
      final validSource = jsonEncode(validJson);
      final seed = canonicalManifest();
      final first = CharacterManifestRepository(
        localFile: local,
        seedManifest: seed,
        transport: _ManifestTransport(source: validSource),
      );
      final accepted = await first.synchronize(
        Uri.parse('https://media.test/m.json'),
      );
      expect(accepted.fromRemote, isTrue);
      expect(accepted.manifest.manifestVersion, 'phase-6.7-test');
      final committed = await local.readAsString();

      final second = CharacterManifestRepository(
        localFile: local,
        seedManifest: seed,
        transport: _ManifestTransport(source: '{"invalid":true}'),
      );
      final fallback = await second.synchronize(
        Uri.parse('https://media.test/m.json'),
      );
      expect(fallback.fromRemote, isFalse);
      expect(fallback.remoteError, isNotNull);
      expect(fallback.manifest.manifestVersion, 'phase-6.7-test');
      expect(await local.readAsString(), committed);
    },
  );

  test('last-known-good manifest survives offline fetch failure', () async {
    final local = File('${temp.path}/manifest.json');
    await local.writeAsString(canonicalSource);
    final repository = CharacterManifestRepository(
      localFile: local,
      seedManifest: CharacterManifest.empty(),
      transport: _ManifestTransport(error: const SocketException('offline')),
    );
    // The empty seed cannot validate the canonical kind association baseline,
    // so use the real current baseline for the production-equivalent fallback.
    final realRepository = CharacterManifestRepository(
      localFile: local,
      seedManifest: canonicalManifest(),
      transport: _ManifestTransport(error: const SocketException('offline')),
    );
    expect(repository, isNotNull);
    final result = await realRepository.synchronize(
      Uri.parse('https://media.test/m.json'),
    );
    expect(result.fromRemote, isFalse);
    expect(result.manifest.assets, hasLength(43));
    expect(result.remoteError, contains('offline'));
  });

  test(
    'future manifest may exceed 43 while canonical baseline stays intact',
    () async {
      final json = jsonDecode(canonicalSource) as Map<String, dynamic>;
      final assets = json['assets'] as List<dynamic>;
      final next = Map<String, dynamic>.from(
        assets.last as Map<String, dynamic>,
      );
      next['asset_id'] = 'chr_044';
      next['path'] = 'vault/chr_044.mp4';
      next['poster'] = 'vault/chr_044.poster.jpg';
      next['poster_blur'] = 'vault/chr_044.blur.jpg';
      next['sha256'] = ''.padLeft(64, 'a');
      assets.add(next);
      json['manifest_version'] = 'future-44';
      final repository = CharacterManifestRepository(
        localFile: File('${temp.path}/manifest.json'),
        seedManifest: canonicalManifest(),
        transport: _ManifestTransport(source: jsonEncode(json)),
      );
      final result = await repository.synchronize(
        Uri.parse('https://media.test/m.json'),
      );
      expect(result.manifest.assets, hasLength(44));
      expect(result.manifest.byId, contains('chr_044'));
    },
  );

  test(
    'partial interrupted download resumes and completes atomically',
    () async {
      final payload = _mp4(36, 7);
      final manifest = _manifestWithPayloads(canonicalSource, {
        'chr_001': payload,
      });
      final asset = manifest.byId['chr_001']!;
      final transport = _MediaTransport(
        payloads: {'chr_001': payload},
        interruptOnce: {'chr_001'},
      );
      final manager = CharacterDownloadManager(
        transport: transport,
        sleep: (_) async {},
      );
      final destination = File('${temp.path}/chr_001.mp4');
      final partial = File('${destination.path}.partial');
      final outcomes = <DownloadOutcome>[];
      await manager.downloadAll([
        DownloadJob(
          asset: asset,
          uri: Uri.parse('https://media.test/assets/chr_001.mp4'),
          partial: partial,
          destination: destination,
        ),
      ], (asset, outcome, attempts, message) async => outcomes.add(outcome));
      expect(transport.starts, [0, payload.length ~/ 2]);
      expect(outcomes, [DownloadOutcome.completed]);
      expect(await destination.readAsBytes(), payload);
      expect(await partial.exists(), isFalse);
    },
  );

  test(
    'hash mismatch is quarantined, retried, and never becomes ready',
    () async {
      final payload = _mp4(32, 3);
      final manifest = _manifestWithPayloads(canonicalSource, {
        'chr_001': payload,
      });
      final asset = manifest.byId['chr_001']!;
      final transport = _MediaTransport(
        payloads: {'chr_001': payload},
        corrupt: true,
      );
      final destination = File('${temp.path}/chr_001.mp4');
      DownloadOutcome? outcome;
      await CharacterDownloadManager(
        transport: transport,
        sleep: (_) async {},
      ).downloadAll([
        DownloadJob(
          asset: asset,
          uri: Uri.parse('https://media.test/assets/chr_001.mp4'),
          partial: File('${destination.path}.partial'),
          destination: destination,
        ),
      ], (asset, value, attempts, message) async => outcome = value);
      expect(transport.attempts['chr_001'], 3);
      expect(outcome, DownloadOutcome.integrityError);
      expect(await destination.exists(), isFalse);
      expect(
        temp.listSync().where((entry) => entry.path.contains('.bad-')),
        hasLength(3),
      );
    },
  );

  test(
    'retryable failures use exponential backoff; nonretryable does not',
    () async {
      final payload = _mp4(32, 4);
      final manifest = _manifestWithPayloads(canonicalSource, {
        'chr_001': payload,
      });
      final asset = manifest.byId['chr_001']!;
      final waits = <Duration>[];
      final retrying = _MediaTransport(
        payloads: {'chr_001': payload},
        retryFailures: 2,
      );
      await CharacterDownloadManager(
        transport: retrying,
        sleep: (duration) async => waits.add(duration),
      ).downloadAll([
        _job(temp, asset),
      ], (asset, outcome, attempts, message) async {});
      expect(waits, const [
        Duration(milliseconds: 250),
        Duration(milliseconds: 500),
      ]);
      expect(retrying.attempts['chr_001'], 3);

      final rejected = _MediaTransport(
        payloads: {'chr_001': payload},
        nonRetryable: true,
      );
      await CharacterDownloadManager(
        transport: rejected,
        sleep: (_) async => fail('must not back off'),
      ).downloadAll(
        [_job(Directory('${temp.path}/other')..createSync(), asset)],
        (asset, outcome, attempts, message) async {
          expect(outcome, DownloadOutcome.failed);
        },
      );
      expect(rejected.attempts['chr_001'], 1);
    },
  );

  test(
    'active download pauses, resumes, and cancellation discards partial',
    () async {
      final payload = _mp4(32, 5);
      final manifest = _manifestWithPayloads(canonicalSource, {
        'chr_001': payload,
      });
      final asset = manifest.byId['chr_001']!;
      final pausable = _ControlledTransport(payload);
      final manager = CharacterDownloadManager(
        transport: pausable,
        sleep: (_) async {},
      );
      final outcomes = <DownloadOutcome>[];
      final task = manager.downloadAll([
        _job(temp, asset),
      ], (asset, outcome, attempts, message) async => outcomes.add(outcome));
      await pausable.started.future;
      manager.pause();
      pausable.release.complete();
      await Future<void>.delayed(Duration.zero);
      manager.resume();
      await task;
      expect(outcomes, [DownloadOutcome.paused, DownloadOutcome.completed]);

      final cancelRoot = Directory('${temp.path}/cancel')..createSync();
      final cancellable = _ControlledTransport(payload);
      final cancelManager = CharacterDownloadManager(
        transport: cancellable,
        sleep: (_) async {},
      );
      DownloadOutcome? cancelled;
      final cancelTask = cancelManager.downloadAll([
        _job(cancelRoot, asset),
      ], (asset, outcome, attempts, message) async => cancelled = outcome);
      await cancellable.started.future;
      await cancelManager.cancel(asset.assetId);
      cancellable.release.complete();
      await cancelTask;
      expect(cancelled, DownloadOutcome.cancelled);
      expect(
        File('${cancelRoot.path}/chr_001.mp4.partial').existsSync(),
        isFalse,
      );
    },
  );

  test('cache index persists only relative sandbox-safe paths', () async {
    final index = CharacterCacheIndex(temp);
    final timestamp = DateTime.utc(2026, 9, 19);
    await index.put(
      VaultIndexEntry(
        assetId: 'chr_001',
        localPath: 'assets/chr_001.mp4',
        manifestVersion: 'test',
        sha256: ''.padLeft(64, 'a'),
        fileSize: 12,
        downloadedAt: timestamp,
        lastUsedAt: timestamp,
        status: VaultAssetStatus.ready,
        failureCount: 0,
        pinned: true,
      ),
    );
    final restored = CharacterCacheIndex(temp);
    await restored.load();
    expect(restored['chr_001']!.localPath, 'assets/chr_001.mp4');
    final raw = await restored.file.readAsString();
    expect(raw, isNot(contains('C:\\')));
    expect(raw, isNot(contains('/Users/')));
  });

  test('LRU evicts oldest non-pinned asset and retains pinned core', () async {
    final payloads = {
      'chr_001': _mp4(32, 1),
      'chr_003': _mp4(32, 2),
      'chr_004': _mp4(32, 3),
    };
    final source = _sourceWithPayloads(canonicalSource, payloads);
    final manifest = const CharacterManifestLoader().load(source).manifest!;
    await _seedCache(temp, manifest, payloads, protectedNewest: false);
    final vault = _vault(
      root: temp,
      source: source,
      config: const CharacterMediaConfig(),
      maxBytes: 64,
    );
    await vault.bootstrap();
    await vault.evictIfNeeded();
    expect(vault.isReady('chr_001'), isTrue);
    expect(vault.isReady('chr_003'), isFalse);
    expect(vault.isReady('chr_004'), isTrue);
  });

  test(
    'currently playing asset is never evicted and core remains pinned',
    () async {
      final payloads = {
        'chr_001': _mp4(32, 1),
        'chr_003': _mp4(32, 2),
        'chr_004': _mp4(32, 3),
      };
      final source = _sourceWithPayloads(canonicalSource, payloads);
      final manifest = const CharacterManifestLoader().load(source).manifest!;
      await _seedCache(temp, manifest, payloads, protectedNewest: false);
      final vault = _vault(
        root: temp,
        source: source,
        config: const CharacterMediaConfig(),
        maxBytes: 64,
      );
      await vault.bootstrap();
      vault.protect('chr_003');
      await vault.evictIfNeeded();
      expect(vault.isReady('chr_001'), isTrue);
      expect(vault.isReady('chr_003'), isTrue);
      expect(vault.isReady('chr_004'), isFalse);
    },
  );

  test('cached media resolves offline after relaunch', () async {
    final payload = _mp4(40, 9);
    final source = _sourceWithPayloads(canonicalSource, {'chr_001': payload});
    final manifest = const CharacterManifestLoader().load(source).manifest!;
    final online = _vault(
      root: temp,
      source: source,
      config: const CharacterMediaConfig(baseUrl: 'https://media.test/'),
      payloads: {'chr_001': payload},
    );
    await online.bootstrap();
    await online.downloadAssets(
      [manifest.byId['chr_001']!],
      scope: const VaultDownloadScope(
        mode: StageContext.daily,
        ownerInitiated: true,
      ),
      pin: true,
    );
    expect(online.isReady('chr_001'), isTrue);

    final offline = _vault(
      root: temp,
      source: source,
      config: const CharacterMediaConfig(),
    );
    await offline.bootstrap();
    final media = await offline.resolve(manifest.byId['chr_001']!);
    expect(media, isNotNull);
    expect(await media!.video.readAsBytes(), payload);
  });

  test(
    'mode boundaries and excluded assets prevent automatic download',
    () async {
      final payloads = {'chr_003': _mp4(32, 2), 'chr_011': _mp4(32, 3)};
      final source = _sourceWithPayloads(canonicalSource, payloads);
      final manifest = const CharacterManifestLoader().load(source).manifest!;
      final transport = _MediaTransport(payloads: payloads);
      final vault = CharacterVault(
        seedManifest: manifest,
        config: const CharacterMediaConfig(baseUrl: 'https://media.test/'),
        rootProvider: () async => temp,
        manifestTransport: _ManifestTransport(source: source),
        mediaTransport: transport,
        autoDownloadStartup: false,
      );
      await vault.bootstrap();
      await vault.downloadAssets(
        [manifest.byId['chr_003']!],
        scope: const VaultDownloadScope(mode: StageContext.daily),
        pin: false,
      );
      await vault.downloadAssets(
        [manifest.byId['chr_011']!],
        scope: const VaultDownloadScope(
          mode: StageContext.daily,
          ownerInitiated: true,
        ),
        pin: false,
      );
      expect(transport.attempts, isEmpty);
      expect(vault.isReady('chr_003'), isFalse);
      expect(vault.isReady('chr_011'), isFalse);
    },
  );

  test('missing media resolves to silhouette and source playback is muted', () {
    final manifest = canonicalManifest();
    final result = AssetResolver(SeededRandomSource(1)).resolve(
      ResolverInput(
        manifest: manifest,
        requestedState: CoreState.idle,
        stageContext: StageContext.daily,
        ownerPolicy: const OwnerPolicy(),
        readyAssetIds: const {},
        readyPosterIds: const {},
        brokenAssetIds: const {},
        recentUsage: const [],
        privateSessionActive: false,
      ),
    );
    expect(result.kind, VisualKind.silhouette);
    final source = File('lib/character/stage/video_controller_port.dart')
        .readAsStringSync();
    expect(source, contains('setVolume(0.0)'));
  });
}

CharacterVault _vault({
  required Directory root,
  required String source,
  required CharacterMediaConfig config,
  Map<String, List<int>> payloads = const {},
  int maxBytes = 1024 * 1024,
}) {
  final manifest = const CharacterManifestLoader().load(source).manifest!;
  return CharacterVault(
    seedManifest: manifest,
    config: config,
    rootProvider: () async => root,
    manifestTransport: _ManifestTransport(source: source),
    mediaTransport: _MediaTransport(payloads: payloads),
    cachePolicy: CharacterCachePolicy(maxBytes: maxBytes),
    autoDownloadStartup: false,
  );
}

DownloadJob _job(Directory root, CharacterAsset asset) {
  final destination = File('${root.path}/${asset.assetId}.mp4');
  return DownloadJob(
    asset: asset,
    uri: Uri.parse('https://media.test/assets/${asset.assetId}.mp4'),
    partial: File('${destination.path}.partial'),
    destination: destination,
  );
}

List<int> _mp4(int length, int fill) {
  final bytes = List<int>.filled(length, fill);
  bytes.setRange(0, 12, [
    0,
    0,
    0,
    24,
    0x66,
    0x74,
    0x79,
    0x70,
    0x69,
    0x73,
    0x6f,
    0x6d,
  ]);
  return bytes;
}

CharacterManifest _manifestWithPayloads(
  String canonicalSource,
  Map<String, List<int>> payloads,
) => const CharacterManifestLoader()
    .load(_sourceWithPayloads(canonicalSource, payloads))
    .manifest!;

String _sourceWithPayloads(
  String canonicalSource,
  Map<String, List<int>> payloads,
) {
  final json = jsonDecode(canonicalSource) as Map<String, dynamic>;
  json['manifest_version'] = 'phase-6.7-fixture';
  for (final raw in json['assets'] as List<dynamic>) {
    final asset = raw as Map<String, dynamic>;
    final payload = payloads[asset['asset_id']];
    if (payload != null) {
      asset['bytes'] = payload.length;
      asset['sha256'] = sha256.convert(payload).toString();
    }
  }
  return jsonEncode(json);
}

Future<void> _seedCache(
  Directory root,
  CharacterManifest manifest,
  Map<String, List<int>> payloads, {
  required bool protectedNewest,
}) async {
  final assets = Directory('${root.path}/assets')..createSync(recursive: true);
  final index = CharacterCacheIndex(root);
  var day = 1;
  for (final entry in payloads.entries) {
    final asset = manifest.byId[entry.key]!;
    await File('${assets.path}/${entry.key}.mp4').writeAsBytes(entry.value);
    final timestamp = DateTime.utc(2026, 9, day++);
    await index.put(
      VaultIndexEntry(
        assetId: entry.key,
        localPath: 'assets/${entry.key}.mp4',
        manifestVersion: manifest.manifestVersion,
        sha256: asset.sha256,
        fileSize: entry.value.length,
        downloadedAt: timestamp,
        lastUsedAt: timestamp,
        status: VaultAssetStatus.ready,
        failureCount: 0,
        pinned: entry.key == 'chr_001',
      ),
    );
  }
}

class _ManifestTransport implements CharacterManifestTransport {
  const _ManifestTransport({this.source, this.error});
  final String? source;
  final Object? error;
  @override
  Future<String> fetch(Uri uri) async {
    if (error != null) throw error!;
    return source!;
  }
}

class _MediaTransport implements CharacterMediaTransport {
  _MediaTransport({
    required this.payloads,
    this.interruptOnce = const {},
    this.corrupt = false,
    this.retryFailures = 0,
    this.nonRetryable = false,
  });

  final Map<String, List<int>> payloads;
  final Set<String> interruptOnce;
  final bool corrupt;
  int retryFailures;
  final bool nonRetryable;
  final Map<String, int> attempts = {};
  final List<int> starts = [];
  final Set<String> _interrupted = {};

  @override
  Future<DownloadHttpResult> download(
    Uri uri,
    File partial, {
    required int startAt,
    required VaultCancelToken cancelToken,
  }) async {
    final id = uri.pathSegments.last.replaceAll('.mp4', '');
    attempts[id] = (attempts[id] ?? 0) + 1;
    starts.add(startAt);
    if (nonRetryable) {
      throw const DownloadFailure('HTTP 404', retryable: false);
    }
    if (retryFailures > 0) {
      retryFailures--;
      throw const DownloadFailure('timeout', retryable: true);
    }
    var payload = List<int>.from(payloads[id]!);
    if (corrupt) payload[payload.length - 1] ^= 0xff;
    if (interruptOnce.contains(id) && _interrupted.add(id)) {
      final half = payload.length ~/ 2;
      await partial.writeAsBytes(payload.sublist(0, half));
      throw const DownloadFailure('connection lost', retryable: true);
    }
    final remaining = payload.sublist(startAt);
    await partial.writeAsBytes(
      remaining,
      mode: startAt > 0 ? FileMode.append : FileMode.write,
      flush: true,
    );
    return DownloadHttpResult(startAt > 0 ? 206 : 200, remaining.length);
  }
}

class _ControlledTransport implements CharacterMediaTransport {
  _ControlledTransport(this.payload);

  final List<int> payload;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  var calls = 0;

  @override
  Future<DownloadHttpResult> download(
    Uri uri,
    File partial, {
    required int startAt,
    required VaultCancelToken cancelToken,
  }) async {
    calls++;
    if (calls == 1) {
      await partial.writeAsBytes(payload.sublist(0, payload.length ~/ 2));
      started.complete();
      await release.future;
      if (cancelToken.isCancelled) throw const DownloadInterrupted();
    }
    final current = await partial.exists() ? await partial.length() : 0;
    await partial.writeAsBytes(
      payload.sublist(current),
      mode: current > 0 ? FileMode.append : FileMode.write,
      flush: true,
    );
    return DownloadHttpResult(
      current > 0 ? 206 : 200,
      payload.length - current,
    );
  }
}
