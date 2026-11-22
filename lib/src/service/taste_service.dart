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
  final int count;

  /// How common the tag is on the whole site, when the tag count data is installed.
  final int? siteCount;

  String? label;

  TasteItem(this.namespace, this.key, this.count, {this.siteCount, this.label});

  String get displayName => label?.isNotEmpty == true ? label! : key;

  String get keyword => namespace == 'uploader' ? 'uploader:"$key"' : '$namespace:"$key\$"';
}

/// A section of the taste page.
enum TasteSection { artist, group, uploader, parody, character, tag }

enum TasteRefreshPhase { idle, listing, fetching }

/// Collects the tags, artists, circles and uploaders of all favourited
/// galleries (favourites list + EH `gdata` API, 25 galleries per request) and
/// ranks them, so the user can see and follow their own taste.
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

  /// Only for testing without an account: `--dart-define=JH_TASTE_SOURCE=<search>`
  /// analyses that public search instead of the favourites. Empty in real builds.
  static const String testSource = String.fromEnvironment('JH_TASTE_SOURCE');

  /// Roughly how many galleries EH has; only the order of magnitude matters.
  static const int siteGalleries = 3000000;

  Map<int, TasteGallery> galleries = {};
  DateTime? updateTime;

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
        updateTime = json['updateTime'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['updateTime']);
      } catch (e) {
        log.warning('Read taste cache failed', e);
      }
    }
  }

  @override
  Future<void> doAfterBeanReady() async {
    if (galleries.isNotEmpty) {
      await _computeSections();
    }
  }

  bool get refreshing => phase != TasteRefreshPhase.idle;

  Future<void> _saveCache() async {
    await _cacheFile.parent.create(recursive: true);
    await _cacheFile.writeAsString(jsonEncode({
      'updateTime': updateTime?.millisecondsSinceEpoch,
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
        GalleryPageInfo page = await _withRetry(() => ehRequest.requestGalleryPage<GalleryPageInfo>(
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
      final List<Gallery> missing = favorites.values.where((g) => !galleries.containsKey(g.gid)).toList();
      phase = TasteRefreshPhase.fetching;
      progressDone = 0;
      progressTotal = missing.length;
      updateSafely([stateId]);

      for (int i = 0; i < missing.length; i += 25) {
        final List<Gallery> batch = missing.sublist(i, math.min(missing.length, i + 25));
        List<GalleryMetadata> metadatas = await _withRetry(() => ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
              list: batch.map((g) => (gid: g.gid, token: g.token)).toList(),
              parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
            ));
        for (GalleryMetadata m in metadatas) {
          galleries[m.galleryUrl.gid] = TasteGallery.fromMetadata(m);
        }
        progressDone = math.min(missing.length, i + 25);
        updateSafely([stateId]);
        await Future.delayed(const Duration(milliseconds: 700));
      }

      updateTime = DateTime.now();
      await _saveCache();
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

  /// Ranks the artists, circles, uploaders, series, characters and tags of
  /// [galleries]. [siteCounts] (`namespace:key` -> galleries on the site) lets
  /// content tags typical of this collection beat tags that are everywhere.
  static Map<TasteSection, List<TasteItem>> rank(Iterable<TasteGallery> galleries, Map<String, int> siteCounts, {int limit = 60}) {
    final Map<String, int> counts = {};
    final Map<String, int> uploaders = {};
    for (TasteGallery g in galleries) {
      for (String tag in g.tags.toSet()) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
      if (g.uploader != null) {
        uploaders[g.uploader!] = (uploaders[g.uploader!] ?? 0) + 1;
      }
    }

    List<TasteItem> byNamespace(Set<String> namespaces, {bool distinctive = false}) {
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
        items.add(TasteItem(namespace, key, count, siteCount: siteCounts[tag]));
      });
      double score(TasteItem item) {
        if (!distinctive || item.siteCount == null) {
          return item.count.toDouble();
        }
        // tf-idf: a tag on 3 of your favourites and 20k galleries says more
        // about you than one on 5 favourites and 1.3M galleries
        return item.count * math.max(0.1, math.log(siteGalleries / (item.siteCount! + 1)));
      }

      items.sort((a, b) {
        final int byScore = score(b).compareTo(score(a));
        return byScore != 0 ? byScore : b.count.compareTo(a.count);
      });
      return items.take(limit).toList();
    }

    return {
      TasteSection.artist: byNamespace({'artist'}),
      TasteSection.group: byNamespace({'group'}),
      TasteSection.uploader: (uploaders.entries.map((e) => TasteItem('uploader', e.key, e.value)).toList()..sort((a, b) => b.count.compareTo(a.count))).take(limit).toList(),
      TasteSection.parody: byNamespace({'parody'}),
      TasteSection.character: byNamespace({'character'}),
      TasteSection.tag: byNamespace({'female', 'male', 'mixed', 'other'}, distinctive: true),
    };
  }

  /// Network hiccups (TLS resets, timeouts) should not end a long scan.
  static Future<T> _withRetry<T>(Future<T> Function() request, {int attempts = 3}) async {
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

  Future<void> _computeSections() async {
    final Set<String> tags = galleries.values.expand((g) => g.tags).toSet();

    // how common each tag is on the site, to favour tags that are typical of *this* collection
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

    final Map<TasteSection, List<TasteItem>> result = rank(galleries.values, siteCounts);

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

    sections = result;
    updateSafely([stateId]);
  }
}
