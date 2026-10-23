// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

/// 从番剧文件名里解析集数，用于「按集数显示」。
///
/// 参考 anime-server 的 aniparse 方案，但这里是纯 Dart 的轻量实现：
/// 覆盖常见的 `SxxEyy`、`第N集`、` - 12 `、`[05]`、`EP12` 等写法，
/// 并排除 1080/720 这类分辨率数字。
library;

const Set<int> _ignoredNumbers = {
  480,
  576,
  720,
  1080,
  1440,
  2160,
  264,
  265,
};

final List<RegExp> _patterns = [
  // S06E02 / S2 E12
  RegExp(r'[Ss]\d{1,2}[ ._-]*[Ee](\d{1,4})'),
  // 第12集 / 第 12 话 / 第十二話
  RegExp(r'第\s*(\d{1,4})\s*[集话話]'),
  // [05] / （12）
  RegExp(r'[\[\(（]\s*(\d{1,4})(?:v\d)?\s*[\]\)）]'),
  // " - 171 " / "- 05."
  RegExp(r'[-–—]\s*(\d{1,4})(?=\s*[\[\(（._ ]|\s*$)'),
  // EP12 / E12
  RegExp(r'\bEP?\.?\s*(\d{1,4})\b', caseSensitive: false),
  // 12 END / 12 完
  RegExp(r'(\d{1,4})\s*(?:END|Fin|完)', caseSensitive: false),
];

/// 解析不到返回 null。
int? parseEpisodeNumber(String rawName) {
  var name = rawName.trim();
  if (name.isEmpty) {
    return null;
  }
  // 去掉扩展名
  final dot = name.lastIndexOf('.');
  if (dot > 0 && name.length - dot <= 6) {
    name = name.substring(0, dot);
  }
  for (final pattern in _patterns) {
    final match = pattern.firstMatch(name);
    if (match == null) {
      continue;
    }
    final value = int.tryParse(match.group(1) ?? '');
    if (value == null || value <= 0 || value > 5000) {
      continue;
    }
    if (_ignoredNumbers.contains(value)) {
      continue;
    }
    return value;
  }
  return null;
}

/// 「第N集」；解析不到时返回原文件名。
String episodeDisplayName(String rawName) {
  final number = parseEpisodeNumber(rawName);
  if (number == null) {
    return rawName;
  }
  return '第$number集';
}
