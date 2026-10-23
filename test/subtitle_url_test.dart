// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/subtitle/subtitle_repository.dart';
import 'package:kazumi/utils/episode_url.dart';

void main() {
  group('looksLikeDirectMediaUrl', () {
    test('accepts anime-server raw links', () {
      expect(
        looksLikeDirectMediaUrl('http://192.0.2.10:7006/raw/abc123.mkv'),
        isTrue,
      );
      expect(
        looksLikeDirectMediaUrl('http://192.0.2.10:7006/raw/abc123.MP4'),
        isTrue,
      );
    });

    test('rejects html episode pages', () {
      expect(looksLikeDirectMediaUrl('http://192.0.2.10:7006/play/abc123'),
          isFalse);
      expect(looksLikeDirectMediaUrl('https://example.com/ep/1'), isFalse);
      expect(looksLikeDirectMediaUrl('https://example.com/watch.html'), isFalse);
    });
  });

  group('videoIdFromUrl', () {
    test('strips directory and extension', () {
      expect(videoIdFromUrl('http://h:7006/raw/abc.mkv'), 'abc');
      expect(videoIdFromUrl('http://h:7006/play/abc'), 'abc');
      expect(videoIdFromUrl('http://h:7006/raw/abc'), 'abc');
    });
  });
}
