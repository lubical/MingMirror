/// 服务商配置：OpenAI 兼容接口。
class ProviderConfig {
  final String id;
  final String baseUrl;
  final String defaultModel;
  const ProviderConfig(this.id, this.baseUrl, this.defaultModel);
}

const kProviders = <String, ProviderConfig>{
  'glm': ProviderConfig(
    'glm',
    'https://open.bigmodel.cn/api/paas/v4',
    'glm-4-flash',
  ),
  'deepseek': ProviderConfig(
    'deepseek',
    'https://api.deepseek.com',
    'deepseek-chat',
  ),
  'qwen': ProviderConfig(
    'qwen',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'qwen-plus',
  ),
};

ProviderConfig providerConfig(String id) =>
    kProviders[id.toLowerCase()] ?? kProviders['glm']!;
