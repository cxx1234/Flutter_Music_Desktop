import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../constants/audio_extensions.dart';
import '../utils/logger.dart';
import 'metadata_service.dart';
import 'song_repository.dart';

/// 待处理事件的最新类型：add/modify 归并为 upsert（入库置可用），remove 独立。
enum _PendingKind { upsert, remove }

/// 描述一次去抖批量处理后的文件系统变化（每窗口只发一条汇总事件）。
class FolderWatcherEvent {
  /// 本次新增/更新的文件数。
  final int addedOrUpdated;

  /// 本次移除（标记缺失）的文件数。
  final int removed;

  const FolderWatcherEvent({
    required this.addedOrUpdated,
    required this.removed,
  });

  String get description {
    final parts = <String>[
      if (addedOrUpdated > 0) '添加/更新 $addedOrUpdated',
      if (removed > 0) '移除 $removed',
    ];
    return parts.isEmpty ? '无变化' : parts.join('，');
  }
}

/// Watches configured music folders for file changes in real time.
///
/// Uses the `watcher` package (`dart:io`-based file system watcher).
/// File events are **debounced and batched**: rapid add/modify/remove events
/// accumulate for ~500ms, then flush as one batch — a single [parseAll] + one
/// upsert transaction for adds/mods, one [markMissingFiles] for removes — and
/// a single [FolderWatcherEvent] is emitted. During a scan ([suspend]) events
/// are buffered and processed after [resumeAfterScan], skipping files the scan
/// already parsed (avoid duplicate parse right after a scan).
class FolderWatcherService {
  final MetadataService _metadataService;
  final SongRepository _songRepository;

  final Map<String, StreamSubscription<WatchEvent>> _subscriptions = {};
  final _controller = StreamController<FolderWatcherEvent>.broadcast();

  /// 待处理事件：路径 → 最新类型。
  final Map<String, _PendingKind> _pending = {};
  Timer? _flushTimer;
  bool _suspended = false;
  bool _flushing = false;
  bool _disposed = false;
  static const _flushDelay = Duration(milliseconds: 500);

  /// [metadataService]/[songRepository] 可选注入，便于测试；默认走全局。
  FolderWatcherService({
    MetadataService? metadataService,
    SongRepository? songRepository,
  }) : _metadataService = metadataService ?? MetadataService(),
       _songRepository = songRepository ?? SongRepository();

  /// Stream of file-system events (one summary per flush).
  Stream<FolderWatcherEvent> get events => _controller.stream;

  /// Whether any folder is currently being watched.
  bool get isWatching => _subscriptions.isNotEmpty;

  /// Returns the list of currently watched folder paths.
  List<String> get watchedFolders => _subscriptions.keys.toList();

  /// 是否有待处理（尚未落库）的文件事件。
  bool get hasPending => _pending.isNotEmpty;

  /// Starts watching a single [folderPath].
  ///
  /// Ignores files that are not supported audio files.
  /// If the folder is already being watched, this is a no-op.
  void startWatching(String folderPath) {
    if (_subscriptions.containsKey(folderPath)) return;

    final watcher = DirectoryWatcher(folderPath);
    final sub = watcher.events.listen((event) {
      _handleEvent(event, folderPath);
    });

    _subscriptions[folderPath] = sub;
  }

  /// Starts watching all folders in [folderPaths].
  void startWatchingAll(Iterable<String> folderPaths) {
    for (final folder in folderPaths) {
      startWatching(folder);
    }
  }

  /// Stops watching a single [folderPath].
  void stopWatching(String folderPath) {
    final sub = _subscriptions.remove(folderPath);
    sub?.cancel();
  }

  /// Stops watching all folders.
  void stopAll() {
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  /// Disposes the service, stopping all watchers and closing the stream.
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    stopAll();
    _controller.close();
  }

  // ─── Event batching ───────────────────────────────────

  void _handleEvent(WatchEvent event, String folderPath) {
    _record(event.path, event.type);
  }

  /// 记录一条文件系统事件（去抖后批量处理）。供 watcher 回调与测试复用。
  @visibleForTesting
  void recordEvent(String filePath, ChangeType type) {
    _record(filePath, type);
  }

  void _record(String filePath, ChangeType type) {
    if (!isSupportedAudioExtension(filePath)) return;
    switch (type) {
      case ChangeType.ADD:
      case ChangeType.MODIFY:
        _pending[filePath] = _PendingKind.upsert;
      case ChangeType.REMOVE:
        _pending[filePath] = _PendingKind.remove;
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_disposed || _suspended) return;
    _flushTimer ??= Timer(_flushDelay, () {
      _flushTimer = null;
      unawaited(_flushPending());
    });
  }

  /// 暂停（扫描期间）：事件继续缓冲但不再落库；[resumeAfterScan] 后统一处理。
  void suspend() {
    _suspended = true;
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// 恢复监听（不跳过任何文件）。
  void resume() => _resume(skipUpserts: const {});

  /// 扫描完成后恢复：丢弃/跳过本次扫描已解析过文件的 upsert（与本次扫描集
  /// 求差），避免刚扫完立刻又被 watcher flush 重复解析；remove 不跳过。
  void resumeAfterScan(Set<String> scannedPaths) =>
      _resume(skipUpserts: scannedPaths);

  void _resume({required Set<String> skipUpserts}) {
    if (_disposed) return;
    _suspended = false;
    if (skipUpserts.isNotEmpty) {
      _pending.removeWhere(
        (path, kind) =>
            kind == _PendingKind.upsert && skipUpserts.contains(path),
      );
    }
    if (_pending.isNotEmpty) _scheduleFlush();
  }

  /// 丢弃某文件夹（及子目录）下所有待处理事件（移除该文件夹前调用）。
  void discardPendingUnder(String folderPath) {
    final root = p.normalize(folderPath);
    _pending.removeWhere((path, _) {
      if (path == root) return true;
      return path.startsWith('$root/');
    });
  }

  /// 立即落库所有待处理事件（测试用；内部定时 flush 也走 [_flushPending]）。
  @visibleForTesting
  Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flushPending();
  }

  Future<void> _flushPending() async {
    if (_disposed || _suspended || _flushing) return;
    _flushing = true;
    try {
      if (_pending.isEmpty) return;
      final pending = Map<String, _PendingKind>.from(_pending);
      _pending.clear();

      final removes = <String>[];
      final upserts = <String>[];
      for (final entry in pending.entries) {
        if (entry.value == _PendingKind.remove) {
          removes.add(entry.key);
        } else {
          upserts.add(entry.key);
        }
      }

      if (removes.isNotEmpty) {
        await _songRepository.markMissingFiles(removes.toSet(), const {});
      }
      if (upserts.isNotEmpty) {
        final (scanned, failures) = await _metadataService.parseAll(upserts);
        if (failures.isNotEmpty) {
          AppLogger.warning(
            'FolderWatch',
            'Batch parse failed for ${failures.length} file(s)',
          );
        }
        if (scanned.isNotEmpty) {
          await _songRepository.insertOrUpdateFromScan(scanned);
        }
      }

      if (!_disposed && !_suspended) {
        _controller.add(
          FolderWatcherEvent(
            addedOrUpdated: upserts.length,
            removed: removes.length,
          ),
        );
      }
    } catch (e, s) {
      AppLogger.error('FolderWatch', 'Failed to flush folder events', e, s);
    } finally {
      _flushing = false;
      // 落库期间新到的（或本次未处理完的）事件重新排队。
      if (_pending.isNotEmpty && !_suspended && !_disposed) _scheduleFlush();
    }
  }
}
