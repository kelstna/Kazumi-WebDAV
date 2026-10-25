// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/openlist/openlist_service.dart';
import 'package:kazumi/services/player/subtitle/subtitle_font_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一个字体文件里读出来的名字信息。
class WebDavFontFace {
  const WebDavFontFace({
    required this.file,
    required this.size,
    required this.family,
    required this.aliases,
    this.path = '',
    this.modified = '',
  });

  final String file;

  /// 字体在 WebDAV 上的完整路径（字体包可能按子目录存放）。
  final String path;
  final int size;
  final String modified;
  final String family;
  final List<String> aliases;

  Map<String, dynamic> toJson() => {
        'file': file,
        'path': path,
        'size': size,
        'modified': modified,
        'family': family,
        'aliases': aliases,
      };

  factory WebDavFontFace.fromJson(Map<String, dynamic> json) {
    return WebDavFontFace(
      file: json['file'] as String? ?? '',
      path: json['path'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: json['modified'] as String? ?? '',
      family: json['family'] as String? ?? '',
      aliases: (json['aliases'] as List?)?.cast<String>() ?? const [],
    );
  }
}

class WebDavFontIndex {
  const WebDavFontIndex({
    required this.directory,
    required this.builtAt,
    required this.faces,
  });

  final String directory;
  final DateTime? builtAt;
  final List<WebDavFontFace> faces;

  static const empty = WebDavFontIndex(
    directory: '',
    builtAt: null,
    faces: [],
  );
}

/// Kazumi 侧的 WebDAV 字体库。
///
/// 不要求 WebDAV 侧放索引文件：这里自己列出字体目录，流式读取每个字体
/// 文件头里的 `name` 表，得到 family / 别名，再把索引存在本地。
class WebDavFontService {
  WebDavFontService._();

  static final WebDavFontService instance = WebDavFontService._();

  /// 自动下载字体的缓存上限。
  static const int cacheLimitBytes = 200 * 1024 * 1024;

  static const Set<String> _fontExtensions = {'.ttf', '.otf', '.ttc'};

  Directory? _root;
  Map<String, WebDavFontFace>? _localIndex;

