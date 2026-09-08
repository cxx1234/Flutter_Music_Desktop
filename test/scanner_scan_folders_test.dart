import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:txvziwm/core/database/database.dart';
import 'package:txvziwm/core/services/library_scanner_service.dart';
import 'package:txvziwm/core/services/song_repository.dart';

/// 扫描全流程回归：验证 scanFolders 的 quick/full/force 三条路径都能完成，
/// 重点覆盖 3.2 的变化检测（`Isolate.run` + record Map）与 3.4 的文件夹并行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late LibraryScannerService scanner;
  late Directory dir;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('scan_folders_');
    // 把 path_provider 指向临时目录（封面缓存/清理等依赖应用文档目录）。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return dir.path;
          }
          return null;
        });
    scanner = LibraryScannerService(
      songRepository: SongRepository(database: db),
    );
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<String> addFile(String name, {String content = 'fake audio'}) async {
    final f = File('${dir.path}/$name');
    await f.writeAsString(content);
    return f.path;
  }

  test('全量扫描：首次新增；二次无变化 → 全部跳过（走 Isolate.run 变化检测）', () async {
    await addFile('song.mp3');

    final first = await scanner.scanFolders([dir.path], updateExisting: true);
    expect(first.added, 1, reason: '新文件应被解析入库');

    final second = await scanner.scanFolders([dir.path], updateExisting: true);
    expect(second.added, 0);
    expect(second.updated, 0);
    expect(
      second.skipped,
      1,
      reason: 'mtime/size 未变 → 跳过，走 detectChangedFiles',
    );
  });

  test('force 全量扫描：忽略变化检测，重解析全部已存在文件', () async {
    await addFile('song.mp3');
    await scanner.scanFolders([dir.path], updateExisting: true);

    final forced = await scanner.scanFolders(
      [dir.path],
      updateExisting: true,
      force: true,
    );
    expect(forced.updated, 1);
  });

  test('quick 同步（markMissing:false）：新增文件入库，不标记缺失', () async {
    await addFile('song.mp3');
    final r = await scanner.scanFolders([dir.path], markMissing: false);
    expect(r.added, 1);
  });

  test('多文件夹并行收集（3.4）：两个文件夹的文件都收集到', () async {
    final dir2 = await Directory.systemTemp.createTemp('scan_folders_2_');
    addTearDown(() async {
      if (await dir2.exists()) await dir2.delete(recursive: true);
    });
    await addFile('a.mp3');
    await File('${dir2.path}/b.mp3').writeAsString('fake');

    final r = await scanner.scanFolders([
      dir.path,
      dir2.path,
    ], updateExisting: true);
    // 两个文件都新增。
    expect(r.added, 2);
  });

  test('真实音频文件全量扫描（parseAll + 变化检测）不抛异常', () async {
    const src = 'test/music/黒うさP - 下弦の月.mp3';
    if (!await File(src).exists()) {
      // 真实素材缺失时跳过（与 metadata_service_test 一致）。
      markTestSkipped('test/music 无真实音频');
      return;
    }
    await File(src).copy('${dir.path}/real.mp3');

    // 首次全量扫描：真实解析（parseAll → Isolate.spawn → audio_metadata_reader）。
    final first = await scanner.scanFolders([dir.path], updateExisting: true);
    expect(first.added, 1, reason: '真实音频应被解析入库');

    // 二次扫描：变化检测（Isolate.run）应跳过未变化文件。
    final second = await scanner.scanFolders([dir.path], updateExisting: true);
    expect(second.updated, 0);
    expect(second.skipped, 1);
  });

  test('变化检测 isolate 不捕获 UI 回调（onProgress 含不可发送对象也不抛）', () async {
    await addFile('song.mp3');
    // 自定义对象默认不可跨 isolate 发送，用于模拟真实 app 里 onProgress 捕获
    // UI 上下文（此前内联闭包连带捕获它 → 抛 "object is unsendable"）。
    final sentinel = _NonSendable('ui');

    final r = await scanner.scanFolders(
      [dir.path],
      updateExisting: true,
      onProgress: (_) => sentinel.tag,
    );
    expect(r.added, 1);
  });

  test('单文件夹重扫只作用于该根：其它文件夹可用歌不被误标缺失', () async {
    final dirB = await Directory.systemTemp.createTemp('scan_folders_b_');
    addTearDown(() async {
      if (await dirB.exists()) await dirB.delete(recursive: true);
    });

    final aPath = await addFile('a.mp3');
    final bPath = '${dirB.path}/b.mp3';
    await File(bPath).writeAsString('fake');

    // 先全量扫两个根 → 两首都可用。
    final full = await scanner.scanFolders([
      dir.path,
      dirB.path,
    ], updateExisting: true);
    expect(full.added, 2);

    // 删除根 A 的文件，再只重扫根 A。
    await File(aPath).delete();
    final r = await scanner.scanFolders([dir.path], updateExisting: true);
    expect(r.markedMissing, 1, reason: '根 A 已删文件应被标缺失');

    final avail = await db.getAvailableSongs();
    expect(
      avail.map((s) => s.filePath),
      contains(bPath),
      reason: '根 B 的歌不应被单文件夹重扫影响',
    );
    expect(avail, hasLength(1));
  });

  test('force 扫描清理确已消失的 ghost；普通全量只标缺失保留', () async {
    final p = await addFile('song.mp3');
    await scanner.scanFolders([dir.path], updateExisting: true);

    // 删除文件后普通全量：只标缺失、保留行（可恢复）。
    await File(p).delete();
    final full = await scanner.scanFolders([dir.path], updateExisting: true);
    expect(full.markedMissing, 1);
    expect(await db.getUnavailableSongs(), hasLength(1));

    // force：物理清理确已消失的残留行。
    final forced = await scanner.scanFolders(
      [dir.path],
      updateExisting: true,
      force: true,
    );
    expect(forced.purged, 1);
    expect(await db.getUnavailableSongs(), isEmpty);
  });

  test('force 扫描不删仍在磁盘的 ghost（并恢复为可用）', () async {
    final p = await addFile('song.mp3');
    await scanner.scanFolders([dir.path], updateExisting: true);
    // 模拟：文件仍在磁盘但曾被误标为不可用（如权限抖动历史）。
    await db.markAsUnavailable([p]);

    final forced = await scanner.scanFolders(
      [dir.path],
      updateExisting: true,
      force: true,
    );
    expect(forced.purged, 0, reason: '文件还在磁盘 → 不删');
    expect(await db.getUnavailableSongs(), isEmpty);
    final avail = await db.getAvailableSongs();
    expect(avail.map((s) => s.filePath), contains(p), reason: '重新解析后恢复可用');
  });

  test('force 扫描不清理所扫根之外的 ghost（作用域限定）', () async {
    final dirB = await Directory.systemTemp.createTemp('scan_folders_c_');
    addTearDown(() async {
      if (await dirB.exists()) await dirB.delete(recursive: true);
    });

    final pA = await addFile('a.mp3');
    final pB = '${dirB.path}/b.mp3';
    await File(pB).writeAsString('fake');

    await scanner.scanFolders([dir.path, dirB.path], updateExisting: true);
    // 两个文件都删除并标记缺失。
    await File(pA).delete();
    await File(pB).delete();
    await scanner.scanFolders([dir.path, dirB.path], updateExisting: true);
    expect(await db.getUnavailableSongs(), hasLength(2));

    // 只 force 扫根 A → 只清根 A 的 ghost。
    final forced = await scanner.scanFolders(
      [dir.path],
      updateExisting: true,
      force: true,
    );
    expect(forced.purged, 1);
    final remaining = await db.getUnavailableSongs();
    expect(remaining.single.filePath, pB);
  });
}

/// 不可跨 isolate 发送的自定义对象（无异步生命周期，仅作回归哨兵）。
class _NonSendable {
  final String tag;
  const _NonSendable(this.tag);
}
