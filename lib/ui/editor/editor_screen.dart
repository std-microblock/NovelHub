import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/editor_state.dart';
import '../../state/providers.dart';
import 'editor_pane.dart';
import 'agent/agent_pane.dart';
import 'novel_list/novel_drawer.dart';
import 'novel_settings/novel_settings_page.dart';
import 'prompt_string.dart';

/// The main screen: top bar (chapter switch + edit/select toggle),
/// upper editor pane, lower agent pane. Left drawer = novel list; right
/// swipe = novel settings.
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen>
    with TickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  // Raw pixel height of the agent panel (portrait only). Tracked directly off
  // the finger's absolute position — no delta accumulation — so the handle
  // follows the finger 1:1 regardless of gesture-arena delta coalescing.
  double? _agentH;
  // Anchors captured on drag start: global Y and height at that moment.
  double _dragStartY = 0;
  double _dragStartH = 0;
  // Measured panel heights reported by AgentPane after layout:
  //  _headerH — header only (the fully-collapsed floor)
  //  _midH    — header + composer (the half-collapsed resting state)
  // Fallbacks until the first measure lands.
  double _headerH = 36;
  double _midH = 120;
  // Expanded height remembered across collapse, so tapping the title expands
  // back to where the user had it (not just to the default).
  double _expandedH = 0;
  // Raw (undamped) finger target captured during a drag, used to decide the
  // snap on release. The visible height [_agentH] is damped in the collapse
  // band so it lags the finger; if we snapped off the damped position the
  // panel would always read "near mid" and spring back up instead of latching
  // to fully-collapsed. Tracking the raw intent fixes that.
  double _rawDragH = 0;
  // Animates the snap to a resting state on drag end (spring-like damping).
  late final AnimationController _snap;
  Animation<double>? _snapAnim;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(vsync: this);
    _snap.addListener(() {
      final a = _snapAnim;
      if (a == null) return;
      setState(() => _agentH = a.value);
    });
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  /// Drag started from the header grip.
  void _onDragStart(double startGlobalY, double currentH) {
    _snap.stop();
    _snapAnim = null;
    _dragStartY = startGlobalY;
    _dragStartH = currentH;
    _rawDragH = currentH;
  }

  /// Drag update — position-based, with a damping band below [_midH]: the lower
  /// the panel goes past the half-collapsed point, the harder each px of finger
  /// motion is to earn (like a spring resisting compression). This gives the
  /// "费劲" feel approaching the fully-collapsed floor. [_rawDragH] tracks the
  /// undamped intent so the release snap reflects what the user was actually
  /// aiming for (the damped [_agentH] lags the finger and would otherwise read
  /// "near mid" forever, bouncing back up).
  void _onDragUpdate(double globalY, double total) {
    final maxH = total - 80;
    final floor = _headerH.clamp(0.0, maxH);
    final mid = _midH.clamp(floor, maxH);
    final band = (mid - floor).clamp(1.0, double.infinity);
    // Raw 1:1 target height from the finger's absolute position.
    var target = _dragStartH + (_dragStartY - globalY);
    target = target.clamp(floor, maxH);
    _rawDragH = target;
    // Below [mid] we enter the damping band: scale the distance into the band
    // by a factor that shrinks toward ~0.25 at the floor, so reaching
    // fully-collapsed takes deliberate extra dragging while still letting the
    // finger get there (not a hard wall).
    double damped = target;
    if (target < mid) {
      final into = (mid - target).clamp(0.0, band); // how far past mid
      final k = (1 - (into / band) * 0.75).clamp(0.25, 1.0); // resistance grows
      damped = mid - into * k;
    }
    setState(() => _agentH = damped);
  }

  /// Drag ended — snap to the nearest resting state using the RAW (undamped)
  /// finger intent, so the panel latches to fully-collapsed when the user
  /// dragged hard enough rather than springing back up to mid.
  ///  • raw < ~⅓ into the band → fully-collapsed (floor)
  ///  • raw < mid (but not past the threshold) → half-collapsed (mid)
  ///  • raw >= mid → free rest (expanded); remember it for tap-to-expand.
  void _onDragEnd(double total) {
    final maxH = total - 80;
    final floor = _headerH.clamp(0.0, maxH);
    final mid = _midH.clamp(floor, maxH);
    final band = (mid - floor).clamp(1.0, double.infinity);
    final raw = _rawDragH.clamp(floor, maxH);

    double target;
    if (raw >= mid) {
      // Expanded — let it rest where the finger aimed.
      target = raw.clamp(mid, maxH);
      _expandedH = target;
    } else if (raw <= floor + band * 0.33) {
      // Dragged most of the way down → collapse fully (header only).
      target = floor;
    } else {
      // Somewhere in the band but not far enough to fully collapse → rest at
      // the half-collapsed (header + composer) state.
      target = mid;
    }
    _animateTo(target);
  }

  /// Tap the "Agent" title → toggle between fully-collapsed and the last
  /// expanded height (falling back to a default 45% of the screen).
  void _onToggleExpand(double total) {
    final maxH = total - 80;
    final floor = _headerH.clamp(0.0, maxH);
    final mid = _midH.clamp(floor, maxH);
    final h = (_agentH ?? mid);
    if (h <= mid + 1) {
      // Collapsed → expand to remembered height (or default 45%).
      final target =
          (_expandedH > mid + 48 ? _expandedH : (total * 0.45)).clamp(mid + 48, maxH);
      _expandedH = target;
      _animateTo(target);
    } else {
      // Expanded → fully collapse.
      _animateTo(floor);
    }
  }

  void _animateTo(double target) {
    final from = _agentH ?? target;
    _snapAnim = Tween<double>(begin: from, end: target).animate(
      CurvedAnimation(
        parent: _snap,
        // Spring-like: easeOutBack overshoots slightly for a lively snap.
        curve: Curves.easeOutCubic,
      ),
    );
    _snap.duration = const Duration(milliseconds: 220);
    _snap.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final novelAv = ref.watch(currentNovelProvider);
    final novel = novelAv.valueOrNull;
    final editor = ref.watch(editorStateProvider);

    if (novel == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('NovelHub')),
        drawer: const NovelDrawer(),
        body: const Center(child: Text('左上角菜单 → 新建小说 开始写作')),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: '小说列表',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: _chapterSwitch(editor),
        actions: [
          // Right-swipe affordance -> novel settings.
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '小说设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => NovelSettingsPage(novelId: novel.id)),
            ),
          ),
          _modeSwitch(editor),
        ],
      ),
      drawer: const NovelDrawer(),
      // Pad the bottom so content clears the edge-to-edge system navigation
      // bar (gesture handle); otherwise the agent pane renders behind it.
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 900;
          if (wide) {
            return Row(
              children: [
                Expanded(flex: 1, child: EditorPane(editor: editor)),
                const VerticalDivider(width: 1),
                Expanded(flex: 1, child: AgentPane(editor: editor)),
              ],
            );
          }
          // Vertical split: editor on top, a floating agent panel docked to
          // the bottom edge with rounded top corners + shadow. The drag handle
          // is an overlay that takes no layout space and only shows on hover or
          // while dragging.
          final total = constraints.maxHeight;
          final maxH = total - 80;
          // Resting-state heights reported by AgentPane after layout:
          //  floor = header only (fully-collapsed)
          //  mid   = header + composer (half-collapsed)
          // Fallbacks until the first measure lands.
          final floor = _headerH.clamp(0.0, maxH);
          final mid = _midH.clamp(floor, maxH);
          final agentH = (_agentH ?? total * 0.45).clamp(floor, maxH).toDouble();
          return Stack(
            // No clip so the shadow can spread above the panel onto the editor.
            clipBehavior: Clip.none,
            children: [
              // Upper editor fills everything; the floating panel overlaps its
              // lower portion (the shadow sits on top of the editor).
              Positioned.fill(
                child: EditorPane(editor: editor, bottomInset: agentH),
              ),
              // Floating agent panel: top rounded corners + drop shadow; the
              // bottom edge is flush with the screen bottom (square corners).
              // BoxShadow (not Material.elevation) so it paints even though the
              // panel body itself is colored by AgentPane — and it survives the
              // transparent-background rendering path.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: agentH,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 16,
                        spreadRadius: -2,
                        offset: const Offset(0, -3),
                      ),
                    ],
                  ),
                  child: ClipPath(
                    clipper: const _TopRoundClipper(top: 16),
                    child: AgentPane(
                      editor: editor,
                      panelHeight: agentH,
                      headerHeight: floor,
                      midHeight: mid,
                      // Same position-based drag logic as the strip handle:
                      // anchor on start, recompute height from the finger's
                      // absolute Y every update (with a damping band below
                      // [mid]). Wired to the "Agent" header row so dragging
                      // the title / blank header area resizes the panel.
                      onDragStart: (g) => _onDragStart(g, agentH),
                      onDragUpdate: (g) => _onDragUpdate(g, total),
                      onDragEnd: () => _onDragEnd(total),
                      // Tap (no drag) on the title / blank header toggles
                      // between fully-collapsed and the last expanded height.
                      onToggleExpand: () => _onToggleExpand(total),
                      // AgentPane measures its header (and header + composer)
                      // and reports both so the drag clamp and snap bands stay
                      // in sync with the actual widget sizes.
                      onMeasureHeights: (h, m) {
                        var changed = false;
                        if ((h - _headerH).abs() > 0.5) {
                          _headerH = h;
                          changed = true;
                        }
                        if (m > 0 && (m - _midH).abs() > 0.5) {
                          _midH = m;
                          changed = true;
                        }
                        if (changed) setState(() {});
                      },
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        ),
      ),
    );
  }

  Future<void> _promptNewChapter(BuildContext context) async {
    final chapters = ref.read(editorStateProvider).novel.chapters;
    final initial = '第${chapters.length + 1}章';
    final title = await promptString(
      context,
      title: '新增章节',
      hint: '章节标题',
      initial: initial,
      confirmLabel: '创建',
    );
    if (title != null && title.isNotEmpty && context.mounted) {
      await ref.read(editorStateProvider.notifier).addChapter(title);
    }
  }

  Widget _chapterSwitch(EditorState editor) {
    final chapter = editor.chapter;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: TextButton(
        onPressed: () => _openChapterManager(context, editor),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '${chapter.title} · ${chapter.paragraphs.length}段',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  Future<void> _openChapterManager(
      BuildContext context, EditorState editor) async {
    await showDialog<void>(
      context: context,
      builder: (c) => _ChapterManagerDialog(
        editor: editor,
        notifier: ref.read(editorStateProvider.notifier),
      ),
    );
  }

  Widget _modeSwitch(EditorState editor) {
    final isEdit = editor.mode == EditorMode.edit;
    return IconButton(
      icon: Icon(isEdit ? Icons.edit : Icons.check_box),
      tooltip: isEdit ? '当前：编辑模式' : '当前：选择模式',
      onPressed: () => ref.read(editorStateProvider.notifier).setMode(
            isEdit ? EditorMode.select : EditorMode.edit,
          ),
    );
  }
}

/// Clips only the top corners rounded, leaving the bottom edge square so the
/// floating panel sits flush against the screen bottom while the [Material]
/// above paints the matching rounded shadow.
class _TopRoundClipper extends CustomClipper<Path> {
  final double top;
  const _TopRoundClipper({required this.top});

  @override
  Path getClip(Size size) {
    final r = Radius.circular(top);
    return Path()
      ..moveTo(0, top)
      ..arcToPoint(Offset(top, 0), radius: r)
      ..lineTo(size.width - top, 0)
      ..arcToPoint(Offset(size.width, top), radius: r)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_TopRoundClipper old) => old.top != top;
}

/// Chapter management dialog: lists every chapter with inline rename /
/// reorder / delete actions plus a header button to add a new chapter.
/// Tapping a row switches to that chapter and closes the dialog.
///
/// It rebuilds from the live [EditorState] on every notifier change so the
/// list reflects renames / reorders / deletions immediately.
class _ChapterManagerDialog extends ConsumerWidget {
  final EditorState editor;
  final EditorStateNotifier notifier;

  const _ChapterManagerDialog({required this.editor, required this.notifier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Re-read the live state so mutations performed from within the dialog
    // (rename / move / delete) are reflected without reopening it.
    final live = ref.watch(editorStateProvider);
    final chapters = live.novel.chapters;
    final currentId = live.chapter.id;
    final canDelete = chapters.length > 1;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('章节管理'),
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('新增'),
            onPressed: () async {
              final initial = '第${chapters.length + 1}章';
              final title = await promptString(
                context,
                title: '新增章节',
                hint: '章节标题',
                initial: initial,
                confirmLabel: '创建',
              );
              if (title != null && title.isNotEmpty) {
                await notifier.addChapter(title);
              }
            },
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: chapters.length,
          itemBuilder: (c, i) {
            final ch = chapters[i];
            final selected = ch.id == currentId;
            return ListTile(
              selected: selected,
              leading: Text('${i + 1}',
                  style: const TextStyle(color: Colors.grey)),
              title: Text(ch.title,
                  overflow: TextOverflow.ellipsis, maxLines: 1),
              subtitle: Text('${ch.paragraphs.length}段'),
              onTap: () {
                notifier.selectChapter(ch.id);
                Navigator.pop(c);
              },
              trailing: PopupMenuButton<String>(
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'rename', child: Text('重命名')),
                  PopupMenuItem(
                    value: 'up',
                    enabled: i > 0,
                    child: const Text('上移'),
                  ),
                  PopupMenuItem(
                    value: 'down',
                    enabled: i < chapters.length - 1,
                    child: const Text('下移'),
                  ),
                  PopupMenuItem(
                    value: 'del',
                    enabled: canDelete,
                    child: const Text('删除'),
                  ),
                ],
                onSelected: (v) async {
                  if (v == 'rename') {
                    final title = await promptString(
                      context,
                      title: '重命名章节',
                      initial: ch.title,
                      confirmLabel: '保存',
                    );
                    if (title != null && title.isNotEmpty) {
                      await notifier.renameChapter(ch.id, title);
                    }
                  } else if (v == 'up') {
                    await notifier.moveChapter(ch.id, i);
                  } else if (v == 'down') {
                    await notifier.moveChapter(ch.id, i + 2);
                  } else if (v == 'del') {
                    final ok = await showDialog<bool>(
                          context: context,
                          builder: (cc) => AlertDialog(
                            title: const Text('删除章节'),
                            content: Text(
                                '删除「${ch.title}」及其全部段落？此操作不可撤销。'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(cc, false),
                                  child: const Text('取消')),
                              FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(cc, true),
                                  child: const Text('删除')),
                            ],
                          ),
                        ) ??
                        false;
                    if (ok) await notifier.deleteChapter(ch.id);
                  }
                },
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
