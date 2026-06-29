import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/llm/llm_client.dart';
import '../../../state/providers.dart';
import 'provider_config_form.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with TickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  )..addListener(_onTabChanged);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// Rebuild so the AppBar action (the "+" add-config button) follows the
  /// active tab. indexIsChanging is true mid-swipe; we wait for it to settle
  /// rather than rebuilding on every animation frame.
  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      setState(() {});
    }
  }

  Future<void> _addConfig() async {
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
  }

  @override
  Widget build(BuildContext context) {
    final providersAv = ref.watch(providerConfigListProvider);
    final providers = providersAv.valueOrNull ?? [];
    final activeId = ref.watch(activeProviderIdProvider).valueOrNull;
    // The "+" action only makes sense on the models tab; hide it elsewhere.
    final onModelsTab = _tabController.index == 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          if (onModelsTab)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '新增配置',
              onPressed: _addConfig,
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '偏好'),
            Tab(text: '模型'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _preferencesTab(context),
          _modelsTab(providers, activeId),
        ],
      ),
    );
  }

  Widget _preferencesTab(BuildContext context) {
    return ListView(
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
        // --- Agent panel preferences ---
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('工具调用展开方式',
              style:
                  Theme.of(context).textTheme.titleSmall),
        ),
        for (final m in ToolCallExpandMode.values)
          RadioListTile<ToolCallExpandMode>(
            value: m,
            groupValue: ref.watch(toolCallExpandModeProvider),
            title: Text(m.label),
            onChanged: (v) {
              if (v != null) {
                ref.read(prefsProvider.notifier).toolCallExpandMode = v;
              }
            },
          ),
        SwitchListTile(
          title: const Text('思考过程自动展开'),
          value: ref.watch(cotAutoExpandProvider),
          onChanged: (v) =>
              ref.read(prefsProvider.notifier).cotAutoExpand = v,
        ),
      ],
    );
  }

  Widget _modelsTab(List<ProviderConfig> providers, String? activeId) {
    if (providers.isEmpty) {
      return const Center(child: Text('点击右上角 + 新增第一个模型配置'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final p in providers) _configTile(p, activeId),
      ],
    );
  }

  Widget _configTile(ProviderConfig p, String? activeId) {
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
