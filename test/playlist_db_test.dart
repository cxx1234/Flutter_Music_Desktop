import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:txvziwm/core/database/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<Song> insertSong(String title) async {
    final id = await db.insertSong(
      SongsCompanion.insert(
        title: title,
        fileName: '$title.mp3',
        filePath: '/music/$title.mp3',
        dateAdded: DateTime(2024),
      ),
    );
    return (await db.getSongById(id))!;
  }

  Future<int> insertPlaylist(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.insertPlaylist(
      PlaylistsCompanion.insert(name: name, createdAt: now, updatedAt: now),
    );
  }

  test('schema v4 可创建，播放列表 CRUD 正常', () async {
    final pid = await insertPlaylist('我的最爱');
    expect(pid, greaterThan(0));

    final playlists = await db.getAllPlaylists();
    expect(playlists.length, 1);
    expect(playlists.first.name, '我的最爱');

    // 重命名
    final ok = await db.updatePlaylist(
      PlaylistsCompanion(
        name: const Value('通勤歌单'),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
      pid,
    );
    expect(ok, isTrue);
    expect((await db.getPlaylistById(pid))!.name, '通勤歌单');
  });

  test('加歌去重、批量跳过已存在、移除与排序', () async {
    final s1 = await insertSong('A');
    final s2 = await insertSong('B');
    final s3 = await insertSong('C');
    final pid = await insertPlaylist('测试');

    // 加两首，重复加入同一首被忽略
    await db.addSongToPlaylist(pid, s1.id);
    await db.addSongToPlaylist(pid, s2.id);
    await db.addSongToPlaylist(pid, s1.id);
    var songs = await db.getSongsInPlaylist(pid);
    expect(songs.map((s) => s.id).toList(), [s1.id, s2.id]);

    // 移动到末尾
    await db.moveSongInPlaylist(pid, 0, 1);
    songs = await db.getSongsInPlaylist(pid);
    expect(songs.map((s) => s.id).toList(), [s2.id, s1.id]);

    // 移除
    await db.removeSongFromPlaylist(pid, s2.id);
    songs = await db.getSongsInPlaylist(pid);
    expect(songs.map((s) => s.id).toList(), [s1.id]);

    // 批量添加：s1 已存在被跳过，只新增 s3
    final added = await db.addSongsToPlaylist(pid, [s1.id, s3.id]);
    expect(added, 1);
    songs = await db.getSongsInPlaylist(pid);
    expect(songs.map((s) => s.id).toSet(), {s1.id, s3.id});

    // 计数
    final counts = await db.getPlaylistSongCounts();
    expect(counts[pid], 2);

    // 删除播放列表连带删除关联
    await db.deletePlaylist(pid);
    expect(await db.getAllPlaylists(), isEmpty);
  });

  test('reorderSongsInPlaylist 按给定顺序重排，未列出的行保持相对序追加末尾', () async {
    final s1 = await insertSong('A');
    final s2 = await insertSong('B');
    final s3 = await insertSong('C');
    final s4 = await insertSong('D');
    final pid = await insertPlaylist('排序测试');

    for (final s in [s1, s2, s3, s4]) {
      await db.addSongToPlaylist(pid, s.id);
    }
    expect((await db.getSongsInPlaylist(pid)).map((s) => s.id).toList(), [
      s1.id,
      s2.id,
      s3.id,
      s4.id,
    ]);

    // 按目标顺序整体重排
    await db.reorderSongsInPlaylist(pid, [s4.id, s2.id, s1.id, s3.id]);
    expect((await db.getSongsInPlaylist(pid)).map((s) => s.id).toList(), [
      s4.id,
      s2.id,
      s1.id,
      s3.id,
    ]);

    // 未列出的行（模拟过滤掉的不可用歌曲）保持原相对顺序追加到末尾
    await db.reorderSongsInPlaylist(pid, [s3.id, s1.id, s4.id]);
    expect((await db.getSongsInPlaylist(pid)).map((s) => s.id).toList(), [
      s3.id,
      s1.id,
      s4.id,
      s2.id,
    ]);
  });
}
