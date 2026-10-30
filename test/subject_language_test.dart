// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/bangumi/subject_language.dart';

void main() {
  group('parseSubjectLanguageJson', () {
    test('bgm v0 的 value 写法', () {
      final json = {
        'infobox': [
          {'key': '国家/地区', 'value': '美国'},
          {'key': '语言', 'value': '英语'},
        ],
      };
      expect(parseSubjectLanguageJson(json), 'en');
    });

    test('bgm p1 的 values 写法', () {
      final json = {
        'infobox': [
          {
            'key': '语言',
            'values': [
              {'v': '日语'},
            ],
          },
        ],
      };
      expect(parseSubjectLanguageJson(json), 'ja');
    });

    test('只有国家时用国家兜底', () {
      final json = {
        'infobox': [
          {
            'key': '国家/地区',
            'values': [
              {'v': '中国大陆'},
            ],
          },
        ],
      };
      expect(parseSubjectLanguageJson(json), 'zh');
    });

    test('动画条目没有语言字段', () {
      final json = {
        'infobox': [
          {'key': '话数', 'value': '12'},
          {'key': '放送开始', 'value': '2026年10月3日'},
        ],
      };
      expect(parseSubjectLanguageJson(json), isNull);
    });
  });

  group('filenameLanguageCodes', () {
    test('iTA-ENG 多音轨', () {
      expect(
        filenameLanguageCodes(
          'Spider-Man.Brand.New.Day.2026.iTA-ENG.Bluray.2160p.HEVC.HDR.x265-CYBER.mkv',
        ),
        ['it', 'en'],
      );
    });

    test('没有语言标记时为空', () {
      expect(filenameLanguageCodes('Show.01.1080p.mkv'), isEmpty);
    });
  });

  group('animationLanguageFromTags', () {
    test('国产动画判中文', () {
      expect(animationLanguageFromTags(['国产', '玄幻']), 'zh');
    });

    test('其余按日语', () {
      expect(animationLanguageFromTags(['漫画改', '2026年10月']), 'ja');
    });
  });

  group('normalizeLanguageCode', () {
    test('三字母转两字母', () {
      expect(normalizeLanguageCode('jpn'), 'ja');
      expect(normalizeLanguageCode('eng'), 'en');
      expect(normalizeLanguageCode('chi'), 'zh');
      expect(normalizeLanguageCode('zh-CN'), 'zh');
    });
  });
}
