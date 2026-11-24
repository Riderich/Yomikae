import 'dart:math' as math;

import 'package:jhentai/src/service/taste_service.dart';

/// What the user told the recommender: tags and works they want more or less
/// of, the works already shown and where each search left off.
///
/// Dislikes count everywhere (a tag you never want to see is unwanted in
/// every folder); likes, shown works and search positions belong to the
/// folder they were given in, because folders hold different styles.
class RecommendFeedback {
  /// `namespace:key` -> tags you do not want, any folder.
  final Set<String> dislikedTags;

  /// gid -> its tags, any folder.
  final Map<int, List<String>> dislikedGalleries;

  /// folder key -> liked tags.
  final Map<String, Set<String>> likedTags;

  /// folder key -> gid -> tags.
  final Map<String, Map<int, List<String>>> likedGalleries;

  /// folder key -> gids recommended before, most recent last.
  final Map<String, List<int>> shown;

  /// folder key -> search -> gid to continue the next round from.
  final Map<String, Map<String, String>> cursors;

  /// How many shown gids are remembered per folder.
  static const int maxShown = 900;

  RecommendFeedback({
    Set<String>? dislikedTags,
    Map<int, List<String>>? dislikedGalleries,
    Map<String, Set<String>>? likedTags,
    Map<String, Map<int, List<String>>>? likedGalleries,
    Map<String, List<int>>? shown,
    Map<String, Map<String, String>>? cursors,
  })  : dislikedTags = dislikedTags ?? {},
        dislikedGalleries = dislikedGalleries ?? {},
        likedTags = likedTags ?? {},
        likedGalleries = likedGalleries ?? {},
        shown = shown ?? {},
        cursors = cursors ?? {};

  static String keyOf(int? folder) => folder == null ? 'all' : '$folder';

  // ------------------------------------------------------------- questions

  /// 1 liked, -1 disliked, 0 neither, for [tag] in [folder].
  int tagVote(int? folder, String tag) {
    if (dislikedTags.contains(tag)) {
      return -1;
    }
    return likedTags[keyOf(folder)]?.contains(tag) == true ? 1 : 0;
  }

  int galleryVote(int? folder, int gid) {
    if (dislikedGalleries.containsKey(gid)) {
      return -1;
    }
    return likedGalleries[keyOf(folder)]?.containsKey(gid) == true ? 1 : 0;
  }

  Set<String> likedTagsOf(int? folder) => likedTags[keyOf(folder)] ?? const {};

  Map<int, List<String>> likedGalleriesOf(int? folder) => likedGalleries[keyOf(folder)] ?? const {};

  Set<int> shownOf(int? folder) => (shown[keyOf(folder)] ?? const []).toSet();

  bool get isEmpty => dislikedTags.isEmpty && dislikedGalleries.isEmpty && likedTags.values.every((s) => s.isEmpty) && likedGalleries.values.every((m) => m.isEmpty);

  // --------------------------------------------------------------- changes

  /// Sets the vote of [tag] in [folder]: 1, -1 or 0 to forget it.
  void voteTag(int? folder, String tag, int vote) {
    dislikedTags.remove(tag);
    likedTags[keyOf(folder)]?.remove(tag);
    if (vote < 0) {
      dislikedTags.add(tag);
    } else if (vote > 0) {
      (likedTags[keyOf(folder)] ??= {}).add(tag);
    }
  }

  void voteGallery(int? folder, int gid, List<String> tags, int vote) {
    dislikedGalleries.remove(gid);
    likedGalleries[keyOf(folder)]?.remove(gid);
    if (vote < 0) {
      dislikedGalleries[gid] = tags;
    } else if (vote > 0) {
      (likedGalleries[keyOf(folder)] ??= {})[gid] = tags;
    }
  }

  void clear() {
    dislikedTags.clear();
    dislikedGalleries.clear();
    likedTags.clear();
    likedGalleries.clear();
    shown.clear();
    cursors.clear();
  }

  void addShown(int? folder, Iterable<int> gids) {
    final List<int> list = shown[keyOf(folder)] ??= [];
    final Set<int> added = gids.toSet();
    list.removeWhere(added.contains);
    list.addAll(added);
    if (list.length > maxShown) {
      list.removeRange(0, list.length - maxShown);
    }
  }

  // --------------------------------------------------------------- scoring

  /// The folder's profile moved towards the liked works and tags and away
  /// from the disliked tags (Rocchio-style).
  Map<String, double> adjustProfile(int? folder, Map<String, double> profile, Map<String, int> siteCounts) {
    final Map<String, double> result = Map.of(profile);
    final double top = profile.values.fold(0.0, math.max);
    final double norm = _norm(profile);

    final Map<int, List<String>> liked = likedGalleriesOf(folder);
    if (liked.isNotEmpty) {
      final Map<String, double> likedVector = TasteService.tagVector(liked.entries.map((e) => (_gallery(e.key, e.value), 1.0)), siteCounts);
      final double likedNorm = _norm(likedVector);
      if (likedNorm > 0) {
        // the liked works together weigh half as much as the favourites
        final double scale = (norm == 0 ? 1 : norm) * 0.5 / likedNorm;
        likedVector.forEach((tag, v) => result[tag] = (result[tag] ?? 0) + v * scale);
      }
    }
    for (String tag in likedTagsOf(folder)) {
      if (TasteService.isContentTag(tag)) {
        result[tag] = math.max(result[tag] ?? 0, top == 0 ? 1 : top);
      }
    }
    result.removeWhere((tag, _) => dislikedTags.contains(tag));
    return result;
  }

