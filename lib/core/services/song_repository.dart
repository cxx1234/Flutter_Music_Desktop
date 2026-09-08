import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../models/scanned_song.dart';
import '../database/database.dart';
import '../database/song_sort_order.dart';
import '../utils/logger.dart';
import '../utils/sort_key.dart';
import 'album_art_cache_service.dart';
import 'service_locator.dart';

/// Repository for song data access.
///
/// Wraps [AppDatabase] and provides higher-level operations
/// like batch upsert, file-state sync, and folder-scoped queries.
class SongRepository {
  final AppDatabase? _database;
  AppDatabase get _db => _database ?? ServiceLocator.database;
  final _artCache = AlbumArtCacheService();

  /// [database] is optional and used for testing; defaults to the app-wide
  /// [ServiceLocator.database].
  // ignore: prefer_initializing_formals (公开参数名 database，字段私有 _database)
  SongRepository({AppDatabase? database}) : _database = database;

  // ─── Song queries ──────────────────────────────────────

  Future<List<Song>> getAllSongs() => _db.getAllSongs();

  Future<List<Song>> getAvailableSongs({
    SongSortOrder order = SongSortOrder.title,
  }) => _db.getAvailableSongs(order: order);

  Stream<List<Song>> watchAllSongs() => _db.watchAllSongs();

  Future<List<Song>> getSongsByFolder(String folderPath) =>
      _db.getSongsByFolder(folderPath);

  Future<Song?> getSongByFilePath(String filePath) =>
      _db.getSongByFilePath(filePath);

  Future<Song?> getSongById(int id) => _db.getSongById(id);

  Future<int> getSongCount() => _db.getSongCount();

  // ─── Album queries ─────────────────────────────────────

  Future<List<Album>> getAllAlbums() => _db.getAllAlbums();

  Future<List<Album>> getAlbumsByIds(Iterable<int> ids) =>
      _db.getAlbumsByIds(ids);

  Stream<List<Album>> watchAllAlbums() => _db.watchAllAlbums();

  Future<Album?> getAlbumById(int id) => _db.getAlbumById(id);

  Future<List<Song>> getSongsByAlbum(int albumId) =>
      _db.getSongsByAlbum(albumId);

  Stream<List<Song>> watchSongsByAlbum(int albumId) =>
      _db.watchSongsByAlbum(albumId);

  // ─── Artist queries ────────────────────────────────────

  Future<List<Artist>> getAllArtists() => _db.getAllArtists();

  Stream<List<Artist>> watchAllArtists() => _db.watchAllArtists();

  Future<Artist?> getArtistById(int id) => _db.getArtistById(id);

  Future<List<Song>> getSongsByArtist(int artistId) =>
      _db.getSongsByArtist(artistId);

  Stream<List<Song>> watchSongsByArtist(int artistId) =>
      _db.watchSongsByArtist(artistId);

  /// 每个歌手的歌曲/专辑统计（浏览页计数用，避免加载全量歌曲）。
  Future<Map<int, ({int songCount, int albumCount})>> getArtistStats() =>
      _db.getArtistStats();

  // ─── Playlist queries ──────────────────────────────────

  Future<List<Playlist>> getAllPlaylists() => _db.getAllPlaylists();

  Stream<List<Playlist>> watchAllPlaylists() => _db.watchAllPlaylists();

  Future<Playlist?> getPlaylistById(int id) => _db.getPlaylistById(id);

  Future<int> insertPlaylist(PlaylistsCompanion entry) =>
      _db.insertPlaylist(entry);

  Future<bool> updatePlaylist(PlaylistsCompanion entry, int id) =>
      _db.updatePlaylist(entry, id);

  Future<void> deletePlaylist(int id) => _db.deletePlaylist(id);

  Future<List<Song>> getSongsInPlaylist(int playlistId, {int? limit}) =>
      _db.getSongsInPlaylist(playlistId, limit: limit);

  Future<void> addSongToPlaylist(int playlistId, int songId) =>
      _db.addSongToPlaylist(playlistId, songId);

  Future<int> addSongsToPlaylist(int playlistId, List<int> songIds) =>
      _db.addSongsToPlaylist(playlistId, songIds);

