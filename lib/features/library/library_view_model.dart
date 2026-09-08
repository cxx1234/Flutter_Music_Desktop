import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/database/database.dart';
import '../../core/database/song_sort_order.dart';
import '../../core/services/folder_watcher_service.dart';
import '../../core/services/library_scanner_service.dart';
import '../../core/services/player_service.dart';
import '../../core/services/service_locator.dart';
import '../../core/utils/logger.dart';
import '../../core/viewmodels/page_view_model.dart';

/// Possible states of the library scan.
enum LibraryScanState {
  /// No scan has been performed yet.
  idle,

  /// A scan is currently in progress.
  scanning,

  /// The last scan completed successfully.
  done,

  /// The last scan encountered errors.
  error,
}

/// ViewModel for the Library page.
///
/// Manages scan lifecycle, song list, and folder watching.
class LibraryViewModel extends PageViewModel {
  LibraryScanState _scanState = LibraryScanState.idle;

  /// 扫描进度独立通知（ValueNotifier）：进度更新只重建进度条区域，
  /// 不触发整页 setState（避免扫描期间反复重建歌曲大列表拖慢主线程）。
  final ValueNotifier<ScanProgress?> scanProgressNotifier = ValueNotifier(null);
  ScanResult? _scanResult;
  List<Song> _songs = [];
  String? _errorMessage;
  SongSortOrder _sortOrder = SongSortOrder.title;

  /// 扫描单飞守卫：startScan/forceScan/rescan/quickSync 共用，防并发双跑事务。
  bool _scanInProgress = false;

  /// 文件夹监听的订阅：外部文件增删（去抖批量 flush 后）实时刷新歌曲列表。
  StreamSubscription<FolderWatcherEvent>? _folderWatcherSub;

  LibraryScanState get scanState => _scanState;
  ScanProgress? get scanProgress => scanProgressNotifier.value;
  ScanResult? get scanResult => _scanResult;
  List<Song> get songs => _songs;
  String? get errorMessage => _errorMessage;
  SongSortOrder get sortOrder => _sortOrder;

  bool get isIdle => _scanState == LibraryScanState.idle;
  bool get isScanning => _scanState == LibraryScanState.scanning;
  bool get isDone => _scanState == LibraryScanState.done;
  bool get isError => _scanState == LibraryScanState.error;

  // ─── Player delegation ────────────────────────────────

  Song? get currentSong => ServiceLocator.player.currentSong;
  bool get isPlaying => ServiceLocator.player.isPlaying;
  PlayerRepeatMode get repeatMode => ServiceLocator.player.repeatMode;

  /// Play all songs starting from [index].
  Future<void> playSongFromList(int index) {
    return ServiceLocator.player.playFromList(_songs, startIndex: index);
  }

  /// Play a single [song].
  Future<void> playSong(Song song) {
    return ServiceLocator.player.playFromSong(song);
  }

  /// Play songs in [songs] starting at [index].
  ///
  /// 用于搜索结果等过滤列表，保证"下一首"队列语义限定在该列表内。
  Future<void> playSongsFromList(List<Song> songs, int startIndex) {
    return ServiceLocator.player.playFromList(songs, startIndex: startIndex);
  }

  final _scanner = LibraryScannerService();

  /// 本 ViewModel 是否已订阅播放器的轻量通知器。
  ///
  /// 用于保证「注册最多一次 / 注销彻底一次」。ChangeNotifier 的 addListener
  /// 不去重、removeListener 一次只移除一个匹配项;若 initialize() 被重复调用
  /// (initState / 轮询兜底 / didUpdateWidget 多个触发源)会残留指向已 dispose
  /// 实例的监听,播放时触发即抛 "used after being disposed"。
  bool _playerListenerAttached = false;

  /// 幂等注册:无论调用多少次,最多挂一份轻量通知器监听。
  ///
  /// 只订阅去重的 [PlayerService.currentSongNotifier] 与 [playingNotifier]
  /// (切歌/播放态翻转才触发),不订阅整个 PlayerService——后者随
  /// positionStream 每 ~200ms notify,会让整页(尤其保活后的 offstage 页)
  /// 跟着高频重建。
  void _attachPlayerListener() {
    if (_playerListenerAttached) return;
    ServiceLocator.player.currentSongNotifier.addListener(safeNotify);
    ServiceLocator.player.playingNotifier.addListener(safeNotify);
    _playerListenerAttached = true;
  }

