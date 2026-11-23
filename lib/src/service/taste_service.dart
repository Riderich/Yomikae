import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_metadata.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/tag_search_order_service.dart';
import 'package:jhentai/src/service/tag_translation_service.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:path/path.dart';

import 'jh_service.dart';
import 'log.dart';

TasteService tasteService = TasteService();

/// What the app knows about one favourited gallery.
class TasteGallery {
  final int gid;
  final String token;
  final String title;
  final String category;
  final String? uploader;

  /// `namespace:key`
  final List<String> tags;

  const TasteGallery({required this.gid, required this.token, required this.title, required this.category, this.uploader, required this.tags});

  Map<String, dynamic> toJson() => {'gid': gid, 'token': token, 'title': title, 'category': category, 'uploader': uploader, 'tags': tags};

  factory TasteGallery.fromJson(Map json) => TasteGallery(
        gid: json['gid'],
        token: json['token'],
        title: json['title'] ?? '',
        category: json['category'] ?? '',
        uploader: json['uploader'],
        tags: (json['tags'] as List).cast<String>(),
      );

  factory TasteGallery.fromMetadata(GalleryMetadata m) => TasteGallery(
        gid: m.galleryUrl.gid,
        token: m.galleryUrl.token,
        title: m.japaneseTitle.isNotEmpty ? m.japaneseTitle : m.title,
        category: m.category,
        uploader: m.uploader,
        tags: m.tags.values.expand((tags) => tags).map((t) => '${t.tagData.namespace}:${t.tagData.key}').toList(),
      );
}

/// One artist / circle / uploader / tag and how often it appears in the favourites.
class TasteItem {
  final String namespace;
  final String key;

  /// Favourites with this item; for recommendations, the similar galleries found.
  final int count;

  /// How common the tag is on the whole site, when the tag count data is installed.
  final int? siteCount;

  /// Ranking score, higher first.
  final double score;

  String? label;

  TasteItem(this.namespace, this.key, this.count, {this.siteCount, this.label, this.score = 0});

  String get displayName => label?.isNotEmpty == true ? label! : key;

  String get keyword => namespace == 'uploader' ? 'uploader:"$key"' : '$namespace:"$key\$"';

  Map<String, dynamic> toJson() => {'namespace': namespace, 'key': key, 'count': count, 'siteCount': siteCount, 'score': score};

  factory TasteItem.fromJson(Map json) =>
      TasteItem(json['namespace'], json['key'], json['count'] ?? 0, siteCount: json['siteCount'], score: (json['score'] as num?)?.toDouble() ?? 0);
}

/// A section of the taste page.
enum TasteSection { artist, group, uploader, parody, character, tag }

enum TasteRefreshPhase { idle, listing, fetching }

