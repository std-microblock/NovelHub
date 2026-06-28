import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/llm/llm_client.dart';
import '../../../state/providers.dart';
import 'provider_config_form.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAv = ref.watch(providerConfigListProvider);
    final providers = providersAv.valueOrNull ?? [];
    final activeId = ref.watch(activeProviderIdProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置 · LLM 模型'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增配置',
            onPressed: () async {
              final cfg = ProviderConfig(
                id: 'cfg_${DateTime.now().millisecondsSinceEpoch}',
                name: '新配置',
                type: ProviderType.openaiStreaming,
                baseUrl: 'https://api.openai.com/v1',
                apiKey: '',
                modelName: 'gpt-4o-mini',
              );
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProviderConfigForm(config: cfg, isNew: true),
              ));
            },
          ),
        ],
      ),
      body: providers.isEmpty
          ? Center(child: Text('点击右上角 + 新增第一个模型配置'))
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // --- Sending preferences ---
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('发送方式',
                      style:
                          Theme.of(context).textTheme.titleSmall),
                ),
                for (final b in SendBehavior.values)
                  RadioListTile<SendBehavior>(
                    value: b,
                    groupValue: ref.watch(sendBehaviorProvider),
                    title: Text(b.label),
                    onChanged: (v) {
                      if (v != null) {
                        ref.read(prefsProvider.notifier).sendBehavior = v;
                      }
                    },
                  ),
                const Divider(height: 32),
                // --- Model list ---
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text('模型配置',
                      style:
                          Theme.of(context).textTheme.titleSmall),
                ),
                for (final p in providers) _configTile(context, ref, p, activeId, providers.length),
              ],
            ),
    );
  }

  Widget _configTile(BuildContext context, WidgetRef ref, ProviderConfig p,
      String? activeId, int total) {
    final active = p.id == activeId;
    return ListTile(
      leading: Radio<String?>(
        value: p.id,
        groupValue: activeId,
        onChanged: (_) =>
            ref.read(activeProviderIdProvider.notifier).set(p.id),
      ),
      title: Text(p.name),
      subtitle: Text('${p.type.label} · ${p.modelName}\n${p.baseUrl}',
          maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProviderConfigForm(config: p.copy()),
              ));
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除',
            onPressed: () async {
              final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('删除配置'),
                      content: Text('删除「${p.name}」？'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('删除')),
                      ],
                    ),
                  ) ??
                  false;
              if (ok) {
                await ref
                    .read(providerConfigListProvider.notifier)
                    .remove(p.id);
              }
            },
          ),
        ],
      ),
      selected: active,
      onTap: () => ref.read(activeProviderIdProvider.notifier).set(p.id),
    );
  }
}