  /// The favourites the profile is built from: without the works of a
  /// disliked artist, circle or uploader.
  List<TasteGallery> filterFavorites(List<TasteGallery> favorites) {
    if (dislikedTags.isEmpty) {
      return favorites;
    }
    return favorites
        .where((g) => !g.tags.any((t) => _isCreator(t) && dislikedTags.contains(t)) && !(g.uploader != null && dislikedTags.contains('uploader:${g.uploader}')))
        .toList();
  }

  static bool _isCreator(String tag) => tag.startsWith('artist:') || tag.startsWith('group:');

  /// Seed tags with liked ones first and no disliked ones. When more tags are
  /// liked than fit, [random] picks which, so every round searches others.
  List<String> adjustSeeds(int? folder, List<String> seeds, Map<String, int> siteCounts, {int count = 5, math.Random? random}) {
    final List<String> liked = likedTagsOf(folder)
        .where((tag) => TasteService.isContentTag(tag) && (siteCounts.isEmpty || (siteCounts[tag] ?? 0) >= 300))
        .toList()
      ..sort()
      ..shuffle(random ?? math.Random());
    return {...liked, ...seeds}.where((tag) => !dislikedTags.contains(tag)).take(count).toList();
  }

  /// The strongest content tags of [profile] that are common enough to search
  /// with, for the user to say which they want more or less of.
  static List<String> tasteTags(Map<String, double> profile, Map<String, int> siteCounts, {int count = 30}) {
    final List<MapEntry<String, double>> entries = profile.entries
        .where((e) => TasteService.isContentTag(e.key) && (siteCounts.isEmpty || (siteCounts[e.key] ?? 0) >= 300))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(count).map((e) => e.key).toList();
  }

  /// Ranks recalled galleries for [folder]: similarity to the adjusted
  /// [profile] x rating, minus closeness to the disliked works; works with a
  /// disliked tag or artist and works already voted on are dropped; works
  /// by a liked artist or circle get a boost. Unseen works come first.
  List<(int, double)> rank(int? folder, List<(TasteGallery, double)> candidates, Map<String, double> profile, Map<String, int> siteCounts) {
    final Map<String, double> disliked = TasteService.tagVector(dislikedGalleries.entries.map((e) => (_gallery(e.key, e.value), 1.0)), siteCounts);
    final Set<String> liked = likedTagsOf(folder);
    final Map<int, List<String>> likedWorks = likedGalleriesOf(folder);
    final Set<int> seen = shownOf(folder);

    final List<(int, double)> fresh = [], again = [];
    for ((TasteGallery, double) c in candidates) {
      final TasteGallery g = c.$1;
      if (dislikedGalleries.containsKey(g.gid) || likedWorks.containsKey(g.gid) || g.tags.any(dislikedTags.contains)) {
        continue;
      }
      final Map<String, double> vector = TasteService.tagVector([(g, 1)], siteCounts);
      double score = TasteService.cosine(vector, profile) - 0.5 * TasteService.cosine(vector, disliked);
      if (score <= 0) {
        continue;
      }
      if (g.tags.any((t) => (t.startsWith('artist:') || t.startsWith('group:')) && liked.contains(t))) {
        score *= 1.3;
      }
      score *= (0.6 + 0.2 * (c.$2 - 3)).clamp(0.4, 1.0);
      (seen.contains(g.gid) ? again : fresh).add((g.gid, score));
    }
    int byScore((int, double) a, (int, double) b) => b.$2.compareTo(a.$2);
    return [...fresh..sort(byScore), ...again..sort(byScore)];
  }

  static TasteGallery _gallery(int gid, List<String> tags) => TasteGallery(gid: gid, token: '', title: '', category: '', tags: tags);

  static double _norm(Map<String, double> v) => math.sqrt(v.values.fold(0.0, (sum, x) => sum + x * x));

  // ------------------------------------------------------------------ json

  Map<String, dynamic> toJson() => {
        'dislikedTags': dislikedTags.toList(),
        'dislikedGalleries': dislikedGalleries.map((gid, tags) => MapEntry('$gid', tags)),
        'likedTags': likedTags.map((f, tags) => MapEntry(f, tags.toList())),
        'likedGalleries': likedGalleries.map((f, m) => MapEntry(f, m.map((gid, tags) => MapEntry('$gid', tags)))),
        'shown': shown,
        'cursors': cursors,
      };

  factory RecommendFeedback.fromJson(Map json) {
    Map<int, List<String>> galleries(Map? m) => {for (MapEntry e in (m ?? const {}).entries) int.parse(e.key): (e.value as List).cast<String>()};
    return RecommendFeedback(
      dislikedTags: ((json['dislikedTags'] as List?) ?? const []).cast<String>().toSet(),
      dislikedGalleries: galleries(json['dislikedGalleries']),
      likedTags: {for (MapEntry e in ((json['likedTags'] as Map?) ?? const {}).entries) e.key as String: (e.value as List).cast<String>().toSet()},
      likedGalleries: {for (MapEntry e in ((json['likedGalleries'] as Map?) ?? const {}).entries) e.key as String: galleries(e.value)},
      shown: {for (MapEntry e in ((json['shown'] as Map?) ?? const {}).entries) e.key as String: (e.value as List).cast<int>()},
      cursors: {for (MapEntry e in ((json['cursors'] as Map?) ?? const {}).entries) e.key as String: Map<String, String>.from(e.value)},
    );
  }
}
