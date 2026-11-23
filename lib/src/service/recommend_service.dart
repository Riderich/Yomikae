import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_metadata.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/path_service.dart';
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

  Recommendation({required this.time, required this.galleries, required this.artists, required this.seeds, required this.styles, this.language});

  Map<String, dynamic> toJson() => {
        'time': time.millisecondsSinceEpoch,
        'galleries': galleries.map((g) => g.toJson()).toList(),
        'artists': artists.map((a) => a.toJson()).toList(),
        'seeds': seeds,
        'styles': styles,
        'language': language,
      };

  factory Recommendation.fromJson(Map json) => Recommendation(
        time: DateTime.fromMillisecondsSinceEpoch(json['time']),
        galleries: (json['galleries'] as List).map((g) => Gallery.fromJson(Map<String, dynamic>.from(g))).toList(),
        artists: (json['artists'] as List).map((a) => TasteItem.fromJson(a)).toList(),
        seeds: (json['seeds'] as List).cast<String>(),
        styles: ((json['styles'] as List?) ?? []).cast<String>(),
        language: json['language'],
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

  /// Recommendations shown per folder.
  static const int maxGalleries = 60;
  static const int maxArtists = 16;

  /// folder (null = all favourites) -> last recommendation.
  final Map<int?, Recommendation> results = {};

  /// The folder the page shows.
  int? folder;

  /// The folder being computed, while [running].
  int? runningFolder;
  bool running = false;
  int progressDone = 0;
  int progressTotal = 0;
  String? error;

  /// `namespace:key` -> translated name, for the tags shown.
  final Map<String, String> labels = {};

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
    }));
  }

  /// Searches and ranks recommendations for [folder] (null = all favourites).
  Future<void> recommend(int? folder) async {
    final List<TasteGallery> favorites = tasteService.galleriesOf(folder);
    if (running || favorites.isEmpty) {
      return;
    }
    running = true;
    runningFolder = folder;
    error = null;
    progressDone = 0;
    progressTotal = 0;
    updateSafely([stateId]);

    try {
      final Map<String, int> siteCounts = tasteService.siteCounts;
      final Map<String, double> profile = TasteService.profileOf(favorites, siteCounts);
      final List<String> seeds = TasteService.seedTags(profile, siteCounts);
      final String? language = TasteService.dominantLanguage(favorites);
      final List<String> styles = TasteService.styleTermsOf(favorites);
      final Set<String> categories = TasteService.categoriesOf(favorites);
      final List<String> queries = TasteService.recallQueries(seeds, language, required: styles);
      if (queries.isEmpty) {
        error = 'recommendNoTags'.tr;
        return;
      }
      progressTotal = queries.length + (TasteService.maxRecallGalleries / 25).ceil();
      updateSafely([stateId]);

      // recall
      final Map<int, Gallery> found = {};
      for (String query in queries) {
        GalleryPageInfo page = await TasteService.withRetry(() => ehRequest.requestGalleryPage<GalleryPageInfo>(
              searchConfig: _searchConfig(query, categories),
              parser: EHSpiderParser.galleryPage2GalleryPageInfo,
            ));
        for (Gallery g in page.galleries) {
          if (!tasteService.galleries.containsKey(g.gid) && found.length < TasteService.maxRecallGalleries) {
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
      final List<(int, double)> ranked = TasteService.rankGalleries(rated, profile, siteCounts);
      results[folder] = Recommendation(
        time: DateTime.now(),
        galleries: ranked.take(maxGalleries).map((r) => found[r.$1]!).toList(),
        artists: TasteService.recommend(rated, profile, TasteService.knownArtists(tasteService.galleries.values), siteCounts, limit: maxArtists),
        seeds: seeds,
        styles: styles,
        language: language,
      );
      await _saveCache();
      await _translate();
    } catch (e, stack) {
      log.error('Recommend failed', e, stack);
      error = e.toString();
    } finally {
      running = false;
      updateSafely([stateId]);
    }
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
  Future<void> _translate() async {
    final List<String> tags = {
      for (Recommendation r in results.values) ...[...r.seeds, ...r.styles, ...r.artists.map((a) => '${a.namespace}:${a.key}')]
    }.toList();
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
