import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/entities.dart';
import '../../../state/providers.dart';

/// Right-swipe novel settings: text settings, character/prop settings,
/// text requirements, and per-novel default model.
class NovelSettingsPage extends ConsumerStatefulWidget {
  final String novelId;
  const NovelSettingsPage({super.key, required this.novelId});

  @override
  ConsumerState<NovelSettingsPage> createState() => _NovelSettingsPageState();
}

class _NovelSettingsPageState extends ConsumerState<NovelSettingsPage> {
  late Novel _novel;

  @override
  void initState() {
    super.initState();
    final novels = ref.read(novelListProvider).valueOrNull ?? [];
    _novel = novels.firstWhere(
      (n) => n.id == widget.novelId,
      orElse: () => Novel.create(title: '（未找到）'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text('小说设置 · ${_novel.title}'),
          bottom: const TabBar(tabs: [
            Tab(text: '文本设定'),
            Tab(text: '人物/道具'),
            Tab(text: '文本要求'),
          ]),
        ),
        body: TabBarView(
          children: [
            _textSettingsTab(),
            _characterSettingsTab(),
            _requirementsTab(),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.save),
          label: const Text('保存'),
          onPressed: () async {
            await ref.read(novelListProvider.notifier).save(_novel);
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  Widget _textSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('默认模型（覆盖全局）',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        _defaultModelSelector(),
        const SizedBox(height: 24),
        const Text('文本设定', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: _novel.textSettings,
          maxLines: 12,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '题材、基调、世界观、文风…',
          ),
          onChanged: (v) => _novel.textSettings = v,
        ),
      ],
    );
  }

  Widget _defaultModelSelector() {
    final providers = ref.watch(providerConfigListProvider).valueOrNull ?? [];
    return DropdownButtonFormField<String?>(
      value: _novel.defaultProviderId,
      decoration: const InputDecoration(border: OutlineInputBorder()),
      items: [
        const DropdownMenuItem(value: null, child: Text('使用全局默认')),
        for (final p in providers)
          DropdownMenuItem(value: p.id, child: Text(p.name)),
      ],
      onChanged: (v) => setState(() => _novel.defaultProviderId = v),
    );
  }

  Widget _characterSettingsTab() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _novel.characterSettings.length + 1,
      itemBuilder: (context, i) {
        if (i == _novel.characterSettings.length) {
          return ListTile(
            leading: const Icon(Icons.add),
            title: const Text('新增设定'),
            onTap: () {
              final s = SettingEntry.create(name: '新设定');
              setState(() => _novel.characterSettings.add(s));
            },
          );
        }
        final s = _novel.characterSettings[i];
        return _CharacterSettingCard(
          key: ValueKey(s.id),
          setting: s,
          onDelete: () {
            setState(() =>
                _novel.characterSettings.removeWhere((x) => x.id == s.id));
            ref.read(novelListProvider.notifier).save(_novel);
          },
        );
      },
    );
  }

  Widget _requirementsTab() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _novel.textRequirements.length + 1,
      itemBuilder: (context, i) {
        if (i == _novel.textRequirements.length) {
          return ListTile(
            leading: const Icon(Icons.add),
            title: const Text('新增要求'),
            onTap: () {
              final r = TextRequirement.create('新要求');
              setState(() => _novel.textRequirements.add(r));
            },
          );
        }
        final r = _novel.textRequirements[i];
        return _RequirementCard(
          key: ValueKey(r.id),
          requirement: r,
          onDelete: () {
            setState(
                () => _novel.textRequirements.removeWhere((x) => x.id == r.id));
            ref.read(novelListProvider.notifier).save(_novel);
          },
        );
      },
    );
  }
}

/// One text-requirement row. Owns its own [TextEditingController] so the
/// field never leaks state across list-item reuse (the prior
/// `initialValue`-in-ListView approach caused deletes to target the wrong
/// row because the controller/outside closure got reused with stale indices).
class _RequirementCard extends StatefulWidget {
  final TextRequirement requirement;
  final VoidCallback onDelete;
  const _RequirementCard({
    super.key,
    required this.requirement,
    required this.onDelete,
  });

  @override
  State<_RequirementCard> createState() => _RequirementCardState();
}

class _RequirementCardState extends State<_RequirementCard> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.requirement.text);
    _ctrl.addListener(_sync);
  }

  void _sync() => widget.requirement.text = _ctrl.text;

  @override
  void dispose() {
    _ctrl.removeListener(_sync);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                  border: InputBorder.none, contentPadding: EdgeInsets.all(12)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: widget.onDelete,
          ),
        ],
      ),
    );
  }
}

/// One character/prop setting row. Same per-item controller approach as
/// [_RequirementCard] to avoid ListView reuse bugs.
class _CharacterSettingCard extends StatefulWidget {
  final SettingEntry setting;
  final VoidCallback onDelete;
  const _CharacterSettingCard({
    super.key,
    required this.setting,
    required this.onDelete,
  });

  @override
  State<_CharacterSettingCard> createState() => _CharacterSettingCardState();
}

class _CharacterSettingCardState extends State<_CharacterSettingCard> {
  late final TextEditingController _name;
  late final TextEditingController _desc;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.setting.name);
    _desc = TextEditingController(text: widget.setting.description);
    _name.addListener(() => widget.setting.name = _name.text);
    _desc.addListener(() => widget.setting.description = _desc.text);
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: widget.onDelete,
                ),
              ],
            ),
            TextField(
              controller: _desc,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '描述'),
            ),
          ],
        ),
      ),
    );
  }
}
