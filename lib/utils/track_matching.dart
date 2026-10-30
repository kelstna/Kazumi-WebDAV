// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

/// 文件名解析：把「视频名 / 字幕名」拆成标题词和技术标记。
///
/// 用途只有一个——判断同目录的字幕到底是不是当前这部的：
/// 常见发布组会给同一部片套上 `2160p/1080p`、`BluRay/WEBRip`、`x265/HEVC`
/// 这些不同参数，直接比较文件名永远不相等，只能比较「标题词」。
library;

import 'package:kazumi/utils/episode_number.dart';

/// 发布参数：判断相似度时剔除，做「技术标记重合度」时保留。
const Set<String> _technicalTokens = {
  // 分辨率 / 位深
  '480p', '576p', '720p', '1080p', '1440p', '2160p', '4k', '8k', '2k',
  '8bit', '10bit', '12bit',
  // 片源
  'web', 'webrip', 'webdl', 'web-dl', 'bluray', 'blu-ray', 'bdrip', 'bd',
  'hdtv', 'dvdrip', 'dvd', 'remux', 'telesync', 'ts', 'cam', 'hdcam',
  'repack', 'proper', 'imax',
  // 编码
  'x264', 'x265', 'h264', 'h265', 'avc', 'hevc', 'av1', 'vp9',
  // 音频
  'aac', 'ac3', 'eac3', 'ddp', 'ddp5', 'dd', 'dts', 'flac', 'truehd',
  'atmos', 'opus', '6ch', '2ch', '8ch', '5ch',
  // 画面
  'hdr', 'hdr10', 'dv', 'sdr',
  // 语言/字幕标记
  'chs', 'cht', 'sc', 'tc', 'gb', 'big5', 'jpsc', 'jptc', 'zh', 'chi',
  'zho', 'eng', 'jpn', 'jp', 'ita', 'kor', 'fre', 'fra', 'ger', 'deu',
  'spa', 'rus', 'por', 'tha', 'hin', 'ara',
  // 其它
  'multi', 'dual', 'audio', 'sub', 'subs', '简体', '繁体', '简', '繁',
};

/// 标题里没有信息量、但会干扰相似度的词。
const Set<String> _noiseTokens = {
  'the', 'a', 'an', 'and', 'of', 'to', 'in', 'on', 'no', 'end', 'fin',
};

class ReleaseNameParts {
  const ReleaseNameParts({required this.title, required this.technical});

  /// 去掉发布参数、语言标记、方括号组名之后的标题词（小写）。
  final List<String> title;

  /// 分辨率 / 片源 / 编码 / 音频等发布参数（小写）。
  final Set<String> technical;
}

String _stripExtension(String raw) {
  var value = raw.trim().toLowerCase();
  final dot = value.lastIndexOf('.');
  if (dot > 0 && value.length - dot <= 6) {
    value = value.substring(0, dot);
  }
  return value;
}

/// 方括号里一般是发布组名（`[VCB-Studio]`、`[LoliHouse]`），
/// 但也可能是集数（`[02]`）——集数由 `parseEpisodeNumber` 单独处理，
/// 这里整体去掉，避免组名把相似度拉低。
String _stripBracketedGroups(String value) {
  return value
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'【[^】]*】'), ' ');
}

ReleaseNameParts parseReleaseName(String raw) {
  final value = _stripBracketedGroups(_stripExtension(raw));
  final parts = value.split(RegExp(r'[^a-z0-9\u3040-\u30ff\u4e00-\u9fff]+'));
  final title = <String>[];
  final technical = <String>{};
  for (final part in parts) {
    if (part.isEmpty) {
      continue;
    }
    if (_technicalTokens.contains(part)) {
      technical.add(part);
      continue;
    }
    if (part.length == 1) {
      continue;
    }
    if (_noiseTokens.contains(part)) {
      continue;
    }
    if (!title.contains(part)) {
      title.add(part);
    }
  }
  return ReleaseNameParts(title: title, technical: technical);
}

/// 标题词 Jaccard 相似度，0.0 ~ 1.0。
double titleSimilarity(String a, String b) {
  final setA = parseReleaseName(a).title.toSet();
  final setB = parseReleaseName(b).title.toSet();
  if (setA.isEmpty || setB.isEmpty) {
    return 0;
  }
  final intersection = setA.intersection(setB).length;
  final union = setA.union(setB).length;
  return intersection / union;
}

/// 两边共有的发布参数数量：同片不同压制时用来挑「更贴近当前视频」的那条。
int technicalOverlap(String a, String b) {
  final setA = parseReleaseName(a).technical;
  final setB = parseReleaseName(b).technical;
  return setA.intersection(setB).length;
}

/// 两边都能解析出集数、且不相等 → 一定不是同一集。
bool episodesConflict(String a, String b) {
  final episodeA = parseEpisodeNumber(a);
  final episodeB = parseEpisodeNumber(b);
  if (episodeA == null || episodeB == null) {
    return false;
  }
  return episodeA != episodeB;
}
