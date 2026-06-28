import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/llm/llm_client.dart';
import '../../../state/providers.dart';

/// Unified provider config form. The type dropdown reveals provider-specific
/// fields (e.g. CoT prefix only for DeepSeek).
class ProviderConfigForm extends ConsumerStatefulWidget {
  final ProviderConfig config;
  final bool isNew;
  const ProviderConfigForm(
      {super.key, required this.config, this.isNew = false});

  @override
  ConsumerState<ProviderConfigForm> createState() => _ProviderConfigFormState();
}

class _ProviderConfigFormState extends ConsumerState<ProviderConfigForm> {
  late ProviderConfig _cfg = widget.config;

  @override
  Widget build(BuildContext context) {
    final isDeepSeek = _cfg.type == ProviderType.deepSeekPrefix;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? '新增配置' : '编辑 ${_cfg.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _save,
            tooltip: '保存',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            initialValue: _cfg.name,
            decoration: const InputDecoration(labelText: '名称'),
            onChanged: (v) => _cfg.name = v,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ProviderType>(
            value: _cfg.type,
            decoration: const InputDecoration(labelText: '类型'),
            items: [
              for (final t in ProviderType.values)
                DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: (t) => setState(() => _cfg = _cfg.copyWith(type: t)),
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: _cfg.baseUrl,
            decoration: InputDecoration(
              labelText: 'Base URL',
              hintText: isDeepSeek
                  ? 'https://api.deepseek.com (beta 自动附加)'
                  : 'https://api.openai.com/v1',
            ),
            onChanged: (v) => _cfg.baseUrl = v,
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: _cfg.apiKey,
            decoration: const InputDecoration(labelText: 'API Key'),
            obscureText: true,
            onChanged: (v) => _cfg.apiKey = v,
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: _cfg.modelName,
            decoration: const InputDecoration(labelText: '模型名'),
            onChanged: (v) => _cfg.modelName = v,
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: _cfg.temperature.toString(),
            decoration: const InputDecoration(labelText: 'Temperature'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) =>
                _cfg = _cfg.copyWith(temperature: double.tryParse(v) ?? 0.7),
          ),
          if (isDeepSeek) ...[
            const Divider(),
            SwitchListTile(
              title: const Text('启用 Beta (前缀续写端点)'),
              value: _cfg.beta,
              onChanged: (v) =>
                  setState(() => _cfg = _cfg.copyWith(beta: v)),
            ),
            TextFormField(
              initialValue: _cfg.cotPrefix ?? '',
              decoration: const InputDecoration(
                labelText: 'CoT 前缀 (留空不限)',
                helperText: '强制推理链以这些字符开头 (续写 CoT)',
              ),
              onChanged: (v) => _cfg.cotPrefix = v.isEmpty ? null : v,
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _cfg.cotFirstChars.toString(),
              decoration: const InputDecoration(
                  labelText: 'CoT 前缀长度 (字数)'),
              keyboardType: TextInputType.number,
              onChanged: (v) => _cfg = _cfg.copyWith(
                  cotFirstChars: int.tryParse(v) ?? 2),
            ),
          ],
          const Divider(),
          TextFormField(
            initialValue: _cfg.autoRetryCount.toString(),
            decoration: const InputDecoration(
              labelText: '流式中断自动重试次数',
              helperText: 'DeepSeek 走真前缀续写；其他模型近似续写',
            ),
            keyboardType: TextInputType.number,
            onChanged: (v) => _cfg = _cfg.copyWith(
                autoRetryCount: int.tryParse(v) ?? 3),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final notifier = ref.read(providerConfigListProvider.notifier);
    if (widget.isNew) {
      await notifier.add(_cfg);
      // Auto-activate the first/new config for convenience.
      ref.read(activeProviderIdProvider.notifier).set(_cfg.id);
    } else {
      await notifier.update(_cfg);
    }
    if (mounted) Navigator.of(context).pop();
  }
}
