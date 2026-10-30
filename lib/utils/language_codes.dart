// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

/// 语言代码映射：bgm 的中文描述、国家/地区、文件名标记 → ISO 639-1。
///
/// 纯函数，不依赖 Flutter/Hive，方便单独测试。
library;

/// bgm 的「语言」写法 → ISO 639-1。
const Map<String, String> _languageTextToCode = {
  '英语': 'en',
  '英文': 'en',
  'english': 'en',
  '日语': 'ja',
  '日文': 'ja',
  '日本语': 'ja',
  'japanese': 'ja',
  '汉语': 'zh',
  '中文': 'zh',
  '普通话': 'zh',
  '汉语普通话': 'zh',
  '国语': 'zh',
  'chinese': 'zh',
  '粤语': 'zh',
  '粵語': 'zh',
  'cantonese': 'zh',
  '韩语': 'ko',
  '朝鲜语': 'ko',
  'korean': 'ko',
  '法语': 'fr',
  'french': 'fr',
  '德语': 'de',
  'german': 'de',
  '意大利语': 'it',
  'italian': 'it',
  '西班牙语': 'es',
  'spanish': 'es',
  '俄语': 'ru',
  'russian': 'ru',
  '葡萄牙语': 'pt',
  'portuguese': 'pt',
  '泰语': 'th',
  'thai': 'th',
  '印地语': 'hi',
  'hindi': 'hi',
  '阿拉伯语': 'ar',
  'arabic': 'ar',
  '土耳其语': 'tr',
  'turkish': 'tr',
  '波兰语': 'pl',
  'polish': 'pl',
  '荷兰语': 'nl',
  'dutch': 'nl',
  '瑞典语': 'sv',
  'swedish': 'sv',
  '丹麦语': 'da',
  'danish': 'da',
  '挪威语': 'no',
  'norwegian': 'no',
  '芬兰语': 'fi',
  'finnish': 'fi',
  '越南语': 'vi',
  'vietnamese': 'vi',
  '印尼语': 'id',
  'indonesian': 'id',
};

/// 国家/地区 → 主要语言（只在「语言」字段缺失时兜底）。
const Map<String, String> _countryToCode = {
  '美国': 'en',
  '英国': 'en',
  '加拿大': 'en',
  '澳大利亚': 'en',
  '新西兰': 'en',
  '爱尔兰': 'en',
  '日本': 'ja',
  '中国大陆': 'zh',
  '中国': 'zh',
  '香港': 'zh',
  '澳门': 'zh',
  '台湾': 'zh',
  '韩国': 'ko',
  '朝鲜': 'ko',
  '法国': 'fr',
  '德国': 'de',
  '意大利': 'it',
  '西班牙': 'es',
  '墨西哥': 'es',
  '阿根廷': 'es',
  '巴西': 'pt',
  '葡萄牙': 'pt',
  '俄罗斯': 'ru',
  '印度': 'hi',
  '泰国': 'th',
  '土耳其': 'tr',
  '波兰': 'pl',
  '荷兰': 'nl',
  '瑞典': 'sv',
  '丹麦': 'da',
  '挪威': 'no',
  '芬兰': 'fi',
  '越南': 'vi',
  '印度尼西亚': 'id',
};

/// 文件名里常见的语言标记 → ISO 639-1。
const Map<String, String> _filenameTagToCode = {
  'eng': 'en',
  'en': 'en',
  'english': 'en',
  'jpn': 'ja',
  'jp': 'ja',
  'ja': 'ja',
  'japanese': 'ja',
  'chi': 'zh',
  'zho': 'zh',
  'zh': 'zh',
  'chs': 'zh',
  'cht': 'zh',
  'sc': 'zh',
  'tc': 'zh',
  'ita': 'it',
  'it': 'it',
  'kor': 'ko',
  'ko': 'ko',
  'fre': 'fr',
  'fra': 'fr',
  'fr': 'fr',
  'ger': 'de',
  'deu': 'de',
  'de': 'de',
  'spa': 'es',
  'es': 'es',
  'rus': 'ru',
  'ru': 'ru',
  'por': 'pt',
  'pt': 'pt',
  'tha': 'th',
  'th': 'th',
  'hin': 'hi',
  'hi': 'hi',
  'ara': 'ar',
  'ar': 'ar',
  'vie': 'vi',
  'ind': 'id',
  'tur': 'tr',
  'pol': 'pl',
  'swe': 'sv',
  'nor': 'no',
  'dan': 'da',
  'fin': 'fi',
};

