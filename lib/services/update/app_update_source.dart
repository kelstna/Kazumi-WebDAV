import 'package:kazumi/request/clients/download_http_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/update/app_release_manifest.dart';

class AppUpdateSourceException implements Exception {
  const AppUpdateSourceException(this.reason);

  final String reason;

  @override
  String toString() => '更新清单获取失败：$reason';
}

/// 拉取本仓库的更新清单，多个地址按顺序回退。
class AppUpdateSource {
  AppUpdateSource({List<String>? urls}) : urls = urls ?? defaultUrls;

  /// 调试用：`--dart-define=KAZUMI_UPDATE_MANIFEST=...` 可以临时指向别的清单。
  static const String _manifestOverride =
      String.fromEnvironment('KAZUMI_UPDATE_MANIFEST');

  static List<String> get defaultUrls => _manifestOverride.isNotEmpty
      ? const [_manifestOverride]
      : ApiEndpoints.updateManifestUrls;

  final List<String> urls;

  static const Duration _timeout = Duration(seconds: 8);

  Future<AppReleaseManifest> fetchManifest() async {
    Object? lastError;
    for (final url in urls) {
      try {
        final raw = await DownloadHttpClient.instance
            .getPlain(url, receiveTimeout: _timeout);
        final manifest = AppReleaseManifest.parse(raw);
        KazumiLogger().i('Update: 清单已获取 source=$url');
        return manifest;
      } catch (e) {
        lastError = e;
        KazumiLogger().w('Update: 清单源失败 source=$url', error: e);
      }
    }
    throw AppUpdateSourceException(lastError?.toString() ?? '没有可用的清单地址');
  }
}
