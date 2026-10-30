// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/track_matching.dart';

void main() {
  const video =
      'Spider-Man.Brand.New.Day.2026.iTA-ENG.Bluray.2160p.HEVC.HDR.x265-CYBER.mkv';
  const psa =
      'Spider-Man.Brand.New.Day.2026.1080p.10bit.WEBRip.6CH.x265.HEVC-PSA.chs&eng.ass';
  const dks = 'CHS.Spider-Man.Brand.New.Day.2026.1080p.TELESYNC.x264-DKS.ass';
  const srt = '蜘蛛侠：崭新之日 Spider-Man_ Brand New Day (2026).srt';

  group('parseReleaseName', () {
    test('剥掉发布参数和技术标记', () {
      final parts = parseReleaseName(video);
      expect(parts.title, contains('spider'));
      expect(parts.title, contains('2026'));
      expect(parts.title, isNot(contains('2160p')));
      expect(parts.title, isNot(contains('bluray')));
      expect(parts.technical, contains('2160p'));
      expect(parts.technical, contains('x265'));
    });

    test('方括号里的组名不参与标题比较', () {
      final parts = parseReleaseName(
        '[Airota&VCB-Studio] Majo no Tabitabi [02][Ma10p_1080p][x265_flac].mkv',
      );
      expect(parts.title, isNot(contains('vcb')));
      expect(parts.title, contains('majo'));
    });
  });

  group('titleSimilarity', () {
    test('同片不同压制也能匹配', () {
      expect(titleSimilarity(video, psa), greaterThan(0.55));
    });

    test('同名转写的中文标题能匹配', () {
      expect(titleSimilarity(video, srt), greaterThan(0.5));
    });

    test('完全不同的片名不匹配', () {
      expect(
        titleSimilarity(video, 'Frieren.Beyond.Journeys.End.01.1080p.ass'),
        lessThan(0.2),
      );
    });
  });

  group('technicalOverlap', () {
    test('同编码的压制更容易匹配当前视频', () {
      expect(
        technicalOverlap(video, psa),
        greaterThan(technicalOverlap(video, dks)),
      );
    });
  });

  group('episodesConflict', () {
    test('不同集数冲突', () {
      expect(
        episodesConflict(
          '[VCB-Studio] Show [02][Ma10p_1080p][x265_flac].mkv',
          '[VCB-Studio] Show [03][Ma10p_1080p][x265_flac].sc.ass',
        ),
        isTrue,
      );
    });

    test('电影没有集数时不冲突', () {
      expect(episodesConflict(video, psa), isFalse);
    });
  });
}