  Future<void> removeSongFromPlaylist(int playlistId, int songId) =>
      _db.removeSongFromPlaylist(playlistId, songId);

  Future<void> moveSongInPlaylist(int playlistId, int oldIndex, int newIndex) =>
      _db.moveSongInPlaylist(playlistId, oldIndex, newIndex);

  Future<List<Song>> getFavoriteSongs() => _db.getFavoriteSongs();

  Future<int> getFavoriteCount() => _db.getFavoriteCount();

  Future<int> toggleFavorite(int id) => _db.toggleFavorite(id);

  Future<Map<int, int>> getPlaylistSongCounts() => _db.getPlaylistSongCounts();

  // ─── Sort key backfill ────────────────────────────────

  /// 为 sort_key 为空的歌曲/专辑/歌手回填拼音/日文排序键。
  Future<void> backfillSortKeys() async {
    final songs = await _db.getSongsWithNullSortKey();
    for (final song in songs) {
      final key = buildSortKey(song.title);
      if (key.isNotEmpty) {
        await _db.updateSongSortKey(song.id, key);
      }
    }

    final albums = await _db.getAlbumsWithNullSortKey();
    for (final album in albums) {
      final key = buildSortKey(album.name);
      if (key.isNotEmpty) {
        await _db.updateAlbumSortKey(album.id, key);
      }
    }

    final artists = await _db.getArtistsWithNullSortKey();
    for (final artist in artists) {
      final key = buildSortKey(artist.name);
      if (key.isNotEmpty) {
        await _db.updateArtistSortKey(artist.id, key);
      }
    }
  }

  /// 若已有专辑的 albumArtist 为空且当前歌曲提供了专辑艺术家，则补写。
  Future<void> _fillAlbumArtistIfEmpty(Album album, ScannedSong song) async {
    final artist = song.albumArtist ?? song.artist;
    if (artist == null || artist.isEmpty) return;
    final current = album.albumArtist;
    if (current == null || current.isEmpty) {
      await _db.updateAlbum(
        AlbumsCompanion(albumArtist: Value(artist)),
        album.id,
      );
    }
  }

  /// 若已有专辑的 year 为空且当前歌曲提供了年份，则补写。
  Future<void> _fillYearIfEmpty(Album album, ScannedSong song) async {
    if (album.year != null || song.year == null) return;
    await _db.updateAlbum(AlbumsCompanion(year: Value(song.year)), album.id);
  }

  // ─── File paths (for sync) ─────────────────────────────

  /// Returns the set of all available file paths in the database.
  Future<Set<String>> getExistingFilePaths() async {
    final paths = await _db.getAllFilePaths();
    return paths.toSet();
  }

  /// 返回这些根目录（含子目录）下所有「可用」歌曲路径的并集。
  ///
  /// 供扫描 diff 使用：部分扫描（单文件夹重扫）只应在这几个根内做增删/标记
  /// 缺失，避免影响其它未扫描的文件夹（不再依赖 File.existsSync 启发式兜底）。
  Future<Set<String>> getExistingFilePathsUnder(
    Iterable<String> folderPaths,
  ) async {
    final result = <String>{};
    for (final root in folderPaths) {
      result.addAll(await _db.getFolderFilePaths(root));
    }
    return result;
  }

  /// Returns the set of available file paths under [folderPath].
  Future<Set<String>> getFolderFilePaths(String folderPath) async {
    final paths = await _db.getFolderFilePaths(folderPath);
    return paths.toSet();
  }

  /// Returns existing songs' file stamps (mtime + size) keyed by file path.
  ///
  /// 供扫描变化检测使用。
  Future<Map<String, ({int? lastModifiedMs, int? fileSize})>>
  getExistingFileStats() => _db.getExistingFileStats();

  // ─── Batch upsert with album/artist resolution ─────────

