import '../manifest/manifest_models.dart';

enum VaultAssetStatus {
  absent,
  queued,
  downloading,
  paused,
  ready,
  failed,
  integrityError,
}

enum CharacterVaultStatus {
  notDownloaded,
  loadingManifest,
  downloading,
  paused,
  ready,
  offline,
  updateAvailable,
  storageError,
  integrityError,
}

class VaultIndexEntry {
  const VaultIndexEntry({
    required this.assetId,
    required this.localPath,
    required this.manifestVersion,
    required this.sha256,
    required this.fileSize,
    required this.downloadedAt,
    required this.lastUsedAt,
    required this.status,
    required this.failureCount,
    required this.pinned,
  });

  final String assetId;
  final String localPath;
  final String manifestVersion;
  final String sha256;
  final int fileSize;
  final DateTime downloadedAt;
  final DateTime lastUsedAt;
  final VaultAssetStatus status;
  final int failureCount;
  final bool pinned;

  VaultIndexEntry copyWith({
    String? manifestVersion,
    String? sha256,
    int? fileSize,
    DateTime? downloadedAt,
    DateTime? lastUsedAt,
    VaultAssetStatus? status,
    int? failureCount,
    bool? pinned,
  }) => VaultIndexEntry(
    assetId: assetId,
    localPath: localPath,
    manifestVersion: manifestVersion ?? this.manifestVersion,
    sha256: sha256 ?? this.sha256,
    fileSize: fileSize ?? this.fileSize,
    downloadedAt: downloadedAt ?? this.downloadedAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    status: status ?? this.status,
    failureCount: failureCount ?? this.failureCount,
    pinned: pinned ?? this.pinned,
  );

  Map<String, Object> toJson() => {
    'asset_id': assetId,
    'local_path': localPath,
    'manifest_version': manifestVersion,
    'sha256': sha256,
    'file_size': fileSize,
    'downloaded_at': downloadedAt.toUtc().toIso8601String(),
    'last_used_at': lastUsedAt.toUtc().toIso8601String(),
    'status': status.name,
    'failure_count': failureCount,
    'pinned': pinned,
  };

  factory VaultIndexEntry.fromJson(Map<String, dynamic> json) {
    final id = json['asset_id'];
    final path = json['local_path'];
    if (id is! String || !RegExp(r'^chr_\d{3,}$').hasMatch(id)) {
      throw const FormatException('invalid cache asset_id');
    }
    if (path is! String || path != 'assets/$id.mp4') {
      throw const FormatException('invalid cache local_path');
    }
    return VaultIndexEntry(
      assetId: id,
      localPath: path,
      manifestVersion: json['manifest_version'] as String,
      sha256: json['sha256'] as String,
      fileSize: json['file_size'] as int,
      downloadedAt: DateTime.parse(json['downloaded_at'] as String),
      lastUsedAt: DateTime.parse(json['last_used_at'] as String),
      status: VaultAssetStatus.values.byName(json['status'] as String),
      failureCount: json['failure_count'] as int,
      pinned: json['pinned'] as bool,
    );
  }
}

class VaultSnapshot {
  const VaultSnapshot({
    required this.status,
    required this.downloadedCount,
    required this.totalCount,
    required this.usedBytes,
    required this.manifestVersion,
    required this.completedInBatch,
    required this.batchTotal,
    this.message,
  });

  final CharacterVaultStatus status;
  final int downloadedCount;
  final int totalCount;
  final int usedBytes;
  final String manifestVersion;
  final int completedInBatch;
  final int batchTotal;
  final String? message;

  String get label => switch (status) {
    CharacterVaultStatus.notDownloaded => 'Not downloaded',
    CharacterVaultStatus.loadingManifest => 'Checking media',
    CharacterVaultStatus.downloading =>
      'Downloading $completedInBatch/$batchTotal',
    CharacterVaultStatus.paused => 'Paused',
    CharacterVaultStatus.ready => 'Ready',
    CharacterVaultStatus.offline => 'Offline',
    CharacterVaultStatus.updateAvailable => 'Update available',
    CharacterVaultStatus.storageError => 'Storage error',
    CharacterVaultStatus.integrityError => 'Integrity error',
  };
}

class VaultDownloadScope {
  const VaultDownloadScope({
    required this.mode,
    this.privateSessionActive = false,
    this.ownerInitiated = false,
    this.allowExcluded = false,
  });

  final StageContext mode;
  final bool privateSessionActive;
  final bool ownerInitiated;
  final bool allowExcluded;
}

class CharacterMediaConfig {
  const CharacterMediaConfig({this.baseUrl = '', this.manifestUrl = ''});

  factory CharacterMediaConfig.fromEnvironment() => const CharacterMediaConfig(
    baseUrl: String.fromEnvironment('HANA_MEDIA_BASE_URL'),
    manifestUrl: String.fromEnvironment('HANA_MEDIA_MANIFEST_URL'),
  );

  final String baseUrl;
  final String manifestUrl;

  bool get isConfigured => baseUrl.isNotEmpty || manifestUrl.isNotEmpty;

  Uri? get remoteManifestUri {
    if (manifestUrl.isNotEmpty) {
      final uri = Uri.tryParse(manifestUrl);
      return uri != null && (uri.scheme == 'https' || uri.scheme == 'http')
          ? uri
          : null;
    }
    final base = _baseUri;
    return base?.resolve('manifest/character_manifest.json');
  }

  Uri? assetUri(CharacterAsset asset) {
    final base = _baseUri ?? remoteManifestUri?.resolve('../');
    return base?.resolve('assets/${asset.assetId}.mp4');
  }

  Uri? get _baseUri {
    if (baseUrl.isEmpty) return null;
    final normalized = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.tryParse(normalized);
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http')
        ? uri
        : null;
  }
}
