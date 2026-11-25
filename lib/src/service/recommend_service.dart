import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_metadata.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/service/follow_service.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/recommend_feedback.dart';
import 'package:jhentai/src/service/tag_translation_service.dart';
import 'package:jhentai/src/service/taste_service.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:path/path.dart';

import 'jh_service.dart';
import 'log.dart';

RecommendService recommendService = RecommendService();

/// Galleries and artists recommended for one favourites folder (or all).
class Recommendation {
  final DateTime time;

  /// Best match first.
  final List<Gallery> galleries;
  final List<TasteItem> artists;

  /// What the searches were built from: profile tags, style tags, language.
  final List<String> seeds;
  final List<String> styles;
  final String? language;

  /// gid -> `namespace:key` tags of [galleries], for feedback.
  final Map<int, List<String>> tags;

  /// More of the taste's strongest tags besides [seeds], to rate.
  final List<String> tasteTags;

  Recommendation({
    required this.time,
    required this.galleries,
    required this.artists,
    required this.seeds,
    required this.styles,
    this.language,
    Map<int, List<String>>? tags,
    List<String>? tasteTags,
  })  : tags = tags ?? {},
        tasteTags = tasteTags ?? [];

  Map<String, dynamic> toJson() => {
        'time': time.millisecondsSinceEpoch,
        'galleries': galleries.map((g) => g.toJson()).toList(),
        'artists': artists.map((a) => a.toJson()).toList(),
        'seeds': seeds,
        'styles': styles,
        'language': language,
        'tags': tags.map((gid, t) => MapEntry('$gid', t)),
        'tasteTags': tasteTags,
      };

  factory Recommendation.fromJson(Map json) => Recommendation(
        time: DateTime.fromMillisecondsSinceEpoch(json['time']),
        galleries: (json['galleries'] as List).map((g) => Gallery.fromJson(Map<String, dynamic>.from(g))).toList(),
        artists: (json['artists'] as List).map((a) => TasteItem.fromJson(a)).toList(),
        seeds: (json['seeds'] as List).cast<String>(),
        styles: ((json['styles'] as List?) ?? []).cast<String>(),
        language: json['language'],
        tags: {for (MapEntry e in ((json['tags'] as Map?) ?? const {}).entries) int.parse(e.key): (e.value as List).cast<String>()},
        tasteTags: ((json['tasteTags'] as List?) ?? const []).cast<String>(),
      );
}

