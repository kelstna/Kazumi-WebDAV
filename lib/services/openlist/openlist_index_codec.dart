// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

// 纯 Dart（不 import Flutter），便于用独立 dart 脚本验证解析/编码的边界情况。

import 'dart:convert';

/// 目录索引快照里的一个目录（只存搜索要用的三样）。
class OpenListIndexFolder {
  const OpenListIndexFolder({
    required this.name,
    required this.path,
    required this.modified,
  });

  final String name;
  final String path;
  final String modified;
}

/// 缓存格式版本：改了字段就 +1，旧快照会被判定失效并回退实时扫描。
const int openListIndexFormatVersion = 1;

String encodeOpenListIndex({
  required String key,
  required List<OpenListIndexFolder> folders,
  required DateTime savedAt,
}) {
  return jsonEncode({
    'version': openListIndexFormatVersion,
    'key': key,
    'savedAt': savedAt.toIso8601String(),
    'folders': [
      for (final folder in folders)
        {
          'name': folder.name,
          'path': folder.path,
          'modified': folder.modified,
        },
    ],
  });
}

class DecodedOpenListIndex {
  const DecodedOpenListIndex({required this.folders, required this.savedAt});

  final List<OpenListIndexFolder> folders;
  final DateTime savedAt;
}

/// 解析磁盘快照。版本不符 / key 不符 / JSON 损坏 / 没有有效条目
/// 一律返回 null，调用方据此回退到实时扫描。
DecodedOpenListIndex? decodeOpenListIndex(String raw, {required String key}) {
  if (raw.isEmpty) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) {
    return null;
  }
  if (decoded['version'] != openListIndexFormatVersion) {
    return null;
  }
  if (decoded['key'] != key) {
    return null;
  }
  final savedAt = DateTime.tryParse('${decoded['savedAt']}');
  final items = decoded['folders'];
  if (savedAt == null || items is! List) {
    return null;
  }
  final folders = <OpenListIndexFolder>[];
  for (final item in items) {
    if (item is! Map) {
      continue;
    }
    final name = item['name'];
    final path = item['path'];
    if (name is! String || path is! String || path.isEmpty) {
      continue;
    }
    final modified = item['modified'];
    folders.add(OpenListIndexFolder(
      name: name,
      path: path,
      modified: modified is String ? modified : '',
    ));
  }
  if (folders.isEmpty) {
    return null;
  }
  return DecodedOpenListIndex(folders: folders, savedAt: savedAt);
}
