// 纯函数自检：更新清单解析、版本判定、变体选包。
// 用法（工程根目录）：
//   D:\dev\flutter\bin\dart.exe run tool\update_logic_check.dart
// 退出码 0 表示全部通过。
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/update/app_release_manifest.dart';
import 'package:kazumi/utils/app_variant.dart';
import 'package:kazumi/utils/version.dart';

var _failed = 0;

void check(String name, bool ok, [Object? detail]) {
  if (ok) {
    stdout.writeln('  ok   $name');
  } else {
    _failed++;
    stdout.writeln('  FAIL $name${detail == null ? '' : ' -> $detail'}');
  }
}

void expectThrows(String name, void Function() body) {
  try {
    body();
    check(name, false, '没有抛异常');
  } on FormatException catch (e) {
    check(name, true, e.message);
  }
}

const _shaReplace =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _shaCoexist =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

String _manifestJson({
  int schema = 1,
  String version = '2.3.9',
  Object build = 20313,
  List<Map<String, Object?>>? assets,
}) {
  return jsonEncode({
    'schema': schema,
    'version': version,
    'build': build,
    'tag': 'v2.3.9.20313',
    'publishedAt': '2026-10-30T05:00:00Z',
    'notes': '本次更新见 Release 页面',
    'releaseUrl': 'https://github.com/kelstna/Kazumi-WebDAV/releases/tag/v2.3.9.20313',
    'assets': assets ??
        [
          {
            'variant': 'replace',
            'file': 'Kazumi-2.3.9-20313-android-arm64.apk',
            'url': 'https://github.com/x/y/releases/download/t/a.apk',
            'sha256': _shaReplace,
            'size': 33607365,
          },
          {
            'variant': 'coexist',
            'file': 'Kazumi-2.3.9-20313-android-arm64-coexist.apk',
            'url': 'https://github.com/x/y/releases/download/t/b.apk',
            'sha256': _shaCoexist,
            'size': 33607377,
          },
        ],
  });
}

void main() {
  stdout.writeln('== 清单解析 ==');
  final manifest = AppReleaseManifest.parse(_manifestJson());
  check('build 解析', manifest.build == 20313, manifest.build);
  check('displayVersion', manifest.displayVersion == '2.3.9 (20313)',
      manifest.displayVersion);
  check('assets 数量', manifest.assets.length == 2, manifest.assets.length);
  check('replace 选包', manifest.assetForVariant(AppVariant.replace)?.variant == 'replace');
  check('coexist 选包', manifest.assetForVariant(AppVariant.coexist)?.variant == 'coexist');
  check(
    'replace 不会拿到 coexist',
    !(manifest.assetForVariant(AppVariant.replace)?.fileName.contains('coexist') ?? true),
  );

  expectThrows('schema 不支持', () => AppReleaseManifest.parse(_manifestJson(schema: 2)));
  expectThrows('版本号非法', () => AppReleaseManifest.parse(_manifestJson(version: 'v2.3.9')));
  expectThrows(
    'sha256 非法',
    () => AppReleaseManifest.parse(_manifestJson(assets: [
          {'variant': 'replace', 'file': 'a.apk', 'url': 'https://x/a.apk', 'sha256': 'zz', 'size': 1},
        ])),
  );
  expectThrows(
    'variant 非法',
    () => AppReleaseManifest.parse(_manifestJson(assets: [
          {'variant': 'debug', 'file': 'a.apk', 'url': 'https://x/a.apk', 'sha256': _shaReplace, 'size': 1},
        ])),
  );

  final onlyReplace = AppReleaseManifest.parse(_manifestJson(assets: [
    {'variant': 'replace', 'file': 'a.apk', 'url': 'https://x/a.apk', 'sha256': _shaReplace, 'size': 1},
  ]));
  check('只有替换版时共存版拿不到包', onlyReplace.assetForVariant(AppVariant.coexist) == null);

  stdout.writeln('== 版本判定 ==');
  bool need(String lv, int lb, String rv, int rb) => needUpdateForRelease(
        localVersion: lv,
        localBuild: lb,
        remoteVersion: rv,
        remoteBuild: rb,
      );
  check('20312 -> 20313 有更新', need('2.3.9', 20312, '2.3.9', 20313));
  check('20313 -> 20312 无更新', !need('2.3.9', 20313, '2.3.9', 20312));
  check('同版本无更新', !need('2.3.9', 20313, '2.3.9', 20313));
  check('2.3.9 -> 2.3.10 有更新', need('2.3.9', 99999, '2.3.10', 1));
  check('2.3.10 -> 2.3.9 无更新', !need('2.3.10', 1, '2.3.9', 99999));
  check('compareVersionNames 相等', compareVersionNames('2.3', '2.3.0') == 0);

  stdout.writeln('== 结果 ==');
  if (_failed == 0) {
    stdout.writeln('全部通过');
    exit(0);
  }
  stdout.writeln('失败 $_failed 项');
  exit(1);
}