/// "For you": works and artists the user has not favourited yet that are
/// close to the taste of a favourites folder.
///
/// Recall: a few searches pairing the folder's most characteristic tags,
/// limited to its language, categories and drawing style. Rank: tag
/// similarity to the folder's taste profile, scaled by rating.
class RecommendService extends GetxController with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const String stateId = 'recommendState';

  /// Recommendations shown per folder after a fresh round, and added by
  /// each "more" round of the feed.
  static const int maxGalleries = 60;
  static const int moreGalleries = 40;
  static const int maxArtists = 16;

  /// Read galleries used as a (weaker) taste signal, newest first.
  static const int maxHistory = 500;

  /// How much a read gallery counts compared with a favourite.
  static const double historyWeight = 0.5;

  /// A recommendation older than this is redone when the feed is shown.
  static const Duration staleAfter = Duration(hours: 12);

  /// Favourites are read again when their analysis is older than this.
  static const Duration tasteStaleAfter = Duration(days: 3);

  /// folder (null = all favourites) -> last recommendation.
  final Map<int?, Recommendation> results = {};

  /// The folder the page shows.
  int? folder;

  /// The folder being computed, while [running].
  int? runningFolder;
  bool running = false;

  /// Whether the running round adds to the feed instead of starting over.
  bool runningMore = false;

  /// folder key -> a "more" round found nothing new.
  final Map<String, bool> _exhausted = {};

  /// Read galleries (not favourited), newest first, and all read gids.
  List<TasteGallery> _history = [];
  Set<int> _readGids = {};

  /// The shortest time between the end of a round and the next "more" round.
  static const Duration moreInterval = Duration(seconds: 20);
  DateTime? _lastRoundEnd;
  bool _moreWaiting = false;

  bool _autoBusy = false;
  bool _autoAnalyzed = false;
  DateTime? _lastEnsure;
  int progressDone = 0;
  int progressTotal = 0;
  String? error;

  /// `namespace:key` -> translated name, for the tags shown.
  final Map<String, String> labels = {};

  RecommendFeedback feedback = RecommendFeedback();

  /// folder key -> votes given since its last recommendation.
  final Map<String, int> _newVotes = {};

  late final File _cacheFile;

  @override
  List<JHLifeCircleBean> get initDependencies => [pathService, log, tasteService];

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
    _cacheFile = File(join((pathService.appSupportDir ?? pathService.getVisibleDir()).path, 'recommend_cache.json'));
    if (await _cacheFile.exists()) {
      try {
        Map json = jsonDecode(await _cacheFile.readAsString());
        for (MapEntry e in (json['results'] as Map).entries) {
          results[e.key == 'all' ? null : int.parse(e.key)] = Recommendation.fromJson(e.value);
        }
        folder = json['folder'];
        if (json['feedback'] != null) {
          feedback = RecommendFeedback.fromJson(json['feedback']);
        }
      } catch (e) {
        log.warning('Read recommend cache failed', e);
      }
    }
  }

  @override
  Future<void> doAfterBeanReady() async {
    if (results.isNotEmpty) {
      await _translate();
    }
  }

  Recommendation? get current => results[folder];

  String label(String tag) => labels[tag] ?? tag.substring(tag.indexOf(':') + 1);

  void selectFolder(int? folder) {
    this.folder = folder;
    updateSafely([stateId]);
    _saveCache().catchError((_) {});
  }

  Future<void> _saveCache() async {
    await _cacheFile.parent.create(recursive: true);
    await _cacheFile.writeAsString(jsonEncode({
      'folder': folder,
      'results': results.map((f, r) => MapEntry(f == null ? 'all' : '$f', r.toJson())),
      'feedback': feedback.toJson(),
    }));
  }

  // -------------------------------------------------------------- feedback

  /// Votes given in the shown folder since its last recommendation.
  int get newVotes => _newVotes[RecommendFeedback.keyOf(folder)] ?? 0;

  int tagVote(String tag) => feedback.tagVote(folder, tag);

  /// The vote of [tag] for another folder than the one shown, e.g. from the
  /// taste page.
  int tagVoteIn(int? folder, String tag) => feedback.tagVote(folder, tag);

  int galleryVote(int gid) => feedback.galleryVote(folder, gid);

  /// The tags of a recommended gallery: from its metadata when known.
  List<String> tagsOf(Gallery gallery) {
    for (Recommendation r in results.values) {
      final List<String>? tags = r.tags[gallery.gid];
      if (tags != null) {
        return tags;
      }
    }
    return [
      for (List<GalleryTag> tags in gallery.tags.values)
        for (GalleryTag t in tags) '${t.tagData.namespace}:${t.tagData.key}'
    ];
  }

  void voteTag(String tag, int vote) => voteTagIn(folder, tag, vote);

  void voteTagIn(int? folder, String tag, int vote) {
    feedback.voteTag(folder, tag, vote);
    _voted(folder);
  }

  /// A disliked gallery leaves the shown list; returns where it was so that
  /// [undoDislike] can put it back.
  int voteGallery(Gallery gallery, int vote) {
    feedback.voteGallery(folder, gallery.gid, tagsOf(gallery), vote);
    int index = -1;
    if (vote < 0) {
      index = current?.galleries.indexWhere((g) => g.gid == gallery.gid) ?? -1;
      if (index >= 0) {
        current!.galleries.removeAt(index);
      }
    }
    _voted(folder);
    return index;
  }

  void undoDislike(Gallery gallery, int index) {
    feedback.voteGallery(folder, gallery.gid, const [], 0);
    final Recommendation? r = current;
    if (index >= 0 && r != null && !r.galleries.any((g) => g.gid == gallery.gid)) {
      r.galleries.insert(math.min(index, r.galleries.length), gallery);
    }
    _voted(folder);
  }

  void clearFeedback() {
    feedback.clear();
    _newVotes.clear();
    updateSafely([stateId]);
    _saveCache().catchError((_) {});
  }

  void _voted(int? folder) {
    final String key = RecommendFeedback.keyOf(folder);
    _newVotes[key] = (_newVotes[key] ?? 0) + 1;
    updateSafely([stateId]);
    _saveCache().catchError((_) {});
  }

  final Map<String, List<String>> _tasteTagsMemo = {};

  /// The taste tags to rate for the shown folder, besides the seeds.
  List<String> get tasteTags {
    final Recommendation? r = current;
    if (r == null) {
      return const [];
    }
    if (r.tasteTags.isNotEmpty) {
      return r.tasteTags;
    }
    // recommended by an older version, which did not keep them
    return _tasteTagsMemo.putIfAbsent(RecommendFeedback.keyOf(folder), () {
      final Map<String, int> siteCounts = tasteService.siteCounts;
      final Map<String, double> profile = feedback.adjustProfile(
        folder,
        profileOf(feedback.filterFavorites(tasteService.galleriesOf(folder)), folder == null ? feedback.filterFavorites(_history) : const [], siteCounts),
        siteCounts,
      );
      final List<String> tags = RecommendFeedback.tasteTags(profile, siteCounts, count: 30 + r.seeds.length).where((t) => !r.seeds.contains(t)).take(30).toList();
      translateTags(tags);
      return tags;
    });
  }

  /// Translated names for tags shown outside the recommendation itself.
  Future<void> translateTags(Iterable<String> tags) => _translate(extra: tags);

  /// Whether there is anything to recommend from: favourites or, for all
  /// favourites, reading history.
  bool canRecommend(int? folder) => tasteService.galleriesOf(folder).isNotEmpty || (folder == null && _history.isNotEmpty);

  bool get exhausted => _exhausted[RecommendFeedback.keyOf(folder)] ?? false;

  /// Reads the reading history: a taste signal, and works not to recommend.
  Future<void> _loadHistory() async {
    try {
      final List<GalleryHistoryV2Data> rows = await historyService.getLatest10000RawHistory();
      _readGids = rows.map((r) => r.gid).toSet();
      final List<TasteGallery> history = [];
      for (GalleryHistoryV2Data row in rows) {
        if (history.length >= maxHistory) {
          break;
        }
        if (tasteService.galleries.containsKey(row.gid)) {
          continue;
        }
        final GalleryHistoryModel h = GalleryHistoryModel.fromJson(jsonDecode(row.jsonBody));
        if (h.tags.isNotEmpty) {
          history.add(TasteGallery(
            gid: h.galleryUrl.gid,
            token: h.galleryUrl.token,
            title: h.title,
            category: h.category,
            uploader: h.uploader.isEmpty ? null : h.uploader,
            tags: h.tags,
          ));
        }
      }
      _history = history;
    } catch (e) {
      log.warning('Read history for recommendations failed', e);
    }
  }

  /// Shows the feed fresh: reads the favourites the first time (and when
  /// their analysis is old), and recommends again when the last
  /// recommendation is old. Cheap to call often.
  Future<void> ensureFresh() async {
    final DateTime now = DateTime.now();
    if (running || tasteService.refreshing || _autoBusy || (_lastEnsure != null && now.difference(_lastEnsure!) < const Duration(minutes: 1))) {
      return;
    }
    _lastEnsure = now;
    _autoBusy = true;
    try {
      final bool favoritesReadable = userSetting.hasLoggedIn() || TasteService.testSource.isNotEmpty;
      final DateTime? analyzed = tasteService.updateTime;
      if (favoritesReadable && !_autoAnalyzed && (analyzed == null || now.difference(analyzed) > tasteStaleAfter)) {
        _autoAnalyzed = true;
        await tasteService.analyze();
      }
      await _loadHistory();
      final Recommendation? r = results[folder];
      if (canRecommend(folder) && (r == null || now.difference(r.time) > staleAfter)) {
        await recommend(folder);
      } else {
        updateSafely([stateId]);
      }
    } finally {
      _autoBusy = false;
    }
  }

  /// The next part of the feed: more works for the shown folder, searched
  /// from where the last round left off.
  Future<void> loadMore() async {
    if (running || _moreWaiting || current == null || exhausted) {
      return;
    }
    // every round is a dozen requests: keep rounds apart, or EH bans the IP
    final DateTime? last = _lastRoundEnd;
    if (last != null) {
      final Duration wait = moreInterval - DateTime.now().difference(last);
      if (wait > Duration.zero) {
        _moreWaiting = true;
        await Future.delayed(wait);
        _moreWaiting = false;
      }
    }
    await recommend(folder, more: true);
  }

  /// Searches and ranks recommendations for [folder] (null = all favourites,
  /// together with the reading history). With [more], adds works to the
  /// current recommendation instead of starting over.
  Future<void> recommend(int? folder, {bool more = false}) async {
    if (running) {
      return;
    }
    // claimed before the first await, so that two calls never run together
    running = true;
    if (_readGids.isEmpty) {
      await _loadHistory();
    }
    final List<TasteGallery> favorites = feedback.filterFavorites(tasteService.galleriesOf(folder));
    final List<TasteGallery> basis = [...favorites, if (folder == null) ...feedback.filterFavorites(_history)];
    final Recommendation? previous = results[folder];
    if (basis.isEmpty || (more && previous == null)) {
      running = false;
      updateSafely([stateId]);
      return;
    }
    runningMore = more;
    runningFolder = folder;
    error = null;
    progressDone = 0;
    progressTotal = 0;
    if (!more) {
      _exhausted.remove(RecommendFeedback.keyOf(folder));
    }
    updateSafely([stateId]);

    try {
      final Map<String, int> siteCounts = tasteService.siteCounts;
      final Map<String, double> profile = feedback.adjustProfile(folder, profileOf(favorites, folder == null ? feedback.filterFavorites(_history) : const [], siteCounts), siteCounts);
      final List<String> seeds = feedback.adjustSeeds(folder, TasteService.seedTags(profile, siteCounts, count: 8), siteCounts);
      final String? language = TasteService.dominantLanguage(basis);
      final List<String> styles = TasteService.styleTermsOf(basis);
      final Set<String> categories = TasteService.categoriesOf(basis);
      final Set<int> alreadyShown = more ? previous!.galleries.map((g) => g.gid).toSet() : const {};
      final List<String> queries = TasteService.recallQueries(seeds, language, required: styles);
      if (queries.isEmpty) {
        error = 'recommendNoTags'.tr;
        return;
      }
      progressTotal = queries.length + (TasteService.maxRecallGalleries / 25).ceil();
      updateSafely([stateId]);

      // recall, each search continuing where the last round left off
      final Map<int, Gallery> found = {};
      final Map<String, String> cursors = feedback.cursors[RecommendFeedback.keyOf(folder)] ??= {};
      for (String query in queries) {
        GalleryPageInfo page = await TasteService.withRetry(() => ehRequest.requestGalleryPage<GalleryPageInfo>(
              nextGid: cursors[query],
              searchConfig: _searchConfig(query, categories),
              parser: EHSpiderParser.galleryPage2GalleryPageInfo,
            ));
        if (page.nextGid == null) {
          cursors.remove(query);
        } else {
          cursors[query] = page.nextGid!;
        }
        for (Gallery g in page.galleries) {
          if (!tasteService.galleries.containsKey(g.gid) &&
              !_readGids.contains(g.gid) &&
              !alreadyShown.contains(g.gid) &&
              found.length < TasteService.maxRecallGalleries) {
            found.putIfAbsent(g.gid, () => g);
          }
        }
        progressDone++;
        updateSafely([stateId]);
        await Future.delayed(const Duration(milliseconds: 600));
      }

      // full tags and ratings
      final List<Gallery> candidates = found.values.toList();
      progressTotal = queries.length + (candidates.length / 25).ceil();
      final List<(TasteGallery, double)> rated = [];
      for (int i = 0; i < candidates.length; i += 25) {
        for (GalleryMetadata m in await TasteService.fetchMetadata(candidates.sublist(i, math.min(candidates.length, i + 25)))) {
          rated.add((TasteGallery.fromMetadata(m), m.rating));
        }
        progressDone++;
        updateSafely([stateId]);
        await Future.delayed(const Duration(milliseconds: 700));
      }

      // rank
      final List<(int, double)> ranked = feedback.rank(folder, rated, profile, siteCounts);
      final List<int> kept = ranked.take(more ? moreGalleries : maxGalleries).map((r) => r.$1).toList();
      final Map<int, List<String>> tagsByGid = {for ((TasteGallery, double) r in rated) r.$1.gid: r.$1.tags};
      final Set<String> knownArtists = {
        ...TasteService.knownArtists(tasteService.galleries.values),
        // artists already followed are not news either
        for (FollowEntry e in followService.entries) '${e.namespace}:${e.key}',
        ...feedback.likedTagsOf(folder),
        ...feedback.dislikedTags,
      };
      final List<(TasteGallery, double)> artistCandidates =
          rated.where((r) => !feedback.dislikedGalleries.containsKey(r.$1.gid) && !r.$1.tags.any(feedback.dislikedTags.contains)).toList();
      if (more) {
        if (kept.isEmpty) {
          _exhausted[RecommendFeedback.keyOf(folder)] = true;
        }
        previous!.galleries.addAll(kept.map((gid) => found[gid]!));
        previous.tags.addAll({for (int gid in kept) gid: tagsByGid[gid] ?? const []});
        feedback.addShown(folder, kept);
        await _saveCache();
        return;
      }
      results[folder] = Recommendation(
        time: DateTime.now(),
        galleries: kept.map((gid) => found[gid]!).toList(),
        artists: TasteService.recommend(artistCandidates, profile, knownArtists, siteCounts, limit: maxArtists),
        seeds: seeds,
        tasteTags: RecommendFeedback.tasteTags(profile, siteCounts, count: 30 + seeds.length).where((t) => !seeds.contains(t)).take(30).toList(),
        styles: styles,
        language: language,
        tags: {for (int gid in kept) gid: tagsByGid[gid] ?? const []},
      );
      feedback.addShown(folder, kept);
      _tasteTagsMemo.remove(RecommendFeedback.keyOf(folder));
      _newVotes.remove(RecommendFeedback.keyOf(folder));
      await _saveCache();
      await _translate();
    } catch (e, stack) {
      log.error('Recommend failed', e, stack);
      error = e.toString();
    } finally {
      running = false;
      runningMore = false;
      _lastRoundEnd = DateTime.now();
      updateSafely([stateId]);
    }
  }

  /// The taste profile: favourites (recent ones a bit more) and, weaker,
  /// read galleries.
  static Map<String, double> profileOf(List<TasteGallery> favorites, List<TasteGallery> history, Map<String, int> siteCounts) {
    return TasteService.tagVector([
      for (int i = 0; i < favorites.length; i++) (favorites[i], TasteService.recency(i, favorites.length)),
      for (int i = 0; i < history.length; i++) (history[i], historyWeight * TasteService.recency(i, history.length)),
    ], siteCounts);
  }

  static SearchConfig _searchConfig(String query, Set<String> categories) {
    final SearchConfig config = SearchConfig(keyword: query, minimumRating: 4);
    if (categories.isEmpty) {
      return config;
    }
    config
      ..includeDoujinshi = categories.contains('Doujinshi')
      ..includeManga = categories.contains('Manga')
      ..includeArtistCG = categories.contains('Artist CG')
      ..includeGameCg = categories.contains('Game CG')
      ..includeWestern = categories.contains('Western')
      ..includeNonH = categories.contains('Non-H')
      ..includeImageSet = categories.contains('Image Set')
      ..includeCosplay = categories.contains('Cosplay')
      ..includeAsianPorn = categories.contains('Asian Porn')
      ..includeMisc = categories.contains('Misc');
    return config;
  }

  /// Translated names of the seed tags and artists, when the database is installed.
  Future<void> _translate({Iterable<String> extra = const []}) async {
    final List<String> tags = {
      for (Recommendation r in results.values) ...[...r.seeds, ...r.tasteTags, ...r.styles, ...r.artists.map((a) => '${a.namespace}:${a.key}')],
      ...feedback.dislikedTags,
      for (Set<String> liked in feedback.likedTags.values) ...liked,
      ...extra,
    }.where((t) => t.contains(':') && !labels.containsKey(t)).toList();
    if (tags.isEmpty) {
      return;
    }
    try {
      final List<TagData> translated = await tagTranslationService.translateTagDatasIfNeeded(tags.map((t) {
        final int colon = t.indexOf(':');
        return TagData(namespace: t.substring(0, colon), key: t.substring(colon + 1));
      }).toList());
      for (int i = 0; i < tags.length && i < translated.length; i++) {
        if (translated[i].tagName?.isNotEmpty == true) {
          labels[tags[i]] = translated[i].tagName!;
        }
      }
      for (Recommendation r in results.values) {
        for (TasteItem a in r.artists) {
          a.label = labels['${a.namespace}:${a.key}'];
        }
      }
    } catch (e) {
      log.warning('Translate recommendation tags failed', e);
    }
    updateSafely([stateId]);
  }
}