  /// Inserts or updates a list of scanned songs in a single transaction.
  ///
  /// For each song:
  /// 1. Looks up (or creates) the [Artist] record by name.
  /// 2. Looks up (or creates) the [Album] record by name + artist.
  /// 3. Deduplicates album art: the first song with embedded art for an album
  ///    saves it (keyed by album identity); subsequent songs reuse the cached
  ///    path stored on the album record.
  /// 4. Writes the song with [artistId], [albumId], and the album's art path.
  ///
  /// Uses [filePath]'s UNIQUE constraint to decide insert vs update.
  Future<int> insertOrUpdateFromScan(List<ScannedSong> scanned) async {
    if (scanned.isEmpty) return 0;

    // 本次批量内已比对过封面内容的 albumKey,避免每首歌重复读盘。
    final verifiedArtKeys = <String>{};

    // 批量级内存缓存:同一歌手/专辑在本次扫描内只查/建一次,
    // 避免每首歌都执行 artist/album 的 DB 查找。
    final artistIdCache = <String, int>{};
    final albumCache = <String, Album>{};

    // 一次性查现有行的首次入库时间(保留 dateAdded),替代每歌一条 SELECT。
    final dateAddedByPath = await _db.getDateAddedByFilePaths([
      for (final s in scanned) s.filePath,
    ]);

    var count = 0;
    await _db.transaction(() async {
      for (final song in scanned) {
        // ── Resolve artist ──────────────────────────────
        int? artistId;
        if (song.artist != null && song.artist!.trim().isNotEmpty) {
          artistId = await _getOrCreateArtist(
            song.artist!.trim(),
            cache: artistIdCache,
          );
        }

        // ── Resolve album + album art ───────────────────
        int? albumId;
        String? albumArtPath;
        if (song.album != null && song.album!.trim().isNotEmpty) {
          final result = await _getOrCreateAlbum(
            song.album!.trim(),
            artistId,
            song,
            verifiedArtKeys,
            albumCache: albumCache,
          );
          albumId = result.$1;
          albumArtPath = result.$2;
        } else {
          // 无专辑名:封面按「无专辑 + 歌手」回退 key 缓存,写入歌曲行
          // (albumArtFilePath 属于 song 列,不依赖 album)。
          albumArtPath = await _cacheArtForNoAlbum(song, verifiedArtKeys);
        }

        // ── 保留首次入库时间 ────────────────────────────
        // 更新已存在歌曲时沿用原 dateAdded,避免全量扫描反复重置
        // "最近添加"排序(文件创建时间无法通过 dart:io 读取)。
        final dateAdded = dateAddedByPath[song.filePath] ?? DateTime.now();

        await _db.insertSongOnConflictReplace(
          _toCompanion(
            song,
            artistId,
            albumId,
            albumArtPath,
            dateAdded: dateAdded,
          ),
        );
        count++;
      }
    });
    return count;
  }

  /// 无专辑名歌曲的封面缓存:按「无专辑 + 歌手」key 去重,复用专辑封面缓存。
  Future<String?> _cacheArtForNoAlbum(
    ScannedSong song,
    Set<String> verifiedArtKeys,
  ) async {
    if (!song.hasEmbeddedArt ||
        song.pictureBytes == null ||
        song.pictureMimeType == null) {
      return null;
    }
    return _saveArtIfChanged(
      _buildAlbumKey(_kNoAlbumName, song.albumArtist ?? song.artist),
      song.pictureBytes!,
      song.pictureMimeType!,
      verifiedArtKeys,
    );
  }

  // ─── Artist helpers ────────────────────────────────────

  /// Finds an existing artist by name or creates a new one.
  /// Returns the artist's id.
  ///
  /// [cache] 为本次扫描批量内的内存缓存(名字 → id):同一歌手的多首歌
  /// 只查/建一次,大幅减少扫描事务内的查询数。
  Future<int> _getOrCreateArtist(String name, {Map<String, int>? cache}) async {
    final cached = cache?[name];
    if (cached != null) return cached;

    final existing = await _db.getArtistByName(name);
    if (existing != null) {
      cache?[name] = existing.id;
      return existing.id;
    }

    final id = await _db.insertArtist(
      ArtistsCompanion(
        name: Value(name),
        nameSortKey: Value(buildSortKey(name)),
      ),
    );
    cache?[name] = id;
    return id;
  }

  // ─── Album helpers ─────────────────────────────────────

