/// Core domain entities for NovelHub.
///
/// These are plain Dart models (no code-gen dependency) so the app compiles
/// even before running build_runner. The persistence layer (data/isar + repos)
/// owns its own annotated schemas and converts to/from these domain types.
library;

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// A single novel.
class Novel {
  final String id;
  String title;

  /// Free-form text settings (tone, genre, world rules, ...).
  String textSettings;

  /// Character / prop settings — list of named entries.
  List<SettingEntry> characterSettings;

  /// Text-level requirements (style constraints, etc.).
  List<TextRequirement> textRequirements;

  /// Chapters in order.
  List<Chapter> chapters;

  /// Per-novel override for the active LLM provider (null = use global).
  String? defaultProviderId;

  /// Serialized conversations (raw JSON maps), persisted with the novel.
  /// EditorState (de)serializes via domain/conversation.dart. Stored as raw
  /// maps here to avoid an entities↔conversation import cycle.
  List<Map<String, dynamic>> conversationsJson;

  Novel({
    required this.id,
    required this.title,
    this.textSettings = '',
    List<SettingEntry>? characterSettings,
    List<TextRequirement>? textRequirements,
    List<Chapter>? chapters,
    this.defaultProviderId,
    List<Map<String, dynamic>>? conversationsJson,
  })  : characterSettings = characterSettings ?? [],
        textRequirements = textRequirements ?? [],
        chapters = chapters ?? [],
        conversationsJson = conversationsJson ?? [];

  Novel copy() => Novel(
        id: id,
        title: title,
        textSettings: textSettings,
        characterSettings: characterSettings.map((e) => e.copy()).toList(),
        textRequirements: textRequirements.map((e) => e.copy()).toList(),
        chapters: chapters.map((e) => e.copy()).toList(),
        defaultProviderId: defaultProviderId,
        conversationsJson:
            conversationsJson.map((e) => Map<String, dynamic>.from(e)).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'textSettings': textSettings,
        'characterSettings': characterSettings.map((e) => e.toJson()).toList(),
        'textRequirements': textRequirements.map((e) => e.toJson()).toList(),
        'chapters': chapters.map((e) => e.toJson()).toList(),
        'defaultProviderId': defaultProviderId,
        'conversations': conversationsJson,
      };

  factory Novel.fromJson(Map<String, dynamic> json) => Novel(
        id: json['id'] as String,
        title: json['title'] as String,
        textSettings: (json['textSettings'] as String?) ?? '',
        characterSettings: ((json['characterSettings'] as List?) ?? [])
            .map((e) => SettingEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        textRequirements: ((json['textRequirements'] as List?) ?? [])
            .map((e) => TextRequirement.fromJson(e as Map<String, dynamic>))
            .toList(),
        chapters: ((json['chapters'] as List?) ?? [])
            .map((e) => Chapter.fromJson(e as Map<String, dynamic>))
            .toList(),
        defaultProviderId: json['defaultProviderId'] as String?,
        conversationsJson: ((json['conversations'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );

  static Novel create({required String title}) =>
      Novel(id: _uuid.v4(), title: title, chapters: [Chapter.create()]);
}

/// A named character / prop / setting entry.
class SettingEntry {
  final String id;
  String name;
  String description;

  SettingEntry({
    required this.id,
    required this.name,
    required this.description,
  });

  SettingEntry copy() => SettingEntry(id: id, name: name, description: description);

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'description': description};

  factory SettingEntry.fromJson(Map<String, dynamic> json) => SettingEntry(
        id: json['id'] as String,
        name: json['name'] as String,
        description: (json['description'] as String?) ?? '',
      );

  static SettingEntry create({required String name, String description = ''}) =>
      SettingEntry(id: _uuid.v4(), name: name, description: description);
}

/// A text-level requirement (style constraint, word-count rule, ...).
class TextRequirement {
  final String id;
  String text;

  TextRequirement({required this.id, required this.text});

  TextRequirement copy() => TextRequirement(id: id, text: text);

  Map<String, dynamic> toJson() => {'id': id, 'text': text};

  factory TextRequirement.fromJson(Map<String, dynamic> json) =>
      TextRequirement(id: json['id'] as String, text: json['text'] as String);

  static TextRequirement create(String text) =>
      TextRequirement(id: _uuid.v4(), text: text);
}

/// A chapter — a list of paragraphs (1-based numbering in UI/tools).
class Chapter {
  final String id;
  String title;
  List<Paragraph> paragraphs;

  Chapter({
    required this.id,
    required this.title,
    required this.paragraphs,
  });

  Chapter copy() => Chapter(
        id: id,
        title: title,
        paragraphs: paragraphs.map((e) => e.copy()).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'paragraphs': paragraphs.map((e) => e.toJson()).toList(),
      };

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        id: json['id'] as String,
        title: json['title'] as String,
        paragraphs: ((json['paragraphs'] as List?) ?? [])
            .map((e) => Paragraph.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static Chapter create({String title = '第一章'}) =>
      Chapter(id: _uuid.v4(), title: title, paragraphs: [Paragraph.create('')]);
}

/// A paragraph of the document. Stable id lets the UI track edits.
class Paragraph {
  final String id;
  String text;

  Paragraph({required this.id, required this.text});

  Paragraph copy() => Paragraph(id: id, text: text);

  Map<String, dynamic> toJson() => {'id': id, 'text': text};

  factory Paragraph.fromJson(Map<String, dynamic> json) =>
      Paragraph(id: json['id'] as String, text: json['text'] as String);

  static Paragraph create(String text) => Paragraph(id: _uuid.v4(), text: text);
}
