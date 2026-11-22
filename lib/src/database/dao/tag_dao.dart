import 'package:drift/drift.dart';
import 'package:jhentai/src/database/database.dart';

class TagDao {
  static Future<List<TagData>> selectTagByNamespaceAndKey(String namespace, String key) async {
    return (appDb.select(appDb.tag)..where((tag) => tag.namespace.equals(namespace) & tag.key.equals(key))).get();
  }

  static Future<List<TagData>> selectTagsByKey(String key) {
    return (appDb.select(appDb.tag)..where((tag) => tag.key.equals(key))).get();
  }

  /// Tags of one namespace with their site-wide gallery count (0 when the tag
  /// count data is not installed), most used first, optionally filtered by key
  /// or translated name.
  static Future<List<(TagData, int)>> selectTagsOfNamespaceWithCount(String namespace, {String? filter, int limit = 60, int offset = 0}) async {
    final String? pattern = filter == null || filter.trim().isEmpty ? null : '%${filter.trim().toLowerCase()}%';
    final List<QueryRow> rows = await appDb.customSelect(
      'SELECT t.*, COALESCE(c.count, 0) AS jh_count FROM tag t '
      "LEFT JOIN tag_count c ON c.namespaceWithKey = t.namespace || ':' || t._key "
      'WHERE t.namespace = ?${pattern == null ? '' : ' AND (t._key LIKE ? OR t.tagName LIKE ?)'} '
      'ORDER BY jh_count DESC, t._key LIMIT ? OFFSET ?',
      variables: [
        Variable.withString(namespace),
        if (pattern != null) Variable.withString(pattern),
        if (pattern != null) Variable.withString(pattern),
        Variable.withInt(limit),
        Variable.withInt(offset),
      ],
      readsFrom: {appDb.tag, appDb.tagCount},
    ).get();
    return rows.map((row) => (appDb.tag.map(row.data), row.read<int>('jh_count'))).toList();
  }

  static Future<int> countTags() async {
    final QueryRow row = await appDb.customSelect('SELECT COUNT(*) AS c FROM tag', readsFrom: {appDb.tag}).getSingle();
    return row.read<int>('c');
  }

  static Future<List<TagData>> selectAllTags() {
    return (appDb.select(appDb.tag)).get();
  }

  static Future<List<TagData>> searchFullTags(String namespacePattern, String keyPattern) {
    return (appDb.select(appDb.tag)
          ..where((tag) =>
              (tag.namespace.equals(namespacePattern.toLowerCase()) | tag.translatedNamespace.equals(namespacePattern)) &
              (tag.key.like(keyPattern.toLowerCase()) | tag.tagName.like(keyPattern))))
        .get();
  }

  static Future<List<TagData>> searchFullTagsIncludeIntro(String namespacePattern, String keyPattern) {
    return (appDb.select(appDb.tag)
          ..where((tag) =>
              (tag.namespace.equals(namespacePattern.toLowerCase()) | tag.translatedNamespace.equals(namespacePattern)) &
              (tag.key.like(keyPattern.toLowerCase()) | tag.tagName.like(keyPattern) | tag.intro.like(keyPattern.toLowerCase()))))
        .get();
  }

  static Future<List<TagData>> searchTags(String pattern) {
    return (appDb.select(appDb.tag)..where((tag) => tag.key.like(pattern) | tag.tagName.like(pattern))).get();
  }

  static Future<List<TagData>> searchTagsIncludeIntro(String pattern) {
    return (appDb.select(appDb.tag)..where((tag) => tag.key.like(pattern) | tag.tagName.like(pattern) | tag.intro.like(pattern))).get();
  }

  static Future<int> insertTag(TagData tag) {
    return appDb.into(appDb.tag).insert(tag);
  }

  static Future<int> deleteAllTags() {
    return appDb.delete(appDb.tag).go();
  }
}
