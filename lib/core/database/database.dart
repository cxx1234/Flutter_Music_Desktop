import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'song_sort_order.dart';
import 'tables/albums.dart';
import 'tables/artists.dart';
import 'tables/playlist_songs.dart';
import 'tables/playlists.dart';
import 'tables/songs.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Songs, Albums, Artists, Playlists, PlaylistSongs])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await _createIndexes();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from == 1) {
          await m.addColumn(songs, songs.isAvailable);
        }
        if (from <= 2) {
          await m.createTable(artists);
          await m.createTable(albums);
          await m.addColumn(songs, songs.artistId);
          await m.addColumn(songs, songs.albumId);
        }
        if (from <= 3) {
          await m.addColumn(songs, songs.titleSortKey);
          await m.addColumn(albums, albums.nameSortKey);
          await m.addColumn(artists, artists.nameSortKey);
          await m.createTable(playlists);
          await m.createTable(playlistSongs);
        }
        if (from <= 4) {
          await m.addColumn(songs, songs.lastModifiedMs);
        }
        if (from <= 5) {
          await _createIndexes();
        }
      },
    );
  }

  /// 建查询索引（onCreate 新装 + 老库升级共用）。
  ///
  /// 大库下 WHERE/JOIN/GROUP BY/ORDER BY 常用列都加索引，避免全表扫；
  /// `IF NOT EXISTS` 幂等，迁移失败重试不冲突。
  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_avail_sort '
      'ON songs(is_available, title_sort_key)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_album_id ON songs(album_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_artist_id ON songs(artist_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_fav_avail '
      'ON songs(is_favorite, is_available)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_plsongs_playlist '
      'ON playlist_songs(playlist_id, position)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_plsongs_song ON playlist_songs(song_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_albums_artist ON albums(artist_id)',
    );
  }

  static Future<AppDatabase> create() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(dir.path, 'music_library.db'));
    return AppDatabase(
      NativeDatabase(
        dbFile,
        // SQL 日志只在 debug 打印，release/profile 不逐条输出。
        logStatements: kDebugMode,
        // setup 回调收到的是 sqlite3 包的原始 Database（FFI 层），用 execute。
        setup: (db) {
          // WAL：读写互不阻塞（扫描批量写/后台 5s 位置落盘 vs 列表查询）。
          db.execute('PRAGMA journal_mode = WAL');
          // 并发写冲突时排队等待而非立即抛 SQLITE_BUSY。
          db.execute('PRAGMA busy_timeout = 5000');
        },
      ),
    );
  }

  // ─── CRUD ───────────────────────────────────────────────

  Future<List<Song>> getAllSongs() =>
      (select(songs)..orderBy([
            (t) => OrderingTerm.asc(t.titleSortKey, nulls: NullsOrder.last),
          ]))
          .get();

  Stream<List<Song>> watchAllSongs() =>
      (select(songs)..orderBy([
            (t) => OrderingTerm.asc(t.titleSortKey, nulls: NullsOrder.last),
          ]))
          .watch();

  Future<Song?> getSongById(int id) =>
      (select(songs)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> insertSong(SongsCompanion entry) => into(songs).insert(entry);

  Future<int> insertSongOnConflictReplace(SongsCompanion entry) => into(
    songs,
  ).insert(entry, onConflict: DoUpdate((_) => entry, target: [songs.filePath]));

  Future<int> deleteSong(Song song) => delete(songs).delete(song);

  Future<List<Song>> searchSongs(String query) {
    final pattern = '%$query%';
    return (select(songs)..where(
          (t) =>
              t.title.like(pattern) |
              t.artist.like(pattern) |
              t.album.like(pattern),
        ))
        .get();
  }

  Future<List<Song>> getSongsByFolder(String folderPath) {
    final pattern = '$folderPath%';
    return (select(songs)..where((t) => t.filePath.like(pattern))).get();
  }

  Future<Song?> getSongByFilePath(String filePath) => (select(
    songs,
  )..where((t) => t.filePath.equals(filePath))).getSingleOrNull();

  /// 按 filePath 批量查询（restoreQueue 用，替代逐首单行 SELECT 的 N+1）。
  ///
  /// 返回顺序与 [filePaths] 一致，仅保留存在且可用的歌曲。
  Future<List<Song>> getSongsByFilePaths(List<String> filePaths) async {
    if (filePaths.isEmpty) return const [];
    final rows = await (select(
      songs,
    )..where((t) => t.filePath.isIn(filePaths))).get();
    final byPath = {for (final s in rows) s.filePath: s};
    return [
      for (final fp in filePaths)
        if (byPath[fp]?.isAvailable == 1) byPath[fp]!,
    ];
  }

  /// 批量查询现有歌曲的首次入库时间（filePath → dateAdded）。
  ///
  /// 供扫描保留 dateAdded 用，替代每歌一条 SELECT。**不过滤 is_available**：
  /// 已存在但当前不可用的行也应沿用原 dateAdded。
  Future<Map<String, DateTime>> getDateAddedByFilePaths(
    List<String> filePaths,
  ) async {
    if (filePaths.isEmpty) return const {};
    final rows =
        await (selectOnly(songs)
              ..addColumns([songs.filePath, songs.dateAdded])
              ..where(songs.filePath.isIn(filePaths)))
            .get();
    final result = <String, DateTime>{};
    for (final r in rows) {
      final fp = r.read(songs.filePath);
      final added = r.read(songs.dateAdded);
      if (fp != null && added != null) result[fp] = added;
    }
    return result;
  }

  Future<int> getSongCount() async {
    final result = await customSelect('SELECT COUNT(*) FROM songs').getSingle();
    return result.read<int>('COUNT(*)');
  }

  Future<int> toggleFavorite(int id) {
    return transaction(() async {
      final song = await getSongById(id);
      if (song == null) return 0;
      final newValue = song.isFavorite == 1 ? 0 : 1;
      return (update(songs)..where((t) => t.id.equals(id))).write(
        SongsCompanion(isFavorite: Value(newValue)),
      );
    });
  }

  Future<int> incrementPlayCount(int id) {
    return transaction(() async {
      final song = await getSongById(id);
      if (song == null) return 0;
      return (update(songs)..where((t) => t.id.equals(id))).write(
        SongsCompanion(playCount: Value(song.playCount + 1)),
      );
    });
  }

  // ─── File state sync ────────────────────────────────────

  Future<List<String>> getAllFilePaths() async {
    return (select(
      songs,
    )..where((t) => t.isAvailable.equals(1))).map((s) => s.filePath).get();
  }

  /// 返回已存在歌曲的文件时间戳(file_size + last_modified_ms),按路径索引。
  ///
  /// 供扫描"变化检测"使用:只有 mtime 或大小与上次扫描不同才会被重解析。
  Future<Map<String, ({int? lastModifiedMs, int? fileSize})>>
  getExistingFileStats() async {
    final rows = await (select(
      songs,
    )..where((t) => t.isAvailable.equals(1))).get();
    return {
      for (final s in rows)
        s.filePath: (lastModifiedMs: s.lastModifiedMs, fileSize: s.fileSize),
    };
  }

  /// 返回当前仍被专辑或歌曲引用的所有封面文件路径(用于清理孤儿封面)。
  Future<Set<String>> getAllAlbumArtPaths() async {
    final albumRows =
        await (selectOnly(albums)
              ..addColumns([albums.albumArtFilePath])
              ..where(albums.albumArtFilePath.isNotNull()))
            .get();
    final songRows =
        await (selectOnly(songs)
              ..addColumns([songs.albumArtFilePath])
              ..where(songs.albumArtFilePath.isNotNull()))
            .get();
    return {
      for (final r in albumRows) r.read(albums.albumArtFilePath)!,
      for (final r in songRows) r.read(songs.albumArtFilePath)!,
    };
  }

  Future<List<String>> getFolderFilePaths(String folderPath) async {
    final pattern = '$folderPath%';
    return (select(songs)
          ..where((t) => t.filePath.like(pattern) & t.isAvailable.equals(1)))
        .map((s) => s.filePath)
        .get();
  }

  Future<int> markAsUnavailable(List<String> filePaths) async {
    return (update(songs)..where((t) => t.filePath.isIn(filePaths))).write(
      SongsCompanion(isAvailable: const Value(0)),
    );
  }

  Future<int> markAsAvailable(String filePath) async {
    return (update(songs)..where((t) => t.filePath.equals(filePath))).write(
      SongsCompanion(isAvailable: const Value(1)),
    );
  }

  /// Deletes all songs under [folderPath], then removes orphaned
  /// albums / artists / playlist references that no longer point at any song.
  ///
  /// Runs in a single transaction so the cleanup is atomic with the delete.
  Future<int> deleteFolderSongs(String folderPath) async {
    final pattern = '$folderPath%';
    return transaction(() async {
      final deleted = await (delete(
        songs,
      )..where((t) => t.filePath.like(pattern))).go();
      await cleanupOrphans();
      return deleted;
    });
  }

  /// Removes rows in [playlistSongs] / [albums] / [artists] that no longer
  /// reference any song in the `songs` table (e.g. after a folder is removed,
  /// or a full scan moved songs to other albums).
  ///
  /// Rows for songs merely marked unavailable (`isAvailable=0`) are kept —
  /// those still exist and may come back on a later scan.
  Future<void> cleanupOrphans() async {
    // 1. Playlist rows pointing at deleted songs.
    final songRows = await (selectOnly(songs)..addColumns([songs.id])).get();
    final songIds = songRows
        .map((row) => row.read(songs.id))
        .whereType<int>()
        .toList();
    if (songIds.isEmpty) {
      await delete(playlistSongs).go();
    } else {
      await (delete(
        playlistSongs,
      )..where((t) => t.songId.isNotIn(songIds))).go();
    }

    // 2. Albums with no remaining songs.
    final albumRows =
        await (selectOnly(songs)
              ..addColumns([songs.albumId])
              ..where(songs.albumId.isNotNull()))
            .get();
    final albumIds = albumRows
        .map((row) => row.read(songs.albumId))
        .whereType<int>()
        .toList();
    if (albumIds.isEmpty) {
      await delete(albums).go();
    } else {
      await (delete(albums)..where((t) => t.id.isNotIn(albumIds))).go();
    }

    // 3. Artists with no remaining songs.
    final artistRows =
        await (selectOnly(songs)
              ..addColumns([songs.artistId])
              ..where(songs.artistId.isNotNull()))
            .get();
    final artistIds = artistRows
        .map((row) => row.read(songs.artistId))
        .whereType<int>()
        .toList();
    if (artistIds.isEmpty) {
      await delete(artists).go();
    } else {
      await (delete(artists)..where((t) => t.id.isNotIn(artistIds))).go();
    }
  }

  Future<List<Song>> getUnavailableSongs() {
    return (select(songs)..where((t) => t.isAvailable.equals(0))).get();
  }

  Future<List<Song>> getAvailableSongs({
    SongSortOrder order = SongSortOrder.title,
  }) {
    return (select(songs)
          ..where((t) => t.isAvailable.equals(1))
          ..orderBy(_songOrdering(order)))
        .get();
  }

  // ─── Album queries ──────────────────────────────────────

  Future<List<Album>> getAllAlbums() =>
      (select(albums)..orderBy([
            (t) => OrderingTerm.asc(t.nameSortKey, nulls: NullsOrder.last),
            (t) => OrderingTerm.asc(t.albumArtist),
          ]))
          .get();

  Stream<List<Album>> watchAllAlbums() =>
      (select(albums)..orderBy([
            (t) => OrderingTerm.asc(t.nameSortKey, nulls: NullsOrder.last),
            (t) => OrderingTerm.asc(t.albumArtist),
          ]))
          .watch();

  /// Returns the albums whose ids are in [ids].
  ///
  /// 供歌手详情等按 id 集合定向查询，避免无谓地全表拉取所有专辑。
  /// 空集合直接返回空列表（drift 的 `IN ()` 不合法，须短路）。
  Future<List<Album>> getAlbumsByIds(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return const [];
    return (select(albums)..where((t) => t.id.isIn(list))).get();
  }

  Future<Album?> getAlbumById(int id) =>
      (select(albums)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Album?> getAlbumByNameAndArtist(String name, int artistId) =>
      (select(albums)
            ..where((t) => t.name.equals(name) & t.artistId.equals(artistId)))
          .getSingleOrNull();

  /// Returns the first album with the given [name], regardless of artist.
  ///
  /// Used to merge compilation / multi-artist albums that share a name.
  Future<Album?> getAlbumByName(String name) =>
      (select(albums)
            ..where((t) => t.name.equals(name))
            ..limit(1))
          .getSingleOrNull();

  Future<int> insertAlbum(AlbumsCompanion entry) => into(albums).insert(entry);

  Future<int> updateAlbum(AlbumsCompanion entry, int id) =>
      (update(albums)..where((t) => t.id.equals(id))).write(entry);

  /// 专辑详情页歌曲。只返回可用歌曲（`is_available=1`），与音乐库/浏览计数
  /// 一致：已删除文件仅被标记不可用（保留可恢复），不应出现在详情列表里。
  Future<List<Song>> getSongsByAlbum(int albumId) =>
      (select(songs)
            ..where((t) => t.albumId.equals(albumId) & t.isAvailable.equals(1))
            ..orderBy(_songTrackOrdering()))
          .get();

  Stream<List<Song>> watchSongsByAlbum(int albumId) =>
      (select(songs)
            ..where((t) => t.albumId.equals(albumId) & t.isAvailable.equals(1))
            ..orderBy(_songTrackOrdering()))
          .watch();

  // ─── Artist queries ─────────────────────────────────────

  Future<List<Artist>> getAllArtists() =>
      (select(artists)..orderBy([
            (t) => OrderingTerm.asc(t.nameSortKey, nulls: NullsOrder.last),
          ]))
          .get();

  Stream<List<Artist>> watchAllArtists() =>
      (select(artists)..orderBy([
            (t) => OrderingTerm.asc(t.nameSortKey, nulls: NullsOrder.last),
          ]))
          .watch();

  Future<Artist?> getArtistById(int id) =>
      (select(artists)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Artist?> getArtistByName(String name) =>
      (select(artists)..where((t) => t.name.equals(name))).getSingleOrNull();

  Future<int> insertArtist(ArtistsCompanion entry) =>
      into(artists).insert(entry);

  Future<int> updateArtist(ArtistsCompanion entry, int id) =>
      (update(artists)..where((t) => t.id.equals(id))).write(entry);

  /// 歌手详情页歌曲。只返回可用歌曲（`is_available=1`），与歌手卡片计数
  /// （`getArtistStats`）一致：被删除文件的残留行不应计入详情。
  Future<List<Song>> getSongsByArtist(int artistId) =>
      (select(songs)
            ..where(
              (t) => t.artistId.equals(artistId) & t.isAvailable.equals(1),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.album),
              ..._songTrackOrdering(),
            ]))
          .get();

  Stream<List<Song>> watchSongsByArtist(int artistId) =>
      (select(songs)
            ..where(
              (t) => t.artistId.equals(artistId) & t.isAvailable.equals(1),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.album),
              ..._songTrackOrdering(),
            ]))
          .watch();

  // ─── Playlist queries ──────────────────────────────────

  Future<List<Playlist>> getAllPlaylists() =>
      (select(playlists)..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.name),
          ]))
          .get();

  Stream<List<Playlist>> watchAllPlaylists() =>
      (select(playlists)..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.name),
          ]))
          .watch();

  Future<Playlist?> getPlaylistById(int id) =>
      (select(playlists)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> insertPlaylist(PlaylistsCompanion entry) =>
      into(playlists).insert(entry);

  Future<bool> updatePlaylist(PlaylistsCompanion entry, int id) async =>
      (await (update(playlists)..where((t) => t.id.equals(id))).write(entry)) >
      0;

  Future<void> deletePlaylist(int id) {
    return transaction(() async {
      await (delete(playlistSongs)..where((t) => t.playlistId.equals(id))).go();
      await (delete(playlists)..where((t) => t.id.equals(id))).go();
    });
  }

  /// 播放列表内的歌曲（按 position 排序，过滤不可用文件）。
  Future<List<Song>> getSongsInPlaylist(int playlistId, {int? limit}) {
    final query =
        select(songs).join([
            innerJoin(playlistSongs, playlistSongs.songId.equalsExp(songs.id)),
          ])
          ..where(
            playlistSongs.playlistId.equals(playlistId) &
                songs.isAvailable.equals(1),
          )
          ..orderBy([OrderingTerm.asc(playlistSongs.position)]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.map((row) => row.readTable(songs)).get();
  }

  /// 把 [songId] 加入 [playlistId]。若已存在则忽略（不允许重复）。
  Future<void> addSongToPlaylist(int playlistId, int songId) async {
    final nextPos = await _nextPosition(playlistId);
    await into(playlistSongs).insert(
      PlaylistSongsCompanion.insert(
        playlistId: playlistId,
        songId: songId,
        position: nextPos,
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// 批量添加歌曲，跳过已存在的；返回实际新增数量。
  Future<int> addSongsToPlaylist(int playlistId, List<int> songIds) {
    return transaction(() async {
      var count = 0;
      var pos = await _nextPosition(playlistId);
      for (final songId in songIds) {
        if (await _playlistHasSong(playlistId, songId)) continue;
        await into(playlistSongs).insert(
          PlaylistSongsCompanion.insert(
            playlistId: playlistId,
            songId: songId,
            position: pos++,
          ),
        );
        count++;
      }
      return count;
    });
  }

  /// 从播放列表移除歌曲，并重排剩余 position。
  Future<void> removeSongFromPlaylist(int playlistId, int songId) {
    return transaction(() async {
      await (delete(playlistSongs)..where(
            (t) => t.playlistId.equals(playlistId) & t.songId.equals(songId),
          ))
          .go();
      await _renumberPositions(playlistId);
    });
  }

  /// 移动播放列表内歌曲 [oldIndex] → [newIndex]。
  Future<void> moveSongInPlaylist(int playlistId, int oldIndex, int newIndex) {
    return transaction(() async {
      final rows =
          await (select(playlistSongs)
                ..where((t) => t.playlistId.equals(playlistId))
                ..orderBy([(t) => OrderingTerm.asc(t.position)]))
              .get();
      if (oldIndex < 0 || oldIndex >= rows.length) return;
      if (newIndex < 0 || newIndex > rows.length) return;
      final item = rows.removeAt(oldIndex);
      rows.insert(newIndex, item);
      await _writePositions(rows);
    });
  }

  /// 我的收藏：isFavorite=1 的可用歌曲（按标题排序键）。
  Future<List<Song>> getFavoriteSongs() =>
      (select(songs)
            ..where((t) => t.isFavorite.equals(1) & t.isAvailable.equals(1))
            ..orderBy([
              (t) => OrderingTerm.asc(t.titleSortKey, nulls: NullsOrder.last),
            ]))
          .get();

  Future<int> getFavoriteCount() async {
    final result = await customSelect(
      'SELECT COUNT(*) FROM songs WHERE is_favorite = 1 AND is_available = 1',
    ).getSingle();
    return result.read<int>('COUNT(*)');
  }

  /// 每个播放列表的可用歌曲数。
  Future<Map<int, int>> getPlaylistSongCounts() async {
    final rows = await customSelect(
      'SELECT ps.playlist_id AS pid, COUNT(*) AS c '
      'FROM playlist_songs ps '
      'JOIN songs s ON s.id = ps.song_id '
      'WHERE s.is_available = 1 '
      'GROUP BY ps.playlist_id',
    ).get();
    return {for (final r in rows) r.read<int>('pid'): r.read<int>('c')};
  }

  /// 每个歌手的可用歌曲数与专辑数（聚合查询）。
  ///
  /// 供歌手浏览页计数用，避免在内存里持有全量歌曲/专辑副本。
  Future<Map<int, ({int songCount, int albumCount})>> getArtistStats() async {
    final rows = await customSelect(
      'SELECT artist_id AS aid, '
      'COUNT(*) AS song_count, '
      'COUNT(DISTINCT album_id) AS album_count '
      'FROM songs '
      'WHERE is_available = 1 AND artist_id IS NOT NULL '
      'GROUP BY artist_id',
    ).get();
    return {
      for (final r in rows)
        r.read<int>('aid'): (
          songCount: r.read<int>('song_count'),
          albumCount: r.read<int>('album_count'),
        ),
    };
  }

  // ─── Sort key backfill ─────────────────────────────────

  Future<List<Song>> getSongsWithNullSortKey() =>
      (select(songs)..where((t) => t.titleSortKey.isNull())).get();

  Future<void> updateSongSortKey(int id, String key) =>
      (update(songs)..where((t) => t.id.equals(id))).write(
        SongsCompanion(titleSortKey: Value(key)),
      );

  Future<List<Album>> getAlbumsWithNullSortKey() =>
      (select(albums)..where((t) => t.nameSortKey.isNull())).get();

  Future<void> updateAlbumSortKey(int id, String key) =>
      (update(albums)..where((t) => t.id.equals(id))).write(
        AlbumsCompanion(nameSortKey: Value(key)),
      );

  Future<List<Artist>> getArtistsWithNullSortKey() =>
      (select(artists)..where((t) => t.nameSortKey.isNull())).get();

  Future<void> updateArtistSortKey(int id, String key) =>
      (update(artists)..where((t) => t.id.equals(id))).write(
        ArtistsCompanion(nameSortKey: Value(key)),
      );

  // ─── Helpers ───────────────────────────────────────────

  List<OrderingTerm Function($SongsTable)> _songTrackOrdering() => [
    (t) => OrderingTerm.asc(t.discNumber),
    (t) => OrderingTerm.asc(t.trackNumber),
    (t) => OrderingTerm.asc(t.titleSortKey, nulls: NullsOrder.last),
  ];

  List<OrderingTerm Function($SongsTable)> _songOrdering(SongSortOrder order) {
    switch (order) {
      case SongSortOrder.title:
        return [
          (t) => OrderingTerm.asc(t.titleSortKey, nulls: NullsOrder.last),
        ];
      case SongSortOrder.dateAdded:
        return [(t) => OrderingTerm.desc(t.dateAdded)];
      case SongSortOrder.playCount:
        return [(t) => OrderingTerm.desc(t.playCount)];
      case SongSortOrder.year:
        return [(t) => OrderingTerm.desc(t.year)];
    }
  }

  Future<int> _nextPosition(int playlistId) async {
    final result = await customSelect(
      'SELECT COALESCE(MAX(position), -1) + 1 AS next '
      'FROM playlist_songs WHERE playlist_id = ?',
      variables: [Variable(playlistId)],
    ).getSingle();
    return result.read<int>('next');
  }

  Future<bool> _playlistHasSong(int playlistId, int songId) async {
    final row =
        await (select(playlistSongs)
              ..where(
                (t) =>
                    t.playlistId.equals(playlistId) & t.songId.equals(songId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<void> _renumberPositions(int playlistId) async {
    final rows =
        await (select(playlistSongs)
              ..where((t) => t.playlistId.equals(playlistId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get();
    await _writePositions(rows);
  }

  Future<void> _writePositions(List<PlaylistSong> rows) async {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].position != i) {
        await (update(playlistSongs)..where((t) => t.id.equals(rows[i].id)))
            .write(PlaylistSongsCompanion(position: Value(i)));
      }
    }
  }
}