  /// Builds a stable album key used for art cache deduplication.
  ///
  /// Uses the album artist (falling back to the song artist) so a compilation
  /// album shared by many artists keeps a single cover.
  /// 无专辑名歌曲的封面缓存 key 前缀(避免与真实专辑名冲突)。
  static const String _kNoAlbumName = '__no_album__';

  String _buildAlbumKey(String albumName, String? albumArtist) {
    return '$albumName::${albumArtist ?? 'Unknown'}';
  }

  /// Finds an existing album for [albumName] / [artistId], or creates a new
  /// one, merging same-named albums across different song artists.
  ///
  /// Resolution order:
  /// 1. Exact match by `(albumName, artistId)` — the fast path for ordinary
  ///    albums and same-name albums by the same artist.
  /// 2. Reuse any existing album with the same name — merges compilation /
  ///    multi-artist albums into a single record. Skipped only when the song
  ///    carries an explicit `albumArtist` tag that differs from the existing
  ///    album's (treated as two distinct albums).
  /// 3. Create a new album (with embedded-art caching).
  ///
  /// If the reused album has no art yet and the current song provides embedded
  /// art, the art is cached using the album key (not the file path), ensuring
  /// one cover per album. Returns `(albumId, albumArtFilePath)`.
  Future<(int, String?)> _getOrCreateAlbum(
    String albumName,
    int? artistId,
    ScannedSong song,
    Set<String> verifiedArtKeys, {
    Map<String, Album>? albumCache,
  }) async {
    final albumArtist = song.albumArtist ?? song.artist;
    final albumKey = _buildAlbumKey(albumName, albumArtist);

    // 0) 批量内存缓存命中:同一 albumKey(同专辑 + 同歌手/专辑艺术家)的后续
    //    歌曲直接复用已解析的专辑——只做幂等的补写与封面确保,跳过两次 DB 查找。
    final cachedAlbum = albumCache?[albumKey];
    if (cachedAlbum != null) {
      await _fillAlbumArtistIfEmpty(cachedAlbum, song);
      await _fillYearIfEmpty(cachedAlbum, song);
      final artPath = await _ensureAlbumArt(
        cachedAlbum,
        song,
        albumKey,
        verifiedArtKeys,
      );
      return (cachedAlbum.id, artPath);
    }

    // 1) Exact match by name + song artist.
    if (artistId != null) {
      final existing = await _db.getAlbumByNameAndArtist(albumName, artistId);
      if (existing != null) {
        await _fillAlbumArtistIfEmpty(existing, song);
        await _fillYearIfEmpty(existing, song);
        final artPath = await _ensureAlbumArt(
          existing,
          song,
          albumKey,
          verifiedArtKeys,
        );
        albumCache?[albumKey] = existing;
        return (existing.id, artPath);
      }
    }

    // 2) Reuse a same-named album (merges multi-artist albums).
    final byName = await _db.getAlbumByName(albumName);
    if (byName != null && !_isDistinctAlbum(byName, song.albumArtist)) {
      await _fillAlbumArtistIfEmpty(byName, song);
      await _fillYearIfEmpty(byName, song);
      final artPath = await _ensureAlbumArt(
        byName,
        song,
        albumKey,
        verifiedArtKeys,
      );
      albumCache?[albumKey] = byName;
      return (byName.id, artPath);
    }

    // 3) Create a new album, caching embedded art.
    String? albumArtPath;
    if (song.hasEmbeddedArt &&
        song.pictureBytes != null &&
        song.pictureMimeType != null) {
      // 复用 / 覆盖该 albumKey 的缓存封面(内容变化才重写,路径保持不变)。
      albumArtPath = await _saveArtIfChanged(
        albumKey,
        song.pictureBytes!,
        song.pictureMimeType!,
        verifiedArtKeys,
      );
    }

    final albumId = await _db.insertAlbum(
      AlbumsCompanion(
        name: Value(albumName),
        artistId: Value(artistId),
        albumArtist: Value(albumArtist),
        nameSortKey: Value(buildSortKey(albumName)),
        albumArtFilePath: Value(albumArtPath),
        year: Value(song.year),
      ),
    );

    // 缓存新建的专辑,本次批量内同 albumKey 的后续歌曲直接命中。
    albumCache?[albumKey] = Album(
      id: albumId,
      name: albumName,
      artistId: artistId,
      albumArtist: albumArtist,
      albumArtFilePath: albumArtPath,
      year: song.year,
      genre: null,
      songCount: 0,
      nameSortKey: buildSortKey(albumName),
    );

    return (albumId, albumArtPath);
  }

