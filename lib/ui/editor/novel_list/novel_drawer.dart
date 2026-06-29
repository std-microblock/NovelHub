import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../prompt_string.dart';
import '../settings/settings_page.dart';

/// Left navigation drawer: novel list (create / duplicate / delete /
/// switch) + settings entry at the bottom.
class NovelDrawer extends ConsumerWidget {
  const NovelDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final novelsAv = ref.watch(novelListProvider);
    final novels = novelsAv.valueOrNull ?? [];
    final currentId = ref.watch(currentNovelIdProvider);

    return Drawer(
      child: Column(
        children: [
          const DrawerHeader(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text('NovelHub',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final n in novels)
                  ListTile(
                    selected: n.id == currentId,
                    title: Text(n.title),
                    subtitle: Text('${n.chapters.length} 章'),
                    onTap: () {
                      ref.read(currentNovelIdProvider.notifier).state = n.id;
                      Navigator.pop(context);
                    },
                    trailing: PopupMenuButton<String>(
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'dup', child: Text('复制')),
                        PopupMenuItem(value: 'del', child: Text('删除')),
                      ],
                      onSelected: (v) async {
                        if (v == 'rename') {
                          final title = await promptString(
                            context,
                            title: '重命名小说',
                            initial: n.title,
                            confirmLabel: '保存',
                          );
                          if (title != null && title.isNotEmpty) {
                            await ref
                                .read(novelListProvider.notifier)
                                .rename(n.id, title);
                          }
                        } else if (v == 'dup') {
                          await ref
                              .read(novelListProvider.notifier)
                              .duplicate(n.id);
                        } else if (v == 'del') {
                          final ok = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('删除小说'),
                                  content: Text('删除「${n.title}」？此操作不可撤销。'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, false),
                                        child: const Text('取消')),
                                    FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(c, true),
                                        child: const Text('删除')),
                                  ],
                                ),
                              ) ??
                              false;
                          if (ok) {
                            await ref
                                .read(novelListProvider.notifier)
                                .delete(n.id);
                          }
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('新建小说'),
            onTap: () async {
              final title = await promptString(
                context,
                title: '新建小说',
                hint: '小说标题',
                confirmLabel: '创建',
              );
              if (title != null && title.isNotEmpty) {
                final novel = await ref
                    .read(novelListProvider.notifier)
                    .create(title);
                ref.read(currentNovelIdProvider.notifier).state = novel.id;
              }
              if (context.mounted) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('设置'),
            subtitle: const Text('LLM 模型配置'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
    );
  }
}