/// Collects the tags, artists, circles and uploaders of all favourited
/// galleries (favourites list + EH `gdata` API, 25 galleries per request) and
/// ranks them, so the user can see and follow their own taste.
///
/// Ranking is content based, as in classic recommenders:
/// * the favourites form a taste profile: a tf-idf vector over the content
///   tags, newer favourites weighing a little more;
/// * an artist / circle ranks by favourites (time-decayed) x how much of their
///   work the user favourited (smoothed hit rate) x how close their tags are to
///   the profile (cosine similarity);
/// * recommendations (see RecommendService): recall galleries by searching the
///   profile's most characteristic tag pairs, then rank them and their unknown
///   artists by similarity to the profile and rating.
///
/// Users often sort favourites into folders by style, so every analysis can
/// be limited to one favourites folder.
///
/// The collected data is cached in a JSON file; a refresh only fetches the
/// metadata of galleries not seen before.
class TasteService extends GetxController with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const String stateId = 'tasteState';

  /// Favourites are listed page by page; this bounds the work for huge collections.
  static const int maxGalleries = 3000;

  /// Tags present in nearly every gallery that say nothing about taste.
  static const Set<String> _uninformative = {
    'other:full color',
    'other:uncensored',
    'other:mosaic censorship',
    'other:multi-work series',
    'other:story arc',
    'other:already uploaded',
    'other:extraneous ads',
    'other:incomplete',
    'other:missing cover',
    'other:sample',
    'other:scanmark',
    'other:watermarked',
    'other:rough translation',
    'other:rough grammar',
    'other:paginated',
    'other:tankoubon',
    'other:anthology',
    'other:webtoon',
    'other:variant set',
    'other:non-h imageset',
    'other:ai generated',
    'other:thumbnail',
    'other:3d',
    'other:full censorship',
    'other:no penetration',
    'other:screenshots',
    'other:goudoushi',
  };

  static bool isUninformative(String tag) => _uninformative.contains(tag);

  /// Namespaces describing what a gallery is about.
  static const Set<String> contentNamespaces = {'female', 'male', 'mixed', 'other'};

  static bool isContentTag(String tag) {
    final int colon = tag.indexOf(':');
    return colon > 0 && contentNamespaces.contains(tag.substring(0, colon)) && !_uninformative.contains(tag);
  }

  /// Only for testing without an account: `--dart-define=JH_TASTE_SOURCE=<search>`
  /// analyses that public search instead of the favourites. Empty in real builds.
  static const String testSource = String.fromEnvironment('JH_TASTE_SOURCE');

  /// Roughly how many galleries EH has; only the order of magnitude matters.
  static const int siteGalleries = 3000000;

  /// Search requests used to find recommendations.
  static const int maxRecallQueries = 6;

  /// Galleries whose tags are fetched to rank recommendations.
  static const int maxRecallGalleries = 150;

  Map<int, TasteGallery> galleries = {};

  /// gids in the order of the favourites list (newest first).
  List<int> order = [];

  /// gid -> favourites folder (0-9).
  Map<int, int> folders = {};
  DateTime? updateTime;

  /// The favourites folder the taste page shows, null for all.
  int? folder;

  /// `namespace:key` -> galleries on the site, for the tags of the favourites.
  Map<String, int> siteCounts = {};

  TasteRefreshPhase phase = TasteRefreshPhase.idle;
  int progressDone = 0;
  int progressTotal = 0;
  String? error;

  Map<TasteSection, List<TasteItem>> sections = {};

  late final File _cacheFile;

  @override
  List<JHLifeCircleBean> get initDependencies => [pathService, log];

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
    _cacheFile = File(join((pathService.appSupportDir ?? pathService.getVisibleDir()).path, 'taste_cache.json'));
    if (await _cacheFile.exists()) {
      try {
        Map json = jsonDecode(await _cacheFile.readAsString());
        galleries = {for (var g in (json['galleries'] as List).map((e) => TasteGallery.fromJson(e))) g.gid: g};
        order = (json['order'] as List?)?.cast<int>() ?? [];
        updateTime = json['updateTime'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['updateTime']);
        folders = {for (MapEntry e in ((json['folders'] as Map?) ?? {}).entries) int.parse(e.key): e.value as int};
      } catch (e) {
        log.warning('Read taste cache failed', e);
      }
    }
  }

  @override
  Future<void> doAfterBeanReady() async {
    if (galleries.isNotEmpty) {
      siteCounts = await _loadSiteCounts();
      await _computeSections();
    }
  }

  bool get refreshing => phase != TasteRefreshPhase.idle;

  /// The favourites, newest first. Old caches have no order: gids are a fair
  /// stand-in for time.
  List<TasteGallery> get orderedGalleries {
    final List<TasteGallery> list = [
      for (int gid in order)
        if (galleries[gid] != null) galleries[gid]!
    ];
    if (list.length < galleries.length) {
      final Set<int> seen = list.map((g) => g.gid).toSet();
      list.addAll(galleries.values.where((g) => !seen.contains(g.gid)).toList()..sort((a, b) => b.gid.compareTo(a.gid)));
    }
    return list;
  }

  /// The favourites of [folder] (all for null), newest first.
  List<TasteGallery> galleriesOf(int? folder) {
    final List<TasteGallery> all = orderedGalleries;
    return folder == null ? all : all.where((g) => folders[g.gid] == folder).toList();
  }

  /// folder -> number of analysed favourites in it.
  Map<int, int> get folderCounts {
    final Map<int, int> counts = {};
    for (int gid in galleries.keys) {
      final int? f = folders[gid];
      if (f != null) {
        counts[f] = (counts[f] ?? 0) + 1;
      }
    }
    return Map.fromEntries(counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  Future<void> selectFolder(int? folder) async {
    this.folder = folder;
    updateSafely([stateId]);
    await _computeSections();
  }

  /// The favourites folder of a gallery in the favourites list.
  static int? folderOf(Gallery gallery) {
    if (gallery.favoriteTagIndex != null || testSource.isEmpty) {
      return gallery.favoriteTagIndex;
    }
    // test builds read a public search: fake folders by category
    return switch (gallery.category) { 'Doujinshi' => 0, 'Manga' => 1, _ => 2 };
  }

  Future<void> _saveCache() async {
    await _cacheFile.parent.create(recursive: true);
    await _cacheFile.writeAsString(jsonEncode({
      'updateTime': updateTime?.millisecondsSinceEpoch,
      'order': order,
      'folders': folders.map((gid, f) => MapEntry('$gid', f)),
      'galleries': galleries.values.map((g) => g.toJson()).toList(),
    }));
  }

  /// Lists all favourites and fetches the metadata of the new ones.
  Future<void> analyze() async {
    if (refreshing) {
      return;
    }
    error = null;
    phase = TasteRefreshPhase.listing;
    progressDone = 0;
    progressTotal = 0;
    updateSafely([stateId]);

    try {
      // 1. every favourite (gid + token), newest first
      final Map<int, Gallery> favorites = {};
      String? nextGid;
      do {
        final String? next = nextGid;
        GalleryPageInfo page = await withRetry(() => ehRequest.requestGalleryPage<GalleryPageInfo>(
              searchConfig: testSource.isEmpty ? SearchConfig(searchType: SearchType.favorite) : SearchConfig(keyword: testSource),
              nextGid: next,
              parser: EHSpiderParser.galleryPage2GalleryPageInfo,
            ));
        for (Gallery g in page.galleries) {
          favorites[g.gid] = g;
        }
        progressDone = favorites.length;
        updateSafely([stateId]);
        nextGid = page.nextGid;
        if (nextGid != null) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } while (nextGid != null && favorites.length < maxGalleries);

      // 2. metadata of galleries not cached yet
      galleries.removeWhere((gid, _) => !favorites.containsKey(gid));
      order = favorites.keys.toList();
      folders = {
        for (Gallery g in favorites.values)
          if (folderOf(g) != null) g.gid: folderOf(g)!
      };
      if (folder != null && !folders.containsValue(folder)) {
        folder = null;
      }
      final List<Gallery> missing = favorites.values.where((g) => !galleries.containsKey(g.gid)).toList();
      phase = TasteRefreshPhase.fetching;
      progressDone = 0;
      progressTotal = missing.length;
      updateSafely([stateId]);

      for (int i = 0; i < missing.length; i += 25) {
        final List<Gallery> batch = missing.sublist(i, math.min(missing.length, i + 25));
        List<GalleryMetadata> metadatas = await fetchMetadata(batch);
        for (GalleryMetadata m in metadatas) {
          galleries[m.galleryUrl.gid] = TasteGallery.fromMetadata(m);
        }
        progressDone = math.min(missing.length, i + 25);
        updateSafely([stateId]);
        await Future.delayed(const Duration(milliseconds: 700));
      }

      updateTime = DateTime.now();
      await _saveCache();
      siteCounts = await _loadSiteCounts();
      await _computeSections();
    } catch (e, stack) {
      log.error('Refresh taste failed', e, stack);
      error = e.toString();
      // keep what was fetched so the next run continues from there
      await _saveCache().catchError((_) {});
    } finally {
      phase = TasteRefreshPhase.idle;
      updateSafely([stateId]);
    }
  }

  /// `gdata` for up to 25 galleries.
  static Future<List<GalleryMetadata>> fetchMetadata(List<Gallery> batch) {
    return withRetry(() => ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
          list: batch.map((g) => (gid: g.gid, token: g.token)).toList(),
          parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
        ));
  }

  // ---------------------------------------------------------------- scoring

  /// Weight of the favourite at [position] (0 = newest) of [total]: newer
  /// favourites say more about the current taste, old ones still count half.
  static double recency(int position, int total) {
    final double halfLife = math.max(30, total / 4);
    return 0.5 + 0.5 * math.pow(0.5, position / halfLife);
  }

  /// Inverse document frequency of [tag] on the site; 1 without tag count data.
  static double idf(String tag, Map<String, int> siteCounts) {
    if (siteCounts.isEmpty) {
      return 1;
    }
    // a tag missing from the data is new or rare
    final int count = siteCounts[tag] ?? 1000;
    return math.max(0.1, math.log(siteGalleries / (count + 1)));
  }

  /// Content tag vector of weighted galleries: sublinear tf x idf.
  static Map<String, double> tagVector(Iterable<(TasteGallery, double)> weighted, Map<String, int> siteCounts) {
    final Map<String, double> tf = {};
    for ((TasteGallery, double) entry in weighted) {
      for (String tag in entry.$1.tags.toSet()) {
        if (isContentTag(tag)) {
          tf[tag] = (tf[tag] ?? 0) + entry.$2;
        }
      }
    }
    return tf.map((tag, f) => MapEntry(tag, math.log(1 + f) * idf(tag, siteCounts)));
  }

  /// The taste profile of favourites ordered newest first.
  static Map<String, double> profileOf(List<TasteGallery> ordered, Map<String, int> siteCounts) {
    return tagVector([for (int i = 0; i < ordered.length; i++) (ordered[i], recency(i, ordered.length))], siteCounts);
  }

  static double cosine(Map<String, double> a, Map<String, double> b) {
    if (a.isEmpty || b.isEmpty) {
      return 0;
    }
    final Map<String, double> small = a.length <= b.length ? a : b, large = identical(small, a) ? b : a;
    double dot = 0;
    small.forEach((tag, v) => dot += v * (large[tag] ?? 0));
    if (dot == 0) {
      return 0;
    }
    double norm(Map<String, double> v) => math.sqrt(v.values.fold(0.0, (sum, x) => sum + x * x));
    return dot / (norm(a) * norm(b));
  }

  /// How much of an artist's work the user favourited, smoothed so that 1 of 1
  /// does not beat 8 of 10, mapped to 0.6 .. 1 (0.8 when unknown).
  static double hitFactor(int count, int? siteCount) {
    if (siteCount == null) {
      return 0.8;
    }
    final double rate = math.min(1.0, (count + 0.5) / (siteCount + 5));
    return 0.6 + 0.4 * math.sqrt(rate);
  }

  /// Ranks the artists, circles, uploaders, series, characters and tags of
  /// [galleries], ordered newest first. [siteCounts] (`namespace:key` ->
  /// galleries on the site) enables idf weighting and artist hit rates.
  static Map<TasteSection, List<TasteItem>> rank(Iterable<TasteGallery> galleries, Map<String, int> siteCounts, {int limit = 60}) {
    final List<TasteGallery> list = galleries.toList();
    final Map<String, double> profile = profileOf(list, siteCounts);

    final Map<String, int> counts = {};
    final Map<String, List<(TasteGallery, double)>> works = {};
    for (int i = 0; i < list.length; i++) {
      final TasteGallery g = list[i];
      final double weight = recency(i, list.length);
      for (String tag in {...g.tags, if (g.uploader != null) 'uploader:${g.uploader}'}) {
        counts[tag] = (counts[tag] ?? 0) + 1;
        if (!isContentTag(tag)) {
          (works[tag] ??= []).add((g, weight));
        }
      }
    }

    double decayed(String tag) => works[tag]!.fold(0.0, (sum, e) => sum + e.$2);
    double similarity(String tag) => cosine(tagVector(works[tag]!, siteCounts), profile);

    List<TasteItem> byNamespace(Set<String> namespaces, double Function(String tag, int count, int? siteCount) score) {
      final List<TasteItem> items = [];
      counts.forEach((tag, count) {
        final int colon = tag.indexOf(':');
        if (colon < 0) {
          return;
        }
        final String namespace = tag.substring(0, colon), key = tag.substring(colon + 1);
        if (!namespaces.contains(namespace) || _uninformative.contains(tag) || (namespace == 'parody' && key == 'original')) {
          return;
        }
        final int? siteCount = siteCounts[tag];
        items.add(TasteItem(namespace, key, count, siteCount: siteCount, score: score(tag, count, siteCount)));
      });
      items.sort((a, b) {
        final int byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : b.count.compareTo(a.count);
      });
      return items.take(limit).toList();
    }

    // favourites (recent ones a bit more) x hit rate x closeness to the profile
    double creator(String tag, int count, int? siteCount) => decayed(tag) * hitFactor(count, siteCount) * (0.5 + similarity(tag));

    return {
      TasteSection.artist: byNamespace({'artist'}, creator),
      TasteSection.group: byNamespace({'group'}, creator),
      TasteSection.uploader: byNamespace({'uploader'}, (tag, count, _) => decayed(tag) * (0.5 + similarity(tag))),
      TasteSection.parody: byNamespace({'parody'}, (tag, count, _) => decayed(tag)),
      TasteSection.character: byNamespace({'character'}, (tag, count, _) => decayed(tag)),
      // tf-idf: a tag on 3 of your favourites and 20k galleries says more
      // about you than one on 5 favourites and 1.3M galleries
      TasteSection.tag: byNamespace(
        contentNamespaces,
        (tag, count, siteCount) => siteCount == null ? count.toDouble() : count * math.max(0.1, math.log(siteGalleries / (siteCount + 1))),
      ),
    };
  }

  /// Artists of the favourites, `namespace:key`.
  static Set<String> knownArtists(Iterable<TasteGallery> favorites) => {
        for (TasteGallery g in favorites)
          for (String tag in g.tags)
            if (tag.startsWith('artist:')) tag
      };

  /// The profile's strongest tags that are common enough to find galleries with.
  static List<String> seedTags(Map<String, double> profile, Map<String, int> siteCounts, {int count = 5}) {
    final List<MapEntry<String, double>> entries = profile.entries.where((e) => siteCounts.isEmpty || (siteCounts[e.key] ?? 0) >= 300).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(count).map((e) => e.key).toList();
  }

  /// The language of at least half of the favourites, if there is one.
  static String? dominantLanguage(List<TasteGallery> favorites) {
    const Set<String> notLanguages = {'translated', 'rewrite', 'speechless', 'text cleaned'};
    final Map<String, int> counts = {};
    for (TasteGallery g in favorites) {
      for (String tag in g.tags.toSet()) {
        if (tag.startsWith('language:') && !notLanguages.contains(tag.substring(9))) {
          counts[tag.substring(9)] = (counts[tag.substring(9)] ?? 0) + 1;
        }
      }
    }
    if (counts.isEmpty) {
      return null;
    }
    final MapEntry<String, int> top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return top.value * 2 >= favorites.length ? top.key : null;
  }

  /// Tags marking a drawing style rather than content: when most of a folder
  /// has one, every search for it requires it.
  static const List<String> styleTags = ['other:3d', 'other:webtoon', 'other:ai generated'];

  static List<String> styleTermsOf(List<TasteGallery> favorites) {
    return styleTags.where((tag) => favorites.where((g) => g.tags.contains(tag)).length * 2 > favorites.length).toList();
  }

  /// Categories making up at least a tenth of [favorites]; searches skip the others.
  static Set<String> categoriesOf(List<TasteGallery> favorites) {
    final Map<String, int> counts = {};
    for (TasteGallery g in favorites) {
      counts[g.category] = (counts[g.category] ?? 0) + 1;
    }
    return {
      for (MapEntry<String, int> e in counts.entries)
        if (e.key.isNotEmpty && e.value * 10 >= favorites.length) e.key
    };
  }

  static String searchTerm(String tag) {
    final int colon = tag.indexOf(':');
    return '${tag.substring(0, colon)}:"${tag.substring(colon + 1)}\$"';
  }

  /// Searches combining two seed tags each: specific enough to match the
  /// taste, broad enough to find artists the user does not know yet.
  /// [required] tags (the folder's style) go into every search.
  static List<String> recallQueries(List<String> seeds, String? language, {List<String> required = const []}) {
    String term(String tag) => searchTerm(tag);

    final String suffix = [
      ...required.map(searchTerm),
      if (language != null) 'language:"$language\$"',
    ].map((t) => ' $t').join();
    if (seeds.length == 1) {
      return ['${term(seeds.first)}$suffix'];
    }
    const List<(int, int)> pairs = [(0, 1), (0, 2), (1, 2), (0, 3), (1, 3), (2, 4), (0, 4), (2, 3)];
    return pairs
        .where((p) => p.$2 < seeds.length)
        .take(maxRecallQueries)
        .map((p) => '${term(seeds[p.$1])} ${term(seeds[p.$2])}$suffix')
        .toList();
  }

  /// Ranks the artists of [candidates] (gallery, rating) that are not in
  /// [known]: sum of their 3 closest galleries' similarity to [profile],
  /// scaled by rating.
  static List<TasteItem> recommend(List<(TasteGallery, double)> candidates, Map<String, double> profile, Set<String> known, Map<String, int> siteCounts, {int limit = 24}) {
    final Map<String, List<(double, double)>> byArtist = {};
    for ((TasteGallery, double) c in candidates) {
      final double similarity = cosine(tagVector([(c.$1, 1)], siteCounts), profile);
      for (String tag in c.$1.tags.toSet()) {
        if (tag.startsWith('artist:') && !known.contains(tag)) {
          (byArtist[tag] ??= []).add((similarity, c.$2));
        }
      }
    }

    final List<TasteItem> items = byArtist.entries.map((e) {
      final List<double> sims = e.value.map((v) => v.$1).toList()..sort((a, b) => b.compareTo(a));
      final double rating = e.value.fold(0.0, (sum, v) => sum + v.$2) / e.value.length;
      final double quality = (0.6 + 0.2 * (rating - 3)).clamp(0.4, 1.0);
      return TasteItem('artist', e.key.substring(7), e.value.length, siteCount: siteCounts[e.key], score: sims.take(3).fold(0.0, (a, b) => a + b) * quality);
    }).where((i) => i.score > 0).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return items.take(limit).toList();
  }

  /// Ranks recalled galleries (gallery, rating) by similarity to [profile],
  /// scaled by rating; galleries without a shared tag are dropped.
  static List<(int, double)> rankGalleries(List<(TasteGallery, double)> candidates, Map<String, double> profile, Map<String, int> siteCounts) {
    final List<(int, double)> ranked = [];
    for ((TasteGallery, double) c in candidates) {
      final double similarity = cosine(tagVector([(c.$1, 1)], siteCounts), profile);
      if (similarity > 0) {
        ranked.add((c.$1.gid, similarity * (0.6 + 0.2 * (c.$2 - 3)).clamp(0.4, 1.0)));
      }
    }
    return ranked..sort((a, b) => b.$2.compareTo(a.$2));
  }

  // ---------------------------------------------------------------- helpers

  /// Network hiccups (TLS resets, timeouts) should not end a long scan.
  static Future<T> withRetry<T>(Future<T> Function() request, {int attempts = 3}) async {
    for (int attempt = 1;; attempt++) {
      try {
        return await request();
      } on DioException catch (e) {
        if (attempt >= attempts) {
          rethrow;
        }
        log.warning('Taste request failed (attempt $attempt), retrying', e);
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  /// How common each tag is on the site, to favour tags that are typical of *this* collection.
  Future<Map<String, int>> _loadSiteCounts() async {
    final Set<String> tags = galleries.values.expand((g) => g.tags).toSet();
    final Map<String, int> siteCounts = {};
    try {
      final List<String> keys = tags.toList();
      // keep each query well below SQLite's variable limit
      for (int i = 0; i < keys.length; i += 500) {
        for (TagCountData c in await tagSearchOrderOptimizationService.batchSelectTagCount(keys.sublist(i, math.min(keys.length, i + 500)))) {
          siteCounts[c.namespaceWithKey] = c.count;
        }
      }
    } catch (e) {
      log.warning('Read tag counts for taste failed', e);
    }
    return siteCounts;
  }

  Future<void> _computeSections() async {
    final int? folder = this.folder;
    final Map<TasteSection, List<TasteItem>> result = rank(galleriesOf(folder), siteCounts);

    // translated names, when the tag translation database is installed
    try {
      for (List<TasteItem> items in result.values) {
        final List<TasteItem> tags = items.where((i) => i.namespace != 'uploader').toList();
        if (tags.isEmpty) {
          continue;
        }
        final List<TagData> translated = await tagTranslationService.translateTagDatasIfNeeded(tags.map((i) => TagData(namespace: i.namespace, key: i.key)).toList());
        for (int i = 0; i < tags.length && i < translated.length; i++) {
          tags[i].label = translated[i].tagName;
        }
      }
    } catch (e) {
      log.warning('Translate taste tags failed', e);
    }

    if (folder != this.folder) {
      // another folder was picked meanwhile
      return;
    }
    sections = result;
    updateSafely([stateId]);
  }
}