  /// Whether a same-named album should be treated as a distinct album
  /// (i.e. NOT merged) — true only when the song carries an explicit
  /// `albumArtist` tag that differs from the existing album's. Without a tag
  /// the albums are merged by name.
  bool _isDistinctAlbum(Album album, String? songAlbumArtist) {
    final tag = songAlbumArtist?.trim();
    if (tag == null || tag.isEmpty) return false;
    final existing = album.albumArtist?.trim();
    if (existing == null || existing.isEmpty) return false;
    return existing != tag;
  }

  /// Returns the album's art path, saving (or refreshing) it from the current
  /// song's embedded art when the cached content differs.
  ///
  /// 封面路径由 [albumKey] 决定且保持不变,因此封面变更时直接覆盖同一文件,
  /// 所有引用该封面的歌曲无需改动数据库。
  Future<String?> _ensureAlbumArt(
    Album album,
    ScannedSong song,
    String albumKey,
    Set<String> verifiedArtKeys,
  ) async {
    if (!song.hasEmbeddedArt ||
        song.pictureBytes == null ||
        song.pictureMimeType == null) {
      return album.albumArtFilePath;
    }
    final path = await _saveArtIfChanged(
      albumKey,
      song.pictureBytes!,
      song.pictureMimeType!,
      verifiedArtKeys,
    );
    if (path != null && path != album.albumArtFilePath) {
      await _db.updateAlbum(
        AlbumsCompanion(albumArtFilePath: Value(path)),
        album.id,
      );
    }
    return path ?? album.albumArtFilePath;
  }

  /// 保存封面缓存,仅当缓存内容与 [bytes] 不同(或缓存缺失)时重写。
  ///
  /// [verifiedArtKeys] 记录本次批量已比对过的 albumKey:同一专辑只比对一次,
  /// 避免每首歌重复读盘。
  Future<String?> _saveArtIfChanged(
    String albumKey,
    Uint8List bytes,
    String mimeType,
    Set<String> verifiedArtKeys,
  ) async {
    try {
      final path = await _artCache.getAlbumArtPath(albumKey);
      if (verifiedArtKeys.add(albumKey)) {
        if (await _artContentChanged(path, bytes)) {
          // saveAlbumArt 返回按 mime 存的真实扩展名路径(png/webp/gif/jpg),
          // 不能沿用 getAlbumArtPath 的 `.jpg` 回退,否则 DB 记录指向不存在的
          // 文件,封面不显示(见 docs/Performance-Optimization.md 5.2)。
          return await _artCache.saveAlbumArt(albumKey, bytes, mimeType);
        }
      }
      return path;
    } catch (e) {
      AppLogger.warning('Cache', 'Failed to cache album art', e);
      return null;
    }
  }

  /// 判断 [cachedPath] 上已缓存的封面内容是否与 [newBytes] 不同。
  Future<bool> _artContentChanged(String cachedPath, Uint8List newBytes) async {
    final file = File(cachedPath);
    if (!await file.exists()) return true;
    try {
      final oldBytes = await file.readAsBytes();
      if (oldBytes.length != newBytes.length) return true;
      for (var i = 0; i < newBytes.length; i++) {
        if (oldBytes[i] != newBytes[i]) return true;
      }
      return false;
    } catch (_) {
      return true;
    }
  }

  // ─── File state sync ───────────────────────────────────

  /// Marks files that exist in the database but not on disk as unavailable.
  ///
  /// Returns the list of paths that were marked unavailable.
  Future<List<String>> markMissingFiles(
    Set<String> dbPaths,
    Set<String> diskPaths,
  ) async {
    final missing = dbPaths.difference(diskPaths).toList();
    if (missing.isEmpty) return missing;

    await _db.markAsUnavailable(missing);
    return missing;
  }

