import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../manifest/manifest_models.dart';
import '../stage/asset_repository.dart';
import 'character_cache_index.dart';
import 'character_download_manager.dart';
import 'character_integrity_verifier.dart';
import 'character_manifest_repository.dart';
import 'vault_models.dart';

typedef VaultRootProvider = Future<Directory> Function();

class CharacterCachePolicy {
  const CharacterCachePolicy({this.maxBytes = 1024 * 1024 * 1024});
  final int maxBytes;
}

/// Application-owned, manifest-driven media vault. It is also the only
/// repository handed to the Character Engine and VideoStage.
class CharacterVault extends ChangeNotifier
    implements
        CharacterAssetRepository,
        CharacterAssetLifecycle,
        CharacterAssetAvailability {
  CharacterVault({
    required CharacterManifest seedManifest,
    required this.config,
    required this.rootProvider,
    required this.manifestTransport,
    required this.mediaTransport,
    this.cachePolicy = const CharacterCachePolicy(),
    this.integrityVerifier = const CharacterIntegrityVerifier(),
    this.now = DateTime.now,
    this.autoDownloadStartup = true,
  }) : _manifest = seedManifest,
       _snapshot = VaultSnapshot(
         status: CharacterVaultStatus.notDownloaded,
         downloadedCount: 0,
         totalCount: seedManifest.assets.length,
         usedBytes: 0,
         manifestVersion: seedManifest.manifestVersion,
         completedInBatch: 0,
         batchTotal: 0,
       );

  final CharacterMediaConfig config;
  final VaultRootProvider rootProvider;
  final CharacterManifestTransport manifestTransport;
  final CharacterMediaTransport mediaTransport;
  final CharacterCachePolicy cachePolicy;
  final CharacterIntegrityVerifier integrityVerifier;
  final DateTime Function() now;
  final bool autoDownloadStartup;

  late Directory _root;
  late CharacterCacheIndex _index;
  late CharacterDownloadManager _downloads;
  CharacterManifest _manifest;
  VaultSnapshot _snapshot;
  Future<void>? _initialization;
  Future<void>? _activeBatch;
  bool _storageReady = false;
  final Map<String, int> _protected = {};
  final Set<String> _preloading = {};

  CharacterManifest get manifest => _manifest;
  VaultSnapshot get snapshot => _snapshot;
  Map<String, VaultIndexEntry> get entries =>
      !_storageReady ? const {} : _index.entries;

  Future<void> bootstrap() {
    final active = _initialization;
    if (active != null) return active;
    final completer = Completer<void>();
    _initialization = completer.future;
    () async {
      try {
        await _bootstrap();
        completer.complete();
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  Future<void> _bootstrap() async {
    _setStatus(CharacterVaultStatus.loadingManifest);
    try {
      _root = await rootProvider();
      await _root.create(recursive: true);
      _index = CharacterCacheIndex(_root);
      await _index.load();
      _storageReady = true;
      _downloads = CharacterDownloadManager(
        transport: mediaTransport,
        verifier: integrityVerifier,
      );
      final manifests = CharacterManifestRepository(
        localFile: File('${_root.path}${Platform.pathSeparator}manifest.json'),
        seedManifest: _manifest,
        transport: manifestTransport,
      );
      final sync = await manifests.synchronize(config.remoteManifestUri);
      _manifest = sync.manifest;
      await _reconcileIndex();
      final hasUpdates = _index.entries.values.any(
        (entry) =>
            _manifest.byId[entry.assetId]?.sha256 != entry.sha256 ||
            entry.status != VaultAssetStatus.ready,
      );
      final ready = downloadedCount;
      if (sync.remoteError != null) {
        _updateSnapshot(
          status: ready > 0
              ? CharacterVaultStatus.offline
              : CharacterVaultStatus.notDownloaded,
          message: 'Remote media unavailable; using last-known-good manifest.',
        );
      } else if (sync.changed && hasUpdates) {
        _updateSnapshot(status: CharacterVaultStatus.updateAvailable);
      } else {
        _updateSnapshot(
          status: ready > 0
              ? CharacterVaultStatus.ready
              : CharacterVaultStatus.notDownloaded,
        );
      }
      if (config.isConfigured && autoDownloadStartup) {
        unawaited(downloadStartupPack());
      }
    } on Object catch (error) {
      _updateSnapshot(
        status: CharacterVaultStatus.storageError,
        message: error.toString(),
      );
    }
  }

  int get downloadedCount => !_storageReady
      ? 0
      : _index.entries.values
            .where((entry) => entry.status == VaultAssetStatus.ready)
            .length;

  int get usedBytes => !_storageReady
      ? 0
      : _index.entries.values
            .where((entry) => entry.status == VaultAssetStatus.ready)
            .fold(0, (sum, entry) => sum + entry.fileSize);

  bool isReady(String assetId) =>
      _storageReady && _index[assetId]?.status == VaultAssetStatus.ready;

  VaultAssetStatus statusFor(String assetId) => !_storageReady
      ? VaultAssetStatus.absent
      : _index[assetId]?.status ?? VaultAssetStatus.absent;

  List<CharacterAsset> get startupPack {
    const desired = [
      CoreState.idle,
      CoreState.talking,
      CoreState.thinking,
      CoreState.happy,
      CoreState.listening,
      CoreState.shy,
    ];
    final result = <CharacterAsset>[];
    for (final state in desired) {
      final candidate = _manifest.assets.where(
        (asset) =>
            !asset.excludedByDefault &&
            asset.allowedModes.contains(StageContext.daily) &&
            asset.supportsState(state) &&
            !result.contains(asset),
      );
      if (candidate.isNotEmpty) result.add(candidate.first);
    }
    return List.unmodifiable(result);
  }

  List<CharacterAsset> get dailyPack => _manifest.assets
      .where(
        (asset) =>
            !asset.excludedByDefault &&
            (asset.allowedModes.contains(StageContext.daily) ||
                asset.allowedModes.contains(StageContext.assistant)),
      )
      .toList(growable: false);

  Future<void> downloadStartupPack() async {
    await bootstrap();
    await downloadAssets(
      startupPack,
      scope: const VaultDownloadScope(mode: StageContext.daily),
      pin: true,
    );
  }

  Future<void> downloadDailyPack() async {
    await bootstrap();
    await downloadAssets(
      dailyPack,
      scope: const VaultDownloadScope(
        mode: StageContext.daily,
        ownerInitiated: true,
      ),
      pin: false,
    );
  }

  Future<void> downloadRelationshipPack() async {
    await bootstrap();
    final assets = _manifest.assets
        .where(
          (asset) =>
              !asset.excludedByDefault &&
              asset.allowedModes.contains(StageContext.relationship),
        )
        .toList(growable: false);
    await downloadAssets(
      assets,
      scope: const VaultDownloadScope(
        mode: StageContext.relationship,
        ownerInitiated: true,
      ),
      pin: false,
    );
  }

  Future<void> downloadAssets(
    List<CharacterAsset> assets, {
    required VaultDownloadScope scope,
    required bool pin,
  }) async {
    await bootstrap();
    if (!config.isConfigured || _activeBatch != null) return;
    final jobs = <DownloadJob>[];
    for (final asset in assets) {
      if (!_allowed(asset, scope) || isReady(asset.assetId)) continue;
      final uri = config.assetUri(asset);
      if (uri == null) continue;
      final directory = Directory(
        '${_root.path}${Platform.pathSeparator}assets',
      );
      final destination = File(
        '${directory.path}${Platform.pathSeparator}${asset.assetId}.mp4',
      );
      jobs.add(
        DownloadJob(
          asset: asset,
          uri: uri,
          partial: File('${destination.path}.partial'),
          destination: destination,
        ),
      );
    }
    if (jobs.isEmpty) return;
    final task = _runBatch(jobs, pin: pin);
    _activeBatch = task;
    try {
      await task;
    } finally {
      _activeBatch = null;
    }
  }

  Future<void> _runBatch(List<DownloadJob> jobs, {required bool pin}) async {
    var completed = 0;
    _updateSnapshot(
      status: CharacterVaultStatus.downloading,
      completedInBatch: 0,
      batchTotal: jobs.length,
    );
    await _downloads.downloadAll(jobs, (
      asset,
      outcome,
      attempts,
      message,
    ) async {
      final existing = _index[asset.assetId];
      final timestamp = now().toUtc();
      switch (outcome) {
        case DownloadOutcome.completed:
          completed++;
          await _index.put(
            VaultIndexEntry(
              assetId: asset.assetId,
              localPath: 'assets/${asset.assetId}.mp4',
              manifestVersion: _manifest.manifestVersion,
              sha256: asset.sha256,
              fileSize: asset.bytes,
              downloadedAt: timestamp,
              lastUsedAt: timestamp,
              status: VaultAssetStatus.ready,
              failureCount: 0,
              pinned: pin || startupPack.contains(asset),
            ),
          );
        case DownloadOutcome.paused:
          await _putFailure(asset, VaultAssetStatus.paused, attempts, existing);
        case DownloadOutcome.cancelled:
          await _putFailure(asset, VaultAssetStatus.absent, attempts, existing);
        case DownloadOutcome.failed:
          await _putFailure(asset, VaultAssetStatus.failed, attempts, existing);
        case DownloadOutcome.integrityError:
          await _putFailure(
            asset,
            VaultAssetStatus.integrityError,
            attempts,
            existing,
          );
      }
      _updateSnapshot(
        status: outcome == DownloadOutcome.integrityError
            ? CharacterVaultStatus.integrityError
            : _downloads.isPaused
            ? CharacterVaultStatus.paused
            : CharacterVaultStatus.downloading,
        completedInBatch: completed,
        batchTotal: jobs.length,
        message: message,
      );
    });
    await evictIfNeeded();
    final integrityFailure = jobs.any(
      (job) => statusFor(job.asset.assetId) == VaultAssetStatus.integrityError,
    );
    _updateSnapshot(
      status: integrityFailure
          ? CharacterVaultStatus.integrityError
          : downloadedCount > 0
          ? CharacterVaultStatus.ready
          : CharacterVaultStatus.notDownloaded,
      completedInBatch: completed,
      batchTotal: jobs.length,
    );
  }

  Future<void> _putFailure(
    CharacterAsset asset,
    VaultAssetStatus status,
    int attempts,
    VaultIndexEntry? existing,
  ) async {
    final timestamp = now().toUtc();
    await _index.put(
      VaultIndexEntry(
        assetId: asset.assetId,
        localPath: 'assets/${asset.assetId}.mp4',
        manifestVersion: _manifest.manifestVersion,
        sha256: asset.sha256,
        fileSize: existing?.fileSize ?? 0,
        downloadedAt: existing?.downloadedAt ?? timestamp,
        lastUsedAt: existing?.lastUsedAt ?? timestamp,
        status: status,
        failureCount: (existing?.failureCount ?? 0) + attempts,
        pinned: existing?.pinned ?? false,
      ),
    );
  }

  bool _allowed(CharacterAsset asset, VaultDownloadScope scope) {
    if (!asset.allowedModes.contains(scope.mode)) return false;
    if (asset.excludedByDefault &&
        !(scope.ownerInitiated && scope.allowExcluded)) {
      return false;
    }
    if (scope.mode == StageContext.relationship && !scope.ownerInitiated) {
      return false;
    }
    if (scope.mode == StageContext.private &&
        (!scope.ownerInitiated || !scope.privateSessionActive)) {
      return false;
    }
    return true;
  }

  void pause() {
    if (_initialization == null) return;
    _downloads.pause();
    _updateSnapshot(status: CharacterVaultStatus.paused);
  }

  void resume() {
    if (_initialization == null) return;
    _downloads.resume();
    _updateSnapshot(status: CharacterVaultStatus.downloading);
  }

  Future<void> clearNonEssentialCache() async {
    await bootstrap();
    final removable = _index.entries.values
        .where(
          (entry) =>
              entry.status == VaultAssetStatus.ready &&
              !entry.pinned &&
              !_protected.containsKey(entry.assetId) &&
              !_preloading.contains(entry.assetId),
        )
        .toList();
    for (final entry in removable) {
      await _removeEntry(entry);
    }
    _updateSnapshot(
      status: downloadedCount > 0
          ? CharacterVaultStatus.ready
          : CharacterVaultStatus.notDownloaded,
    );
  }

  Future<void> evictIfNeeded() async {
    if (usedBytes <= cachePolicy.maxBytes) return;
    final candidates =
        _index.entries.values
            .where(
              (entry) =>
                  entry.status == VaultAssetStatus.ready &&
                  !entry.pinned &&
                  !_protected.containsKey(entry.assetId) &&
                  !_preloading.contains(entry.assetId),
            )
            .toList()
          ..sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));
    for (final entry in candidates) {
      if (usedBytes <= cachePolicy.maxBytes) break;
      await _removeEntry(entry);
    }
  }

  Future<void> _removeEntry(VaultIndexEntry entry) async {
    final file = _safeLocalFile(entry.localPath);
    if (file != null && await file.exists()) await file.delete();
    await _index.remove(entry.assetId);
  }

  Future<void> _reconcileIndex() async {
    for (final entry in _index.entries.values.toList()) {
      final asset = _manifest.byId[entry.assetId];
      final file = _safeLocalFile(entry.localPath);
      if (asset == null ||
          file == null ||
          asset.sha256 != entry.sha256 ||
          entry.status != VaultAssetStatus.ready ||
          !await file.exists()) {
        continue;
      }
      final verified = await integrityVerifier.verify(asset, file);
      if (!verified.valid) {
        await file.rename('${file.path}.bad-${now().millisecondsSinceEpoch}');
        await _index.put(
          entry.copyWith(status: VaultAssetStatus.integrityError),
        );
      }
    }
  }

  @override
  Future<LocalCharacterMedia?> resolve(CharacterAsset asset) async {
    await bootstrap();
    final entry = _index[asset.assetId];
    if (entry == null ||
        entry.status != VaultAssetStatus.ready ||
        entry.sha256 != asset.sha256) {
      return null;
    }
    final file = _safeLocalFile(entry.localPath);
    if (file == null || !await file.exists()) return null;
    await _index.put(entry.copyWith(lastUsedAt: now().toUtc()));
    return LocalCharacterMedia(video: file);
  }

  @override
  Future<File?> resolvePoster(CharacterAsset asset) async => null;

  @override
  Future<File?> resolvePosterBlur(CharacterAsset asset) async => null;

  @override
  Future<Set<String>> readyVideoIds(CharacterManifest manifest) async {
    await bootstrap();
    return manifest.assets
        .where((asset) => isReady(asset.assetId))
        .map((asset) => asset.assetId)
        .toSet();
  }

  @override
  Future<Set<String>> readyPosterIds(CharacterManifest manifest) async =>
      const {};

  File? _safeLocalFile(String relative) {
    if (relative.contains('\\') ||
        relative.contains(':') ||
        relative.startsWith('/') ||
        relative.split('/').any((part) => part.isEmpty || part == '..')) {
      return null;
    }
    final rootPath = _root.absolute.path.replaceAll('\\', '/');
    final file = File(
      '${_root.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    final path = file.absolute.path.replaceAll('\\', '/');
    return path.startsWith('$rootPath/') ? file : null;
  }

  @override
  void protect(String assetId) {
    _protected[assetId] = (_protected[assetId] ?? 0) + 1;
  }

  @override
  void release(String assetId) {
    final count = _protected[assetId];
    if (count == null || count <= 1) {
      _protected.remove(assetId);
    } else {
      _protected[assetId] = count - 1;
    }
  }

  void markPreloading(String assetId, bool value) {
    value ? _preloading.add(assetId) : _preloading.remove(assetId);
  }

  void _setStatus(CharacterVaultStatus status) =>
      _updateSnapshot(status: status);

  void _updateSnapshot({
    required CharacterVaultStatus status,
    int? completedInBatch,
    int? batchTotal,
    String? message,
  }) {
    _snapshot = VaultSnapshot(
      status: status,
      downloadedCount: downloadedCount,
      totalCount: _manifest.assets.length,
      usedBytes: usedBytes,
      manifestVersion: _manifest.manifestVersion,
      completedInBatch: completedInBatch ?? _snapshot.completedInBatch,
      batchTotal: batchTotal ?? _snapshot.batchTotal,
      message: message,
    );
    notifyListeners();
  }
}