  Future<Directory> _baseDir() async {
    final existing = _root;
    if (existing != null) {
      return existing;
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'webdav_fonts'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  String get fontDirectory =>
      GStorage.getSetting<String>(SettingsKeys.webdavFontDirectory).trim();

  /// 去掉尾部斜杠、补齐开头的路径形式。
  static String normalizeDirectory(String value) => _normalizeDirectory(value);

  String get normalizedDirectory => _normalizeDirectory(fontDirectory);

  bool get isConfigured =>
      fontDirectory.isNotEmpty && OpenListService.instance.baseUrl.isNotEmpty;

  File _indexFile(Directory dir) => File(p.join(dir.path, 'index.json'));
  File _manifestFile(Directory dir) => File(p.join(dir.path, 'manifest.json'));
  File _cacheFile(Directory dir) => File(p.join(dir.path, 'cache.json'));

  /// 读取本地索引；目录变了就当作空索引。
  Future<WebDavFontIndex> loadIndex() async {
    try {
      final dir = await _baseDir();
      final file = _indexFile(dir);
      if (!await file.exists()) {
        return WebDavFontIndex.empty;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return WebDavFontIndex.empty;
      }
      final directory = decoded['directory'] as String? ?? '';
      final builtAtRaw = decoded['builtAt'] as String?;
      final faces = (decoded['faces'] as List?)
              ?.whereType<Map>()
              .map((item) => WebDavFontFace.fromJson(Map<String, dynamic>.from(item)))
              .toList() ??
          const <WebDavFontFace>[];
      return WebDavFontIndex(
        directory: directory,
        builtAt: builtAtRaw == null ? null : DateTime.tryParse(builtAtRaw),
        faces: faces,
      );
    } catch (error) {
      KazumiLogger().w('WebDavFontService: failed to read index', error: error);
      return WebDavFontIndex.empty;
    }
  }

  /// 扫描 WebDAV 字体目录并重建本地索引。
  ///
  /// [onProgress] 的第一个参数是已处理数量，第二个是总数。
  Future<int> buildIndex({
    void Function(int done, int total)? onProgress,
    void Function(int directories, int files)? onListing,
    bool Function()? shouldCancel,
    bool force = false,
  }) async {
    final directory = normalizedDirectory;
    if (directory.isEmpty) {
      throw OpenListException('未设置 WebDAV 字体目录');
    }
    final files = await _collectFontEntries(directory, onListing: onListing);
    if (files.isEmpty) {
      throw OpenListException('字体目录里没有 .ttf/.otf/.ttc 文件');
    }

    final previous = await loadIndex();
    final oldByFile = {
      for (final face in previous.faces)
        if (previous.directory == directory) face.file: face,
    };

    final faces = <WebDavFontFace>[];
    final pending = <OpenListEntry>[];
    for (final entry in files) {
      final old = oldByFile[entry.name];
      final unchanged = old != null &&
          !force &&
          old.size == entry.size &&
          old.path.isNotEmpty &&
          (entry.modified.isEmpty || old.modified == entry.modified);
      if (unchanged) {
        faces.add(old);
      } else {
        pending.add(entry);
      }
    }

    var done = faces.length;
    onProgress?.call(done, files.length);
    final client = http.Client();
    const batchSize = 8;
    var batchesSinceCheckpoint = 0;
    final dir = await _baseDir();
    try {
      for (var start = 0; start < pending.length; start += batchSize) {
        if (shouldCancel?.call() ?? false) {
          throw FontIndexCancelled();
        }
        final batch = pending.skip(start).take(batchSize).toList();
        final headers = await Future.wait(
          batch.map((entry) => _readHeader(entry, client)),
        );
        final inputs = headers.whereType<Map<String, Object>>().toList();
        if (inputs.isNotEmpty) {
          // 字体表解析放到后台 isolate，主线程只收进度。
          final parsed = await compute(_parseFontHeaders, inputs);
          faces.addAll(parsed.map(WebDavFontFace.fromJson));
        }
        done += batch.length;
        onProgress?.call(done, files.length);
        batchesSinceCheckpoint++;
        // 每 10 批（约 80 个字体）落一次盘。
        if (batchesSinceCheckpoint >= 10) {
          batchesSinceCheckpoint = 0;
          await _writeIndex(dir, directory, faces);
        }
      }
    } finally {
      client.close();
    }

    faces.sort((a, b) => a.file.toLowerCase().compareTo(b.file.toLowerCase()));
    await _writeIndex(dir, directory, faces);
    KazumiLogger().i(
        'WebDavFontService: indexed ${faces.length} fonts in $directory');
    return faces.length;
  }

  Future<void> _writeIndex(
    Directory dir,
    String directory,
    List<WebDavFontFace> faces,
  ) async {
    final payload = <String, Object>{
      'version': 1,
      'directory': directory,
      'builtAt': DateTime.now().toIso8601String(),
      'faces': faces.map((face) => face.toJson()).toList(),
    };
    final encoded = await compute(_encodeIndexPayload, payload);
    await _indexFile(dir).writeAsString(encoded, flush: true);
  }

  /// 字体包经常按类型分子目录，这里做有限深度的递归扫描。
  Future<List<OpenListEntry>> _collectFontEntries(String root,
      {void Function(int directories, int files)? onListing}) async {
    final files = <OpenListEntry>[];
    final queue = <String>[root];
    final scanned = <String>{};
    var directories = 0;
    while (queue.isNotEmpty && files.length < 3000) {
      final directory = queue.removeAt(0);
      if (!scanned.add(directory)) {
        continue;
      }
      directories++;
      if (directories > 120) {
        break;
      }
      List<OpenListEntry> entries;
      try {
        entries = await OpenListService.instance.list(directory);
        // 让出事件循环，避免连续解析 PROPFIND XML 顶住 UI。
        await Future<void>.delayed(Duration.zero);
      } catch (error) {
        KazumiLogger().w(
          'WebDavFontService: failed to list $directory',
          error: error,
        );
        continue;
      }
      onListing?.call(directories, files.length);
      for (final entry in entries) {
        if (entry.isDir) {
          if (queue.length < 300) {
            queue.add(entry.path);
          }
        } else if (_fontExtensions
            .contains(p.extension(entry.name).toLowerCase())) {
          files.add(entry);
        }
      }
    }
    files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return files;
  }

  static String _normalizeDirectory(String value) {
    var path = value.trim();
    if (path.isEmpty) {
      return '';
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  /// 给外挂字幕里出现的字体名补字体，返回本次新装数量。
  Future<int> ensureFonts(
    Set<String> names, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (names.isEmpty || !isConfigured) {
      return 0;
    }
    final index = await loadIndex();
    if (index.faces.isEmpty || index.directory != normalizedDirectory) {
      return 0;
    }
    final dir = await _baseDir();
    final manifest = await _readMap(_manifestFile(dir));
    final cache = await _readCache(dir);
    final fontDir = await SubtitleFontService().directory();
    final local = await _ensureLocalIndex();

    final keys = names.map(_normalize).where((key) => key.isNotEmpty).toSet();
    final missing = <String>{};
    for (final key in keys) {
      final installed = manifest[key];
      if (installed != null && await File(p.join(fontDir.path, installed)).exists()) {
        final meta = cache[installed];
        if (meta != null) {
          meta['lastUsedAt'] = DateTime.now().millisecondsSinceEpoch;
        }
        continue;
      }
      manifest.remove(key);
      // 手动导入 / Download/KazumiFonts 的字体优先，本地命中就不再下载。
      if (local.containsKey(key)) {
        continue;
      }
      missing.add(key);
    }

    if (missing.isEmpty) {
      await _writeCache(dir, cache);
      return 0;
    }

    final candidates = <WebDavFontFace>[];
    final seenFiles = <String>{};
    for (final key in missing) {
      for (final face in index.faces) {
        if (!seenFiles.contains(face.file) && _matches(face, key)) {
          candidates.add(face);
          seenFiles.add(face.file);
          break;
        }
      }
    }
    if (candidates.isEmpty) {
      return 0;
    }

    final limit = candidates.length > 20 ? 20 : candidates.length;
    var installed = 0;
    var done = 0;
    for (var start = 0; start < limit; start += 2) {
      final batch = candidates.skip(start).take(2);
      final results = await Future.wait(batch.map((face) async {
        final ok = await _downloadFont(face, fontDir.path);
        return ok ? face : null;
      }));
      for (final face in results.whereType<WebDavFontFace>()) {
        for (final alias in face.aliases) {
          final key = _normalize(alias);
          if (key.isNotEmpty) {
            manifest[key] = face.file;
          }
        }
        final key = _normalize(p.basenameWithoutExtension(face.file));
        if (key.isNotEmpty) {
          manifest[key] = face.file;
        }
        final file = File(p.join(fontDir.path, face.file));
        cache[face.file] = {
          'size': await file.length(),
          'lastUsedAt': DateTime.now().millisecondsSinceEpoch,
          'source': 'webdav',
        };
        installed++;
      }
      done += results.length;
      onProgress?.call(done, limit);
    }

    if (installed > 0) {
      await _writeMap(_manifestFile(dir), manifest);
      await _evict(dir, cache, fontDir);
      await _writeCache(dir, cache);
      _localIndex = null;
      KazumiLogger().i('WebDavFontService: installed $installed fonts');
    }
    return installed;
  }

  /// 字体目录变化（导入/链接新字体）后清掉内存索引。
  void invalidateLocalIndex() {
    _localIndex = null;
  }

  /// 本地已有字体（手动导入 / Download 链接 / 已下载）的索引。
  ///
  /// 优先级：手动导入 > Download/KazumiFonts 链接 > WebDAV 缓存。
  Future<Map<String, WebDavFontFace>> _ensureLocalIndex() async {
    final existing = _localIndex;
    if (existing != null) {
      return existing;
    }
    final dir = await SubtitleFontService().directory();
    final base = await _baseDir();
    final cacheFile = File(p.join(base.path, 'local_index.json'));
    final cached = await _readMap(cacheFile);
    final webdavFiles = (await _readCache(base)).keys.toSet();
    final result = <String, WebDavFontFace>{};
    final priorities = <String, int>{};
    final fresh = <String, dynamic>{};

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          continue;
        }
        final name = p.basename(entity.path);
        final extension = p.extension(name).toLowerCase();
        if (!_fontExtensions.contains(extension) ||
            name == 'MiSans-Regular.ttf') {
          continue;
        }
        final isLink = entity is Link;
        final file = File(entity.path);
        FileStat stat;
        try {
          stat = await file.stat();
        } catch (_) {
          continue;
        }
        if (stat.type != FileSystemEntityType.file) {
          continue;
        }
        final stamp = '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
        Map<String, dynamic> row;
        final old = cached[name];
        if (old is Map && old['stamp'] == stamp) {
          row = Map<String, dynamic>.from(old);
        } else {
          final names = await _readLocalFontNames(entity.path);
          final aliases = <String>{
            ...names,
            p.basenameWithoutExtension(name),
          }.where((value) => value.trim().isNotEmpty).toList(growable: false);
          row = {
            'stamp': stamp,
            'size': stat.size,
            'family': aliases.isEmpty
                ? p.basenameWithoutExtension(name)
                : aliases.first,
            'aliases': aliases,
            'link': isLink,
          };
        }
        fresh[name] = row;
        if (row['link'] is! bool) {
          row['link'] = isLink;
        }
        final face = WebDavFontFace(
          file: name,
          size: (row['size'] as num?)?.toInt() ?? stat.size,
          family: row['family'] as String? ?? name,
          aliases: (row['aliases'] as List?)?.cast<String>() ?? const [],
        );
        final source = isLink
            ? 'external'
            : (webdavFiles.contains(name) ? 'webdav' : 'manual');
        final priority = source == 'manual' ? 0 : (source == 'external' ? 1 : 2);
        for (final alias in face.aliases) {
          final key = _normalize(alias);
          if (key.isEmpty) {
            continue;
          }
          final current = priorities[key];
          if (current == null || priority < current) {
            priorities[key] = priority;
            result[key] = face;
          }
        }
      }
    } catch (error) {
      KazumiLogger()
          .w('WebDavFontService: failed to scan local fonts', error: error);
    }

    _localIndex = result;
    await _writeMap(cacheFile, fresh);
    return result;
  }

  /// App 字体目录的总占用：手动导入 + 自动下载都算；软链接不计。
  Future<int> cacheBytes() async {
    final dir = await SubtitleFontService().directory();
    var total = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory || entity is Link) {
          continue;
        }
        final name = p.basename(entity.path);
        if (!_fontExtensions.contains(p.extension(name).toLowerCase()) ||
            name == 'MiSans-Regular.ttf') {
          continue;
        }
        final stat = await File(entity.path).stat();
        if (stat.type == FileSystemEntityType.file) {
          total += stat.size;
        }
      }
    } catch (_) {
      // 目录不可读时按 0 处理。
    }
    return total;
  }

  /// App 字体目录里的字体数量（不含软链接）。
  Future<int> cacheCount() async {
    final dir = await SubtitleFontService().directory();
    var count = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory || entity is Link) {
          continue;
        }
        final name = p.basename(entity.path);
        if (name != 'MiSans-Regular.ttf' &&
            _fontExtensions.contains(p.extension(name).toLowerCase())) {
          count++;
        }
      }
    } catch (_) {
      // ignore
    }
    return count;
  }

  Future<void> clearCache() async {
    final dir = await _baseDir();
    final cache = await _readCache(dir);
    final fontDir = await SubtitleFontService().directory();
    for (final file in cache.keys) {
      try {
        final target = File(p.join(fontDir.path, file));
        if (await target.exists()) {
          await target.delete();
        }
      } catch (error) {
        KazumiLogger().w('WebDavFontService: failed to delete $file', error: error);
      }
    }
    final manifest = await _readMap(_manifestFile(dir));
    manifest.removeWhere((_, file) => cache.containsKey(file));
    await _writeMap(_manifestFile(dir), manifest);
    await _writeCache(dir, {});
    _localIndex = null;
  }

  Future<void> _evict(
    Directory dir,
    Map<String, dynamic> cache,
    Directory fontDir,
  ) async {
    var total = 0;
    final sizes = <String, int>{};
    for (final entry in cache.entries) {
      try {
        final stat = await File(p.join(fontDir.path, entry.key)).stat();
        final size = stat.type == FileSystemEntityType.file ? stat.size : 0;
        sizes[entry.key] = size;
        total += size;
      } catch (_) {
        sizes[entry.key] = 0;
      }
    }
    if (total <= cacheLimitBytes) {
      return;
    }
    final ordered = cache.entries.toList()
      ..sort((a, b) => ((a.value as Map)['lastUsedAt'] as num? ?? 0)
          .compareTo((b.value as Map)['lastUsedAt'] as num? ?? 0));
    final manifest = await _readMap(_manifestFile(dir));
    for (final entry in ordered) {
      if (total <= cacheLimitBytes) {
        break;
      }
      final file = entry.key;
      try {
        final target = File(p.join(fontDir.path, file));
        if (await target.exists()) {
          await target.delete();
        }
      } catch (_) {
        // 删除失败就留着，下次再试。
        continue;
      }
      total -= sizes[file] ?? 0;
      cache.remove(file);
      manifest.removeWhere((_, value) => value == file);
    }
    await _writeMap(_manifestFile(dir), manifest);
  }

  Future<bool> _downloadFont(WebDavFontFace face, String fontDir) async {
    try {
      final response = await http
          .get(
              OpenListService.instance.uriFor(
                face.path.isNotEmpty
                    ? face.path
                    : '$normalizedDirectory/${face.file}',
              ),
              headers: OpenListService.instance.authHeaders)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return false;
      }
      final bytes = response.bodyBytes;
      if (bytes.length > 100 * 1024 * 1024 || !_looksLikeFont(bytes)) {
        KazumiLogger().w(
            'WebDavFontService: rejected font ${face.file} (${bytes.length} bytes)');
        return false;
      }
      final target = File(p.join(fontDir, face.file));
      final temp = File('${target.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
      return true;
    } catch (error) {
      KazumiLogger().w('WebDavFontService: failed to download ${face.file}',
          error: error);
      return false;
    }
  }

  bool _matches(WebDavFontFace face, String key) {
    if (_normalize(face.family) == key) {
      return true;
    }
    if (_normalize(p.basenameWithoutExtension(face.file)) == key) {
      return true;
    }
    for (final alias in face.aliases) {
      if (_normalize(alias) == key) {
        return true;
      }
    }
    return false;
  }

  static bool _looksLikeFont(Uint8List bytes) {
    if (bytes.length < 12) {
      return false;
    }
    final tag = String.fromCharCodes(bytes.sublist(0, 4));
    return tag == 'ttcf' ||
        tag == 'OTTO' ||
        tag == 'true' ||
        tag == 'typ1' ||
        (bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0);
  }

  static String _normalize(String value) =>
      value.replaceAll(RegExp(r'[\s_\-·．.（）()\[\]]+'), '').toLowerCase();

  Future<Map<String, Object>?> _readHeader(
    OpenListEntry entry,
    http.Client client,
  ) async {
    final bytes = await _readHeaderBytes(entry.path, client);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return <String, Object>{
      'name': entry.name,
      'path': entry.path,
      'size': entry.size,
      'modified': entry.modified,
      'bytes': bytes,
    };
  }

  Future<Uint8List?> _readHeaderBytes(String path, http.Client client) async {
    try {
      final request = http.Request('GET', OpenListService.instance.uriFor(path));
      request.headers.addAll(OpenListService.instance.authHeaders);
      request.headers['Range'] = 'bytes=0-262143';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 && response.statusCode != 206) {
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        builder.add(chunk);
        if (builder.length >= 262144) {
          break;
        }
      }
      final bytes = builder.takeBytes();
      return bytes.length > 262144
          ? Uint8List.sublistView(bytes, 0, 262144)
          : bytes;
    } catch (error) {
      KazumiLogger()
          .w('WebDavFontService: failed to read header of $path', error: error);
      return null;
    }
  }

  Future<List<String>> _readFontNames(String path, http.Client client) async {
    final bytes = await _readHeaderBytes(path, client);
    if (bytes == null) {
      return const [];
    }
    return _namesFromBytes(bytes);
  }

  Future<List<String>> _readLocalFontNames(String path) async {
    try {
      final bytes = await File(path).openRead(0, 262144).fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (builder, chunk) => builder..add(chunk),
          );
      return _namesFromBytes(bytes.takeBytes());
    } catch (error) {
      KazumiLogger().w(
        'WebDavFontService: failed to read local font $path',
        error: error,
      );
      return const [];
    }
  }

  Future<List<String>> _readNamesFromStream(
      Stream<List<int>> stream, String label) async {
    final iterator = StreamIterator<List<int>>(stream);
    final reader = _FontReader(iterator);
    try {
      if (!await reader.ensure(12)) {
        return const [];
      }
      final tag = String.fromCharCodes(reader.bytes.sublist(0, 4));
      final names = <String>[];
      if (tag == 'ttcf') {
        final count = _u32(reader.bytes, 8);
        if (count <= 0 || count > 64 || !await reader.ensure(12 + 4 * count)) {
          return const [];
        }
        for (var i = 0; i < count; i++) {
          names
              .addAll(await _readFaceNames(reader, _u32(reader.bytes, 12 + 4 * i)));
        }
      } else {
        names.addAll(await _readFaceNames(reader, 0));
      }
      return names.toSet().toList(growable: false);
    } finally {
      await iterator.cancel();
    }
  }

  Future<List<String>> _readFaceNames(_FontReader reader, int base) async {
    if (!await reader.ensure(base + 12)) {
      return const [];
    }
    final numTables = _u16(reader.bytes, base + 4);
    if (numTables <= 0 || numTables > 512) {
      return const [];
    }
    final directoryEnd = base + 12 + 16 * numTables;
    if (!await reader.ensure(directoryEnd)) {
      return const [];
    }
    var nameOffset = 0;
    var nameLength = 0;
    for (var i = 0; i < numTables; i++) {
      final record = base + 12 + 16 * i;
      final tag = String.fromCharCodes(reader.bytes.sublist(record, record + 4));
      if (tag == 'name') {
        nameOffset = _u32(reader.bytes, record + 8);
        nameLength = _u32(reader.bytes, record + 12);
        break;
      }
    }
    if (nameOffset <= 0 || nameLength <= 0 || nameLength > 2 * 1024 * 1024) {
      return const [];
    }
    if (!await reader.ensure(nameOffset + nameLength)) {
      return const [];
    }
    return _parseNameTable(reader.bytes, nameOffset, nameLength);
  }

  List<String> _parseNameTable(Uint8List data, int offset, int length) {
    if (offset + 6 > data.length) {
      return const [];
    }
    final count = _u16(data, offset + 2);
    final stringOffset = _u16(data, offset + 4);
    if (count <= 0 || count > 4096) {
      return const [];
    }
    final end = (offset + length).clamp(0, data.length);
    final names = <String>{};
    for (var i = 0; i < count; i++) {
      final record = offset + 6 + 12 * i;
      if (record + 12 > end) {
        break;
      }
      final platform = _u16(data, record);
      final nameId = _u16(data, record + 6);
      final nameLength = _u16(data, record + 8);
      final nameOffset = _u16(data, record + 10);
      if (nameId != 1 && nameId != 4 && nameId != 6 && nameId != 16 && nameId != 17) {
        continue;
      }
      final start = offset + stringOffset + nameOffset;
      final stop = start + nameLength;
      if (start < 0 || stop > end || stop > data.length || nameLength == 0) {
        continue;
      }
      final text = _decodeName(data, start, nameLength, platform);
      final trimmed = text.replaceAll(RegExp(r'[\x00-\x1F]'), '').trim();
      if (trimmed.isNotEmpty) {
        names.add(trimmed);
      }
    }
    final list = names.toList();
    // 优先把 family 名字放前面：nameID 16/1 无法区分，这里保持读取顺序。
    return list;
  }

  String _decodeName(Uint8List data, int start, int length, int platform) {
    if (platform == 0 || platform == 3) {
      final codes = <int>[];
      for (var i = 0; i + 1 < length; i += 2) {
        codes.add((data[start + i] << 8) | data[start + i + 1]);
      }
      return String.fromCharCodes(codes);
    }
    return String.fromCharCodes(data.sublist(start, start + length));
  }

  static int _u16(Uint8List data, int offset) {
    if (offset + 2 > data.length) return 0;
    return (data[offset] << 8) | data[offset + 1];
  }

  static int _u32(Uint8List data, int offset) {
    if (offset + 4 > data.length) return 0;
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }

  Future<Map<String, dynamic>> _readCache(Directory dir) async {
    final raw = await _readMap(_cacheFile(dir));
    return raw.map((key, value) =>
        MapEntry(key, value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{}));
  }

  Future<void> _writeCache(Directory dir, Map<String, dynamic> cache) =>
      _writeMap(_cacheFile(dir), cache);

  Future<Map<String, dynamic>> _readMap(File file) async {
    try {
      if (!await file.exists()) {
        return <String, dynamic>{};
      }
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeMap(File file, Map<String, dynamic> value) async {
    try {
      await file.writeAsString(jsonEncode(value), flush: true);
    } catch (error) {
      KazumiLogger().w('WebDavFontService: failed to write ${file.path}',
          error: error);
    }
  }
}

/// 只按需读取字体文件头部，不把整个字体下载下来。

String _encodeIndexPayload(Map<String, Object> payload) =>
    jsonEncode(payload);

/// 后台 isolate：解析一批字体头，返回可直接 fromJson 的 map。
List<Map<String, Object>> _parseFontHeaders(List<Map<String, Object>> inputs) {
  final result = <Map<String, Object>>[];
  for (final input in inputs) {
    final name = input['name'] as String? ?? '';
    final bytes = input['bytes'] as Uint8List? ?? Uint8List(0);
    final names = _namesFromBytes(bytes);
    final base = p.basenameWithoutExtension(name);
    final aliases = <String>{...names, base}
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
    result.add(<String, Object>{
      'file': name,
      'path': input['path'] as String? ?? '',
      'size': input['size'] as int? ?? 0,
      'modified': input['modified'] as String? ?? '',
      'family': names.isNotEmpty ? names.first : base,
      'aliases': aliases,
    });
  }
  return result;
}

List<String> _namesFromBytes(Uint8List bytes) {
  if (bytes.length < 12) {
    return const [];
  }
  final tag = String.fromCharCodes(bytes.sublist(0, 4));
  final names = <String>[];
  if (tag == 'ttcf') {
    final count = _byteU32(bytes, 8);
    if (count <= 0 || count > 64 || bytes.length < 12 + 4 * count) {
      return const [];
    }
    for (var i = 0; i < count; i++) {
      names.addAll(_faceNamesFromBytes(bytes, _byteU32(bytes, 12 + 4 * i)));
    }
  } else {
    names.addAll(_faceNamesFromBytes(bytes, 0));
  }
  return names.toSet().toList(growable: false);
}

List<String> _faceNamesFromBytes(Uint8List bytes, int base) {
  if (bytes.length < base + 12) {
    return const [];
  }
  final numTables = _byteU16(bytes, base + 4);
  if (numTables <= 0 || numTables > 512) {
    return const [];
  }
  final directoryEnd = base + 12 + 16 * numTables;
  if (bytes.length < directoryEnd) {
    return const [];
  }
  var nameOffset = 0;
  var nameLength = 0;
  for (var i = 0; i < numTables; i++) {
    final record = base + 12 + 16 * i;
    final tag = String.fromCharCodes(bytes.sublist(record, record + 4));
    if (tag == 'name') {
      nameOffset = _byteU32(bytes, record + 8);
      nameLength = _byteU32(bytes, record + 12);
      break;
    }
  }
  if (nameOffset <= 0 || nameLength <= 0 || nameLength > 2 * 1024 * 1024) {
    return const [];
  }
  return _parseNameTableBytes(bytes, nameOffset, nameLength);
}

List<String> _parseNameTableBytes(Uint8List data, int offset, int length) {
  if (offset + 6 > data.length) {
    return const [];
  }
  final count = _byteU16(data, offset + 2);
  final stringOffset = _byteU16(data, offset + 4);
  if (count <= 0 || count > 4096) {
    return const [];
  }
  final end = (offset + length).clamp(0, data.length);
  final names = <String>{};
  for (var i = 0; i < count; i++) {
    final record = offset + 6 + 12 * i;
    if (record + 12 > end) {
      break;
    }
    final platform = _byteU16(data, record);
    final nameId = _byteU16(data, record + 6);
    final nameLength = _byteU16(data, record + 8);
    final nameOffset = _byteU16(data, record + 10);
    if (nameId != 1 &&
        nameId != 4 &&
        nameId != 6 &&
        nameId != 16 &&
        nameId != 17) {
      continue;
    }
    final start = offset + stringOffset + nameOffset;
    final stop = start + nameLength;
    if (start < 0 || stop > end || stop > data.length || nameLength == 0) {
      continue;
    }
    final text = _decodeNameBytes(data, start, nameLength, platform);
    final trimmed = text.replaceAll(RegExp(r'[\x00-\x1F]'), '').trim();
    if (trimmed.isNotEmpty) {
      names.add(trimmed);
    }
  }
  return names.toList();
}

String _decodeNameBytes(
    Uint8List data, int start, int length, int platform) {
  try {
    if (platform == 0) {
      final units = <int>[];
      for (var i = 0; i + 1 < length; i += 2) {
        units.add((data[start + i] << 8) | data[start + i + 1]);
      }
      return String.fromCharCodes(units);
    }
    if (platform == 3) {
      final units = <int>[];
      for (var i = 0; i + 1 < length; i += 2) {
        units.add(data[start + i] | (data[start + i + 1] << 8));
      }
      return String.fromCharCodes(units);
    }
    return String.fromCharCodes(data.sublist(start, start + length));
  } catch (_) {
    return '';
  }
}

int _byteU16(Uint8List data, int offset) {
  if (offset < 0 || offset + 2 > data.length) {
    return 0;
  }
  return (data[offset] << 8) | data[offset + 1];
}

int _byteU32(Uint8List data, int offset) {
  if (offset < 0 || offset + 4 > data.length) {
    return 0;
  }
  return (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];
}

class _FontReader {
  _FontReader(this._iterator);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = <int>[];
  static const int _maxBytes = 6 * 1024 * 1024;
  bool _done = false;

  Uint8List get bytes => Uint8List.fromList(_buffer);

  Future<bool> ensure(int end) async {
    while (_buffer.length < end && !_done && _buffer.length < _maxBytes) {
      final hasNext = await _iterator.moveNext().timeout(
            const Duration(seconds: 20),
            onTimeout: () => false,
          );
      if (!hasNext) {
        _done = true;
        break;
      }
      _buffer.addAll(_iterator.current);
    }
    return _buffer.length >= end;
  }
}

/// 用户取消建索引时抛出，由后台任务捕获。
class FontIndexCancelled implements Exception {
  const FontIndexCancelled();
}