  /// 注销注册:页面生命周期结束时调用,保证移除干净。
  void _detachPlayerListener() {
    if (!_playerListenerAttached) return;
    ServiceLocator.player.currentSongNotifier.removeListener(safeNotify);
    ServiceLocator.player.playingNotifier.removeListener(safeNotify);
    _playerListenerAttached = false;
  }

  /// 幂等订阅文件夹监听事件：外部文件增删去抖批量落库后，实时刷新歌曲列表与
  /// 播放队列（LibraryPage 保活常驻，靠它捕捉 watcher 驱动的变更）。
  void _attachFolderWatcherListener() {
    if (_folderWatcherSub != null) return;
    _folderWatcherSub = ServiceLocator.folderWatcher.events.listen(
      (_) => unawaited(_onFolderWatcherEvent()),
    );
  }

  void _detachFolderWatcherListener() {
    _folderWatcherSub?.cancel();
    _folderWatcherSub = null;
  }

  /// 外部文件变化已由 FolderWatcherService 落库：重载歌曲 + 同步播放队列。
  Future<void> _onFolderWatcherEvent() async {
    await _syncQueueWithLibrary();
    await _loadSongs();
    safeNotify();
  }

  // ─── Initialization ────────────────────────────────────

  /// Called when the Library page is first shown.
  ///
  /// Starts folder watchers and runs a quick consistency check.
  /// Resolves macOS security-scoped bookmarks first to restore sandbox
  /// file access across app restarts.
  Future<void> initialize() async {
    _attachPlayerListener();
    final folders = ServiceLocator.settings.musicFolders;
    if (folders.isNotEmpty) {
      // 沙箱权限恢复已在 ServiceLocator.initialize() 完成（与 UI 解耦，
      // 见 ServiceLocator._restoreSandboxAccess）。
      _startWatching(folders);
      // Quick check: scan without re-parsing existing files.
      // markMissing:false ensures we never falsely delete data even if
      // sandbox permissions happen to be unavailable.
      await _quickSync(folders);
    }
    _sortOrder = ServiceLocator.settings.songSortOrder;
    _attachFolderWatcherListener();
    await _loadSongs();
    safeNotify();
  }

  /// 重新加载歌曲列表（排序或收藏变化后调用）。
  Future<void> reloadSongs() async {
    await _loadSongs();
    safeNotify();
  }

  /// 切换排序方式并持久化到设置。
  Future<void> setSortOrder(SongSortOrder order) async {
    if (_sortOrder == order) return;
    _sortOrder = order;
    safeNotify();
    await ServiceLocator.settings.setSongSortOrder(order);
    await _loadSongs();
    safeNotify();
  }

  // ─── Scanning ──────────────────────────────────────────

  /// Starts a full scan of all configured music folders.
  Future<void> startScan() async {
    final folders = ServiceLocator.settings.musicFolders;
    if (folders.isEmpty) {
      // 诊断「点刷新完全没反应」：未配置音乐文件夹时静默返回。
      AppLogger.warning('Scan', 'startScan skipped: no music folders');
      return;
    }
    await _runScan(folders);
  }

  /// 强制刷新：忽略 mtime/大小变化检测，把全部已存在歌曲重新解析一遍。
  /// 用于文件没变但元数据/封面缓存可能已过期的情况（如封面路径变更后）。
  Future<void> forceScan() async {
    final folders = ServiceLocator.settings.musicFolders;
    if (folders.isEmpty) return;
    await _runScan(folders, force: true);
  }

  /// 仅 debug：模拟一次慢速扫描，驱动进度/结果 UI 便于调试界面。
  ///
  /// 真实扫描常在几十 ms 内完成，进度条与结果横幅一闪而过看不到。
  /// 已注释掉（2026-08-25）：调试扫描 UI 用完后禁用；需要时取消注释，
  /// 并在 library_page 刷新按钮恢复「长按 → simulateScan」即可。
  /*
  Future<void> simulateScan() async {
    if (!kDebugMode) return;
    _scanState = LibraryScanState.scanning;
    scanProgressNotifier.value = null;
    _scanResult = null;
    _errorMessage = null;
    safeNotify();

    const total = 8;
    for (var i = 0; i <= total; i++) {
      scanProgressNotifier.value = ScanProgress(
        processed: i,
        total: total,
        currentFile: i == 0 ? '' : '示例歌曲 $i.mp3',
        phase: i < 2 ? 'collecting' : 'parsing',
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    _scanResult = const ScanResult(
      added: 3,
      updated: 2,
      markedMissing: 0,
      skipped: 3,
      errors: 0,
      errorDetails: [],
    );
    _scanState = LibraryScanState.done;
    safeNotify();
  }
  */

