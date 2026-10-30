// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

/// 「这部作品的原声是什么语言」——供播放器自动选音轨用。
///
/// 数据来源分两层：
/// * Bangumi 条目（bgm.tv）的 `infobox`：真人影视（type 6）通常有
///   「语言」（如「英语」）和「国家/地区」（如「美国」）；
/// * 动画（type 2）没有这两个字段，用 tags 里的「国产 / 国创」判断，
///   其余按日语处理（绝大多数电视动画就是日语）。
///
/// 取不到就返回 null，播放器继续往下走「文件名标签 → 文件默认轨道」。
library;

import 'dart:convert';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/clients/bangumi_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/language_codes.dart';

export 'package:kazumi/utils/language_codes.dart';

/// 作品语言查询 + 缓存（内存 + 落盘 30 天）。
class SubjectLanguageService {
  SubjectLanguageService._();

  static final SubjectLanguageService instance = SubjectLanguageService._();

  static const Duration _ttl = Duration(days: 30);
  static const int _maxEntries = 200;

  final Map<int, _CachedLanguage> _memory = {};
  Map<String, _CachedLanguage>? _persisted;

  /// 不需要联网就能确定的情况：动画。
  String? localLanguageFor(BangumiItem item) {
    if (item.type == 2) {
      return animationLanguageFromTags(item.tags.map((tag) => tag.name));
    }
    return null;
  }

  /// 先查缓存（内存 → 落盘），没有就返回 null。
  String? cachedLanguage(int id) {
    final hit = _memory[id];
    if (hit != null && !hit.isExpired) {
      return hit.code;
    }
    final persisted = _loadPersisted();
    final stored = persisted['$id'];
    if (stored != null && !stored.isExpired) {
      _memory[id] = stored;
      return stored.code;
    }
    return null;
  }

  /// 联网取真人影视的语言；失败做负缓存，避免反复请求。
  Future<String?> resolve(
    int id, {
    int? type,
    Iterable<String> tags = const [],
  }) async {
    if (type == 2) {
      return animationLanguageFromTags(tags);
    }
    final cached = cachedLanguage(id);
    if (cached != null) {
      return cached;
    }
    try {
      final jsonData = await BangumiClient.instance.get(
        ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiInfoByIDNext,
          [id],
        ),
      );
      final code = parseSubjectLanguageJson(jsonData);
      _store(id, code);
      return code;
    } catch (error) {
      KazumiLogger().w(
        'SubjectLanguageService: failed to resolve subject $id',
        error: error,
      );
      _store(id, null);
      return null;
    }
  }

  void _store(int id, String? code) {
    final entry = _CachedLanguage(code: code, timestamp: DateTime.now());
    _memory[id] = entry;
    final persisted = _loadPersisted();
    persisted['$id'] = entry;
    if (persisted.length > _maxEntries) {
      final sorted = persisted.entries.toList()
        ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
      for (final item in sorted.take(persisted.length - _maxEntries)) {
        persisted.remove(item.key);
      }
    }
    _savePersisted(persisted);
  }

  Map<String, _CachedLanguage> _loadPersisted() {
    final cached = _persisted;
    if (cached != null) {
      return cached;
    }
    final map = <String, _CachedLanguage>{};
    try {
      final raw = GStorage.getSetting(SettingsKeys.subjectLanguageCache);
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((key, value) {
          if (value is Map) {
            map['$key'] = _CachedLanguage(
              code: value['code'] as String?,
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                (value['t'] as num?)?.toInt() ?? 0,
              ),
            );
          }
        });
      }
    } catch (_) {
      // 缓存损坏就当作空，不影响播放。
    }
    _persisted = map;
    return map;
  }

  void _savePersisted(Map<String, _CachedLanguage> map) {
    try {
      GStorage.putSetting<String>(
        SettingsKeys.subjectLanguageCache,
        jsonEncode(map.map(
          (key, value) => MapEntry(
            key,
            {'code': value.code, 't': value.timestamp.millisecondsSinceEpoch},
          ),
        )),
      );
    } catch (_) {
      // 忽略写盘失败。
    }
  }
}

class _CachedLanguage {
  const _CachedLanguage({required this.code, required this.timestamp});

  final String? code;
  final DateTime timestamp;

  bool get isExpired =>
      DateTime.now().difference(timestamp) > SubjectLanguageService._ttl;
}