  /// Marks files that exist on disk but were previously unavailable as available.
  ///
  /// Returns the number of restored files.
  Future<int> restoreFiles(Set<String> restoredPaths) async {
    var count = 0;
    for (final path in restoredPaths) {
      count += await _db.markAsAvailable(path);
    }
    return count;
  }

  /// Physically deletes all songs under [folderPath] from the database.
  Future<int> removeFolder(String folderPath) async {
    return _db.deleteFolderSongs(folderPath);
  }

  /// 物理删除「确已从磁盘消失」的不可用(ghost)行，仅限 [roots] 下、且不在
  /// [diskFiles]（本次扫描在磁盘上实际看到的文件）。返回删除行数。
  ///
  /// 仅 force 扫描调用：普通全量只把缺失标不可用保留可恢复，这里才是真正
  /// 清理永远回不来的残留行（如转码后删除的原 flac）。删除后由调用方跑
  /// [cleanupOrphans] 清理被删行引用的 album/artist/playlist。
  Future<int> purgeUnavailableGone({
    required List<String> roots,
    required Set<String> diskFiles,
  }) async {
    if (roots.isEmpty) return 0;
    final songs = await _db.getUnavailableSongs();
    final toDelete = <String>[];
    for (final song in songs) {
      final path = song.filePath;
      // 只清理本次成功读取的根内的行；文件若还在磁盘（将恢复）则保留。
      if (!roots.any((root) => _isUnderRoot(path, root))) continue;
      if (diskFiles.contains(path)) continue;
      toDelete.add(path);
    }
    if (toDelete.isEmpty) return 0;
    return _db.deleteSongsByPaths(toDelete);
  }

  /// 清理不再被任何歌曲引用的 album / artist / playlist 行(全量扫描后调用)。
  Future<void> cleanupOrphans() => _db.cleanupOrphans();

  /// 删除 covers/ 目录中不再被任何专辑或歌曲引用的封面文件。
  Future<int> cleanupOrphanCovers() async {
    final referenced = await _db.getAllAlbumArtPaths();
    final keep = {for (final path in referenced) p.basename(path)};
    return _artCache.deleteOrphans(keep);
  }

  // ─── Helpers ───────────────────────────────────────────

  /// 边界语义的「路径在根下」判断：恰好等于根，或根后紧跟 `/`。
  ///
  /// 与 database.dart 里 `getFolderFilePaths`/`deleteFolderSongs` 的 SQL
  /// （`= root OR LIKE 'root/%'`）保持一致（均先 normalize），避免前缀误匹配
  /// 兄弟文件夹。
  bool _isUnderRoot(String path, String root) {
    final r = p.normalize(root);
    if (path == r) return true;
    return path.startsWith('$r/');
  }

  SongsCompanion _toCompanion(
    ScannedSong scanned,
    int? artistId,
    int? albumId,
    String? albumArtPath, {
    required DateTime dateAdded,
  }) {
    return SongsCompanion(
      title: Value(scanned.title),
      titleSortKey: Value(buildSortKey(scanned.title)),
      artist: Value(scanned.artist),
      album: Value(scanned.album),
      artistId: Value(artistId),
      albumId: Value(albumId),
      trackNumber: Value(scanned.trackNumber),
      discNumber: Value(scanned.discNumber),
      durationMs: Value(scanned.durationMs),
      filePath: Value(scanned.filePath),
      fileName: Value(scanned.fileName),
      fileSize: Value(scanned.fileSize),
      lastModifiedMs: Value(scanned.lastModifiedMs),
      mimeType: Value(scanned.mimeType),
      year: Value(scanned.year),
      genre: Value(scanned.genre),
      bitrate: Value(scanned.bitrate),
      sampleRate: Value(scanned.sampleRate),
      albumArtFilePath: Value(albumArtPath),
      hasEmbeddedArt: Value(scanned.hasEmbeddedArt ? 1 : 0),
      hasEmbeddedLyrics: Value(scanned.hasEmbeddedLyrics ? 1 : 0),
      lyricsFilePath: Value(scanned.lyricsFilePath),
      dateAdded: Value(dateAdded),
      isAvailable: const Value(1),
    );
  }
}