/// 把 `eng` / `jpn` / `zh-CN` 之类统一成两位代码。
String normalizeLanguageCode(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  if (value.isEmpty) {
    return '';
  }
  final base = value.split(RegExp(r'[-_]')).first;
  if (_filenameTagToCode.containsKey(base)) {
    return _filenameTagToCode[base]!;
  }
  if (base == 'zh') {
    return 'zh';
  }
  return base;
}

/// bgm infobox 里的中文语言名 → 代码。
String? languageCodeFromText(String? text) {
  final value = (text ?? '').trim();
  if (value.isEmpty) {
    return null;
  }
  final lower = value.toLowerCase();
  for (final entry in _languageTextToCode.entries) {
    if (lower.contains(entry.key)) {
      return entry.value;
    }
  }
  return null;
}

/// bgm infobox 的「国家/地区」→ 代码。
String? languageCodeFromCountry(String? text) {
  final value = (text ?? '').trim();
  if (value.isEmpty) {
    return null;
  }
  for (final entry in _countryToCode.entries) {
    if (value.contains(entry.key)) {
      return entry.value;
    }
  }
  return null;
}

/// 从文件名里按出现顺序抽出语言标记，例如
/// `Spider-Man...iTA-ENG.Bluray...` → `['it', 'en']`。
List<String> filenameLanguageCodes(String name) {
  final parts = name
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((part) => part.isNotEmpty);
  final result = <String>[];
  for (final part in parts) {
    final code = _filenameTagToCode[part];
    if (code != null && !result.contains(code)) {
      result.add(code);
    }
  }
  return result;
}

/// 动画（type 2）用标签判断国产，其余按日语。
String? animationLanguageFromTags(Iterable<String> tags) {
  const chineseMarkers = ['国产', '国创', '中国', '大陆'];
  for (final tag in tags) {
    for (final marker in chineseMarkers) {
      if (tag.contains(marker)) {
        return 'zh';
      }
    }
  }
  return 'ja';
}

/// 解析 bgm 条目详情里的 `infobox`：
///
/// * `api.bgm.tv/v0` 用 `{"key": "语言", "value": "英语"}`；
/// * `next.bgm.tv/p1` 用 `{"key": "语言", "values": [{"v": "英语"}]}`。
String? parseSubjectLanguageJson(dynamic json) {
  if (json is! Map) {
    return null;
  }
  final infobox = json['infobox'];
  if (infobox is! List) {
    return null;
  }

  String? languageText;
  String? countryText;
  for (final field in infobox) {
    if (field is! Map) {
      continue;
    }
    final key = '${field['key'] ?? ''}';
    if (key != '语言' && key != '对白语言' && key != '国家/地区' && key != '地区') {
      continue;
    }
    final texts = <String>[];
    final value = field['value'];
    if (value is String && value.trim().isNotEmpty) {
      texts.add(value.trim());
    }
    final values = field['values'];
    if (values is List) {
      for (final item in values) {
        if (item is Map && item['v'] != null) {
          final text = '${item['v']}'.trim();
          if (text.isNotEmpty) {
            texts.add(text);
          }
        }
      }
    }
    if (texts.isEmpty) {
      continue;
    }
    if (key == '语言' || key == '对白语言') {
      languageText ??= texts.first;
    } else {
      countryText ??= texts.first;
    }
  }

  return languageCodeFromText(languageText) ??
      languageCodeFromCountry(countryText);
}
