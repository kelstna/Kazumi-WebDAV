// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  });

  final String file;
  final int size;
  final String family;
  final List<String> aliases;

  Map<String, dynamic> toJson() => {
        'file': file,
        'size': size,
        'family': family,
        'aliases': aliases,
      };

  factory WebDavFontFace.fromJson(Map<String, dynamic> json) {
    return WebDavFontFace(
      file: json['file'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
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
  }) async {
    final directory = normalizedDirectory;
    if (directory.isEmpty) {
      throw OpenListException('未设置 WebDAV 字体目录');
    }
    final files = await _collectFontEntries(directory);
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
      if (old != null && old.size == entry.size) {
        faces.add(old);
      } else {
        pending.add(entry);
      }
    }

    var done = faces.length;
    onProgress?.call(done, files.length);
    const batchSize = 4;
    for (var start = 0; start < pending.length; start += batchSize) {
      final batch = pending.skip(start).take(batchSize);
      final results = await Future.wait(batch.map(_readFace));
      for (final result in results) {
        faces.add(result);
      }
      done += results.length;
      onProgress?.call(done, files.length);
    }

    faces.sort((a, b) => a.file.toLowerCase().compareTo(b.file.toLowerCase()));
    final dir = await _baseDir();
    await _indexFile(dir).writeAsString(jsonEncode({
      'version': 1,
      'directory': directory,
      'builtAt': DateTime.now().toIso8601String(),
      'faces': faces.map((face) => face.toJson()).toList(),
    }), flush: true);
    KazumiLogger().i(
        'WebDavFontService: indexed ${faces.length} fonts in $directory');
    return faces.length;
  }

  /// 字体包经常按类型分子目录，这里做有限深度的递归扫描。
  Future<List<OpenListEntry>> _collectFontEntries(String root) async {
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
      } catch (error) {
        KazumiLogger().w(
          'WebDavFontService: failed to list $directory',
          error: error,
        );
        continue;
      }
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
      KazumiLogger().i('WebDavFontService: installed $installed fonts');
    }
    return installed;
  }

  Future<int> cacheBytes() async {
    final dir = await _baseDir();
    final cache = await _readCache(dir);
    final fontDir = await SubtitleFontService().directory();
    var total = 0;
    for (final file in cache.keys) {
      try {
        final stat = await File(p.join(fontDir.path, file)).stat();
        if (stat.type == FileSystemEntityType.file) {
          total += stat.size;
        }
      } catch (_) {
        // 文件被删了就忽略。
      }
    }
    return total;
  }

  Future<int> cacheCount() async {
    final dir = await _baseDir();
    return (await _readCache(dir)).length;
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
          .get(OpenListService.instance.uriFor('$normalizedDirectory/${face.file}'),
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

  Future<WebDavFontFace> _readFace(OpenListEntry entry) async {
    final names = await _readFontNames(entry.path);
    final family = names.isNotEmpty ? names.first : p.basenameWithoutExtension(entry.name);
    final aliases = <String>{...names, p.basenameWithoutExtension(entry.name)}
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
    return WebDavFontFace(
      file: entry.name,
      size: entry.size,
      family: family,
      aliases: aliases,
    );
  }

  Future<List<String>> _readFontNames(String path) async {
    final client = http.Client();
    StreamIterator<List<int>>? iterator;
    try {
      final request = http.Request('GET', OpenListService.instance.uriFor(path));
      request.headers.addAll(OpenListService.instance.authHeaders);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        return const [];
      }
      iterator = StreamIterator<List<int>>(response.stream);
      final reader = _FontReader(iterator);
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
          names.addAll(await _readFaceNames(reader, _u32(reader.bytes, 12 + 4 * i)));
        }
      } else {
        names.addAll(await _readFaceNames(reader, 0));
      }
      return names.toSet().toList(growable: false);
    } catch (error) {
      KazumiLogger()
          .w('WebDavFontService: failed to read names of $path', error: error);
      return const [];
    } finally {
      await iterator?.cancel();
      client.close();
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
