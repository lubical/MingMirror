import 'dart:io';

/// 配置：环境变量优先，回退 .env 文件（仅当环境变量未设置时）。
/// key 只从环境变量 / .env 读取，.env 已被 .gitignore 忽略。
class Config {
  final String apiKey;
  final String provider;
  final String model;
  final String? baseUrlOverride;
  final int topK;
  final int history;
  final double temperature;

  Config({
    required this.apiKey,
    required this.provider,
    required this.model,
    this.baseUrlOverride,
    required this.topK,
    required this.history,
    required this.temperature,
  });

  /// 极简 .env 解析：KEY=VALUE 行，忽略注释与空行。
  static Map<String, String> _loadDotEnv(String cwd) {
    final file = File('$cwd${Platform.pathSeparator}.env');
    final out = <String, String>{};
    if (!file.existsSync()) return out;
    for (final line in file.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final eq = t.indexOf('=');
      if (eq <= 0) continue;
      final k = t.substring(0, eq).trim();
      final v = t.substring(eq + 1).trim();
      if (k.isNotEmpty) out[k] = v;
    }
    return out;
  }

  static String _get(String key, Map<String, String> dotEnv, String fallback) =>
      Platform.environment[key] ?? dotEnv[key] ?? fallback;

  factory Config.fromCwd(String cwd) {
    final dotEnv = _loadDotEnv(cwd);
    int intOr(String key, int fallback) =>
        int.tryParse(_get(key, dotEnv, '')) ?? fallback;
    final baseUrl = _get('MINGTIAN_BASE_URL', dotEnv, '');
    return Config(
      apiKey: _get('MINGTIAN_API_KEY', dotEnv, ''),
      provider: _get('MINGTIAN_PROVIDER', dotEnv, 'glm'),
      model: _get('MINGTIAN_MODEL', dotEnv, ''),
      baseUrlOverride: baseUrl.isEmpty ? null : baseUrl,
      topK: intOr('MINGTIAN_TOP_K', 4),
      history: intOr('MINGTIAN_HISTORY', 6),
      temperature: double.tryParse(_get('MINGTIAN_TEMPERATURE', dotEnv, '')) ?? 0.4,
    );
  }
}
