import 'dart:convert';

import 'package:kazumi/utils/app_variant.dart';

/// 仓库根目录 `update.json` 里的一个安装包条目。
class AppReleaseAsset {
  const AppReleaseAsset({
    required this.variant,
    required this.fileName,
    required this.url,
    required this.sha256,
    required this.size,
  });

  /// `replace` 或 `coexist`。
  final String variant;
  final String fileName;
  final String url;
  final String sha256;
  final int size;

  bool get isCoexist => variant == AppVariant.coexist.name;

  @override
  String toString() =>
      'AppReleaseAsset($variant, $fileName, ${size}B, ${sha256.substring(0, 8)}…)';
}

/// 本仓库 Release 的更新清单。
///
/// 不查 GitHub API：`api.github.com` 在国内经常被限流或直接连不通，
/// 所以把版本信息写成仓库里的静态 JSON，App 端走 raw / jsDelivr 拉。
class AppReleaseManifest {
  const AppReleaseManifest({
    required this.schema,
    required this.version,
    required this.build,
    required this.tag,
    required this.publishedAt,
    required this.notes,
    required this.releaseUrl,
    required this.assets,
  });

  static const int supportedSchema = 1;

  final int schema;

  /// 版本名，例如 `2.3.9`（对应 pubspec `version:` 的 `+` 前部分）。
  final String version;

  /// 构建号，例如 `20313`（对应 pubspec `version:` 的 `+` 后部分）。
  final int build;

  final String tag;
  final String publishedAt;

  /// 弹窗里显示的更新说明。
  final String notes;

  /// Release 页面地址，下载失败或没有对应包型时跳这里。
  final String releaseUrl;

  final List<AppReleaseAsset> assets;

  String get displayVersion => '$version ($build)';

  /// 解析清单；字段缺失或格式不对都抛 [FormatException]，方便上层统一提示。
  static AppReleaseManifest parse(String raw) {
    final decoded = jsonDecodeMap(raw);
    final schema = _asInt(decoded['schema'], 'schema');
    if (schema != supportedSchema) {
      throw FormatException('更新清单版本不支持：$schema');
    }

    final version = _asString(decoded['version'], 'version');
    if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(version)) {
      throw FormatException('更新清单版本号不合法：$version');
    }

    final build = _asInt(decoded['build'], 'build');
    if (build <= 0) {
      throw FormatException('更新清单 build 号不合法：$build');
    }

    final rawAssets = decoded['assets'];
    if (rawAssets is! List || rawAssets.isEmpty) {
      throw const FormatException('更新清单缺少 assets');
    }

    final assets = <AppReleaseAsset>[];
    for (final item in rawAssets) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('更新清单 assets 格式错误');
      }
      assets.add(_parseAsset(item));
    }

    return AppReleaseManifest(
      schema: schema,
      version: version,
      build: build,
      tag: _asString(decoded['tag'] ?? '', 'tag', allowEmpty: true),
      publishedAt:
          _asString(decoded['publishedAt'] ?? '', 'publishedAt', allowEmpty: true),
      notes: _asString(decoded['notes'] ?? '', 'notes', allowEmpty: true),
      releaseUrl:
          _asString(decoded['releaseUrl'] ?? '', 'releaseUrl', allowEmpty: true),
      assets: assets,
    );
  }

  static AppReleaseAsset _parseAsset(Map<String, dynamic> json) {
    final variant = _asString(json['variant'], 'assets.variant');
    if (variant != AppVariant.replace.name && variant != AppVariant.coexist.name) {
      throw FormatException('更新清单 assets.variant 不合法：$variant');
    }

    final fileName = _asString(json['file'], 'assets.file');
    final url = _asString(json['url'], 'assets.url');
    if (!url.startsWith('https://')) {
      throw FormatException('更新清单 assets.url 必须是 https：$url');
    }

    final sha256 = _asString(json['sha256'], 'assets.sha256').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw FormatException('更新清单 assets.sha256 不合法：$sha256');
    }

    return AppReleaseAsset(
      variant: variant,
      fileName: fileName,
      url: url,
      sha256: sha256,
      size: json['size'] == null ? 0 : _asInt(json['size'], 'assets.size'),
    );
  }

  /// 按当前安装的变体取安装包：先看 `variant` 字段，再退回文件名里的 `coexist` 标记。
  AppReleaseAsset? assetForVariant(AppVariant variant) {
    for (final asset in assets) {
      if (asset.variant == variant.name) {
        return asset;
      }
    }
    final wantCoexist = variant == AppVariant.coexist;
    for (final asset in assets) {
      if (asset.fileName.toLowerCase().contains('coexist') == wantCoexist) {
        return asset;
      }
    }
    return null;
  }

  static Map<String, dynamic> jsonDecodeMap(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('更新清单不是 JSON 对象');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static String _asString(Object? value, String field, {bool allowEmpty = false}) {
    if (value is! String) {
      throw FormatException('更新清单字段缺失：$field');
    }
    if (!allowEmpty && value.trim().isEmpty) {
      throw FormatException('更新清单字段为空：$field');
    }
    return value;
  }

  static int _asInt(Object? value, String field) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    throw FormatException('更新清单字段不是整数：$field');
  }

  @override
  String toString() => 'AppReleaseManifest($displayVersion, ${assets.length} assets)';
}