  /// Re-scans a specific folder.
  Future<void> rescanFolder(String folderPath) async {
    await _runScan([folderPath]);
  }

  /// Removes a folder: stop watching → delete songs from DB → remove from settings.
  Future<void> removeFolder(String folderPath) async {
    ServiceLocator.folderWatcher.stopWatching(folderPath);
    // 清掉该目录下尚未 flush 的监听事件，避免随后误处理已删目录的事件。
    ServiceLocator.folderWatcher.discardPendingUnder(folderPath);
    await ServiceLocator.songRepo.removeFolder(folderPath);
    await ServiceLocator.settings.removeMusicFolder(folderPath);
    await _syncQueueWithLibrary();
    await _loadSongs();
    safeNotify();
  }

  // ─── Internal ──────────────────────────────────────────

  Future<void> _runScan(List<String> folders, {bool force = false}) async {
    // 单飞：扫描进行中时忽略新的扫描请求（UI 已隐藏刷新按钮，这是 VM 层兜底）。
    if (_scanInProgress) {
      AppLogger.warning('Scan', 'Scan already in progress; request ignored');
      return;
    }
    _scanInProgress = true;
    // 扫描期间暂停文件夹监听：事件缓冲，扫完 resumeAfterScan 批量处理，并跳过
    // 本次已扫描过的文件（与扫描集求差），避免并发写库与重复解析。
    ServiceLocator.folderWatcher.suspend();

    _scanState = LibraryScanState.scanning;
    scanProgressNotifier.value = null;
    _scanResult = null;
    _errorMessage = null;
    safeNotify();

    ScanResult? result;
    try {
      result = await _scanner.scanFolders(
        folders,
        updateExisting: true,
        force: force,
        onProgress: (progress) {
          // 进度走独立 notifier，不触发整页 setState（避免扫描期间
          // 反复重建歌曲大列表拖慢主线程 / 拖慢扫描）。
          scanProgressNotifier.value = progress;
        },
      );

      _scanResult = result;
      _scanState = result.errors > 0
          ? LibraryScanState.error
          : LibraryScanState.done;
      _startWatching(folders);
    } catch (e, s) {
      // 记录真实异常（此前静默吞掉 → 「一闪而过、无任何提示」）。
      AppLogger.error('Scan', 'Scan failed', e, s);
      _scanState = LibraryScanState.error;
      _errorMessage = e.toString();
    } finally {
      _scanInProgress = false;
      ServiceLocator.folderWatcher.resumeAfterScan(
        result?.parsedFiles ?? const <String>{},
      );
    }

    await _syncQueueWithLibrary();
    await _loadSongs();
    safeNotify();
  }

  /// 清除扫描结果横幅（扫描完成后 N 秒自动收起时调用）。
  ///
  /// 页面全部保活后 VM 常驻，结果横幅不再随"切换 tab 重建页面"被清掉，
  /// 需要 UI 主动清除，否则会一直挂在页面上。
  void clearScanResult() {
    if (_scanResult == null) return;
    _scanResult = null;
    _scanState = LibraryScanState.idle;
    safeNotify();
  }

  Future<void> _quickSync(List<String> folders) async {
    if (_scanInProgress) {
      AppLogger.warning('Scan', 'Quick sync skipped: a scan is running');
      return;
    }
    _scanInProgress = true;
    ServiceLocator.folderWatcher.suspend();
    ScanResult? result;
    try {
      result = await _scanner.scanFolders(folders, markMissing: false);
    } catch (e) {
      AppLogger.warning('Scan', 'Quick sync failed', e);
    } finally {
      _scanInProgress = false;
      ServiceLocator.folderWatcher.resumeAfterScan(
        result?.parsedFiles ?? const <String>{},
      );
    }
    await _syncQueueWithLibrary();
  }

  /// 移除音乐库中已不存在的歌曲，保持播放队列与库一致。
  Future<void> _syncQueueWithLibrary() async {
    final available = await ServiceLocator.database.getAllFilePaths();
    await ServiceLocator.player.pruneQueue(available.toSet());
  }

  Future<void> _loadSongs() async {
    _songs = await ServiceLocator.songRepo.getAvailableSongs(order: _sortOrder);
  }

  void _startWatching(List<String> folders) {
    ServiceLocator.folderWatcher.startWatchingAll(folders);
  }

  @override
  void dispose() {
    // 测试环境可能未初始化 ServiceLocator，需要判空。
    if (ServiceLocator.isReady) {
      _detachPlayerListener();
      _detachFolderWatcherListener();
    }
    scanProgressNotifier.dispose();
    super.dispose(); // 基类置 _disposed 并释放
  }
}
