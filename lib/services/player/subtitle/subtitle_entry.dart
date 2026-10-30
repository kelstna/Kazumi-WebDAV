// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:media_kit/media_kit.dart';

/// 字幕来源：视频容器内封 / 同目录或服务器外挂
enum SubtitleEntryKind { embedded, external }

/// 播放器字幕列表里的一项。
///
/// [id] 内封时是 mpv 的轨道 id，外挂时是本地文件的绝对路径。
class SubtitleEntry {
  const SubtitleEntry({
    required this.id,
    required this.title,
    required this.kind,
    this.rawTitle,
    this.language,
    this.codec,
    this.uri,
    this.image = false,
    this.forced = false,
  });

  factory SubtitleEntry.fromTrack(SubtitleTrack track) {
    final codec = (track.codec ?? '').toLowerCase();
    return SubtitleEntry(
      id: track.id,
      title: subtitleTrackLabel(track),
      rawTitle: track.title,
      kind: SubtitleEntryKind.embedded,
      language: track.language,
      codec: track.codec,
      image: isBitmapSubtitleCodec(codec),
    );
  }

  final String id;
  final String title;
  final SubtitleEntryKind kind;

  /// 字幕文件/容器里的原始标题（不经过中文化），用于语言匹配。
  final String? rawTitle;
  final String? language;
  final String? codec;

  /// 外挂字幕的本地文件路径。
  final String? uri;

  /// 图形字幕（PGS/VobSub），libass 不能改字体样式。
  final bool image;

  /// 强制字幕（只翻译外语对白），自动选择时跳过。
  final bool forced;

  bool get isEmbedded => kind == SubtitleEntryKind.embedded;

  bool get isExternal => kind == SubtitleEntryKind.external;

  SubtitleEntry copyWith({bool? image, bool? forced, String? title}) {
    return SubtitleEntry(
      id: id,
      title: title ?? this.title,
      kind: kind,
      rawTitle: rawTitle,
      language: language,
      codec: codec,
      uri: uri,
      image: image ?? this.image,
      forced: forced ?? this.forced,
    );
  }

  SubtitleTrack toTrack() {
    if (isExternal) {
      final path = uri ?? id;
      return SubtitleTrack.uri(
        Uri.file(path).toString(),
        title: title,
        language: language ?? 'auto',
      );
    }
    return SubtitleTrack(id, title, language);
  }
}

const Set<String> kSubtitleFileExtensions = {
  '.ass',
  '.ssa',
  '.srt',
  '.vtt',
  '.webvtt',
  '.sub',
  '.idx',
  '.sup',
  '.smi',
  '.sami',
  '.ttml',
  '.dfxp',
  '.lrc',
};

bool isSubtitleFileName(String name) {
  final lower = name.toLowerCase();
  return kSubtitleFileExtensions.any(lower.endsWith);
}

bool isBitmapSubtitleCodec(String codec) {
  return codec.contains('pgs') ||
      codec.contains('hdmv') ||
      codec.contains('dvd_subtitle') ||
      codec.contains('dvb_subtitle') ||
      codec.contains('vobsub') ||
      codec.contains('xsub');
}

const Map<String, String> _languageLabels = {
  'chi': '简体中文',
  'zho': '中文',
  'zh': '中文',
  'chs': '简体中文',
  'cht': '繁體中文',
  'zh-cn': '简体中文',
  'zh-sg': '简体中文',
  'zh-tw': '繁體中文',
  'zh-hk': '繁體中文',
  'zh-hans': '简体中文',
  'zh-hant': '繁體中文',
  'sc': '简体中文',
  'tc': '繁體中文',
  'jpn': '日语',
  'ja': '日语',
  'jp': '日语',
  'eng': '英语',
  'en': '英语',
  'kor': '韩语',
  'ko': '韩语',
  'ita': '意大利语',
  'it': '意大利语',
  'fre': '法语',
  'fra': '法语',
  'fr': '法语',
  'ger': '德语',
  'deu': '德语',
  'de': '德语',
  'spa': '西班牙语',
  'es': '西班牙语',
  'rus': '俄语',
  'ru': '俄语',
  'por': '葡萄牙语',
  'pt': '葡萄牙语',
  'und': '未知',
  'mul': '多语言',
};

/// 把 ISO 639-1/2 或常见压制组写法换成中文标签。
String subtitleLanguageLabel(String? language, {String fallback = ''}) {
  final raw = (language ?? '').trim();
  if (raw.isEmpty) {
    return fallback;
  }
  return _languageLabels[raw.toLowerCase()] ?? raw;
}

/// 内封轨道的展示名，例如「简体中文 · ASS」「评论音轨」。
String subtitleTrackLabel(SubtitleTrack track) {
  final parts = <String>[];
  final title = (track.title ?? '').trim();
  final language = subtitleLanguageLabel(track.language);
  final codec = (track.codec ?? '').trim().toUpperCase();

  if (title.isNotEmpty &&
      title.toLowerCase() != (track.language ?? '').toLowerCase() &&
      title != language) {
    parts.add(title);
  }
  if (language.isNotEmpty && language != title) {
    parts.add(language);
  }
  if (codec.isNotEmpty) {
    parts.add(codec);
  }
  if (parts.isEmpty) {
    parts.add('字幕 ${track.id}');
  }
  return parts.join(' · ');
}
