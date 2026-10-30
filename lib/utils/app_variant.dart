/// 构建产物变体。
///
/// 替换版与官方应用同包名（`com.predidit.kazumi`），共存版是独立包名
/// （`com.predidit.kazumi.mod`，构建脚本会临时改 gradle + manifest）。
/// 两者的更新包不能混装：换错只会装出一个多余的应用，或者因签名不同直接安装失败。
enum AppVariant {
  replace('替换版'),
  coexist('共存版');

  const AppVariant(this.label);

  final String label;

  /// 构建脚本用 `--dart-define=KAZUMI_VARIANT=coexist` 打共存版；
  /// 没注入时按替换版处理，普通 `flutter build apk` 也能跑。
  static const String defined =
      String.fromEnvironment('KAZUMI_VARIANT', defaultValue: 'replace');

  static AppVariant get current =>
      defined == AppVariant.coexist.name ? AppVariant.coexist : AppVariant.replace;
}
