import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:jhentai/src/utils/toast_util.dart';

import 'jh_service.dart';
import 'log.dart';

FollowService followService = FollowService();

/// Something the user follows: an uploader (scanlation group accounts), an
/// artist, a circle or any other tag. [namespace] is `uploader` for uploaders
/// and the EH tag namespace otherwise.
class FollowEntry {
  final String namespace;
  final String key;

  /// Translated tag name, if known when followed.
  String? label;

  /// Newest gallery the user has seen for this entry.
  int? seenGid;

  /// Newest gallery found by the last update check.
  int? latestGid;

  /// Galleries newer than [seenGid] found by the last check (capped at one result page).
  int newCount;

  final DateTime followedAt;

  FollowEntry({
    required this.namespace,
    required this.key,
    this.label,
    this.seenGid,
    this.latestGid,
    this.newCount = 0,
    DateTime? followedAt,
  }) : followedAt = followedAt ?? DateTime.now();

  bool get isUploader => namespace == 'uploader';

  String get id => '$namespace:$key';

  /// EH search keyword that lists this entry's galleries.
  String get keyword => isUploader ? 'uploader:"$key"' : '$namespace:"$key\$"';

  String get displayName => label?.isNotEmpty == true ? label! : key;

  Map<String, dynamic> toJson() => {
        'namespace': namespace,
        'key': key,
        'label': label,
        'seenGid': seenGid,
        'latestGid': latestGid,
        'newCount': newCount,
        'followedAt': followedAt.millisecondsSinceEpoch,
      };

  factory FollowEntry.fromJson(Map json) => FollowEntry(
        namespace: json['namespace'],
        key: json['key'],
        label: json['label'],
        seenGid: json['seenGid'],
        latestGid: json['latestGid'],
        newCount: json['newCount'] ?? 0,
        followedAt: json['followedAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['followedAt']),
      );
}

/// Uploaders, artists, circles and tags the user follows, with a light
/// "new galleries since you last looked" check (first result page only,
/// run on demand, never in the background).
class FollowService extends GetxController with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  static const String entriesId = 'followEntries';

  /// How long a check result stays fresh before the follow tab checks again.
  static const Duration checkInterval = Duration(hours: 1);

  List<FollowEntry> entries = [];
  DateTime? lastCheckTime;
  bool importedQuickSearch = false;

  bool checking = false;
  int checkedCount = 0;

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies..add(quickSearchService);

  @override
  ConfigEnum get configEnum => ConfigEnum.follow;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);
    entries = (map['entries'] as List? ?? []).map((e) => FollowEntry.fromJson(e)).toList();
    lastCheckTime = map['lastCheckTime'] == null ? null : DateTime.fromMillisecondsSinceEpoch(map['lastCheckTime']);
    importedQuickSearch = map['importedQuickSearch'] ?? false;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'entries': entries.map((e) => e.toJson()).toList(),
      'lastCheckTime': lastCheckTime?.millisecondsSinceEpoch,
      'importedQuickSearch': importedQuickSearch,
    });
  }

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  void doAfterBeanReady() {
    _importFavoriteUploaders();
  }

  /// Uploaders favourited before following existed were stored as quick searches.
  Future<void> _importFavoriteUploaders() async {
    if (importedQuickSearch) {
      return;
    }
    final RegExp uploader = RegExp(r'^uploader:"(.+)"$');
    for (SearchConfig config in quickSearchService.quickSearchConfigs.values) {
      Match? match = uploader.firstMatch(config.keyword?.trim() ?? '');
      if (match != null && (config.tags?.isEmpty ?? true) && find('uploader', match.group(1)!) == null) {
        entries.add(FollowEntry(namespace: 'uploader', key: match.group(1)!));
      }
    }
    importedQuickSearch = true;
    await saveBeanConfig();
  }

  FollowEntry? find(String namespace, String key) => entries.firstWhereOrNull((e) => e.namespace == namespace && e.key == key);

  bool isFollowing(String namespace, String key) => find(namespace, key) != null;

  int get totalNewCount => entries.fold(0, (sum, e) => sum + e.newCount);

  bool get needsCheck => lastCheckTime == null || DateTime.now().difference(lastCheckTime!) > checkInterval;

  Future<void> follow(String namespace, String key, {String? label}) async {
    if (isFollowing(namespace, key)) {
      return;
    }
    log.info('Follow $namespace:$key');
    entries.insert(0, FollowEntry(namespace: namespace, key: key, label: label));
    await saveBeanConfig();
    updateSafely([entriesId]);
    toast('followSuccess'.tr);
  }

  Future<void> unfollow(String namespace, String key) async {
    log.info('Unfollow $namespace:$key');
    entries.removeWhere((e) => e.namespace == namespace && e.key == key);
    await saveBeanConfig();
    updateSafely([entriesId]);
    toast('unfollowSuccess'.tr);
  }

  Future<void> toggle(String namespace, String key, {String? label}) {
    return isFollowing(namespace, key) ? unfollow(namespace, key) : follow(namespace, key, label: label);
  }

  /// The user opened this entry's galleries: everything up to the newest is seen.
  Future<void> markSeen(FollowEntry entry) async {
    if (entry.latestGid != null) {
      entry.seenGid = entry.latestGid;
    }
    entry.newCount = 0;
    await saveBeanConfig();
    updateSafely([entriesId]);
  }

  /// Looks at the first result page of every entry and counts galleries newer
  /// than the last seen one. Sequential with a pause so EH does not throttle us.
  Future<void> checkUpdates({bool force = false}) async {
    if (checking || entries.isEmpty || (!force && !needsCheck)) {
      return;
    }
    checking = true;
    checkedCount = 0;
    updateSafely([entriesId]);

    try {
      for (FollowEntry entry in List.of(entries)) {
        try {
          GalleryPageInfo page = await ehRequest.requestGalleryPage<GalleryPageInfo>(
            searchConfig: SearchConfig(keyword: entry.keyword),
            parser: EHSpiderParser.galleryPage2GalleryPageInfo,
          );
          List<int> gids = page.galleries.map((g) => g.gid).toList();
          if (gids.isNotEmpty) {
            int newest = gids.reduce((a, b) => a > b ? a : b);
            entry.latestGid = newest;
            // a fresh follow starts with everything seen
            entry.seenGid ??= newest;
            entry.newCount = gids.where((gid) => gid > entry.seenGid!).length;
          }
        } catch (e) {
          log.warning('Check follow update failed: ${entry.id}', e);
        }
        checkedCount++;
        updateSafely([entriesId]);
        await Future.delayed(const Duration(milliseconds: 600));
      }
      lastCheckTime = DateTime.now();
      await saveBeanConfig();
    } finally {
      checking = false;
      updateSafely([entriesId]);
    }
  }
}
