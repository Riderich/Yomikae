import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/utils/toast_util.dart';

import '../widget/eh_search_config_dialog.dart';
import 'jh_service.dart';
import 'log.dart';

QuickSearchService quickSearchService = QuickSearchService();

class QuickSearchService extends GetxController with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  LinkedHashMap<String, SearchConfig> quickSearchConfigs = LinkedHashMap();

  final ScrollController drawerScrollController = _PersistentScrollController();

  @override
  ConfigEnum get configEnum => ConfigEnum.quickSearch;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    quickSearchConfigs = LinkedHashMap.from(map.map((key, value) => MapEntry(key, SearchConfig.fromJson(value))));
  }

  @override
  String toConfigString() {
    return jsonEncode(quickSearchConfigs);
  }

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  void doAfterBeanReady() {}

  Future<void> addQuickSearch(String name, SearchConfig searchConfig) async {
    if (quickSearchConfigs.containsKey(name)) {
      toast('sameNameExists'.tr, isShort: false);
      return;
    }

    Map<String, dynamic> queryParameters = searchConfig.toQueryParameters();
    for (MapEntry<String, SearchConfig> entry in quickSearchConfigs.entries) {
      if (mapEquals(entry.value.toQueryParameters(), queryParameters)) {
        toast('${'sameConfigExists'.tr}: ${entry.key}', isShort: false);
        return;
      }
    }

    log.info('Add quick search: $name');

    quickSearchConfigs[name] = searchConfig;
    await saveBeanConfig();
    updateSafely();
    
    toast('saveSuccess'.tr);
  }

  Future<void> removeQuickSearch(String name) async {
    log.info('Remove quick search: $name');

    quickSearchConfigs.remove(name);
    await saveBeanConfig();
    update();
  }

  /// 收藏的上传者以快速搜索的形式保存，关键词为 uploader:"xxx"
  static String uploaderKeyword(String uploader) => 'uploader:"$uploader"';

  /// 返回收藏该上传者的快速搜索名称，未收藏则返回 null。
  /// 只匹配关键词，用户在快速搜索里改了名字或分类过滤后仍能识别。
  String? findFavoriteUploaderName(String uploader) {
    String keyword = uploaderKeyword(uploader);
    for (MapEntry<String, SearchConfig> entry in quickSearchConfigs.entries) {
      if (entry.value.keyword?.trim() == keyword && (entry.value.tags?.isEmpty ?? true)) {
        return entry.key;
      }
    }
    return null;
  }

  bool isFavoriteUploader(String uploader) => findFavoriteUploaderName(uploader) != null;

  Future<void> toggleFavoriteUploader(String uploader) async {
    if (uploader.trim().isEmpty) {
      return;
    }

    String? existingName = findFavoriteUploaderName(uploader);
    if (existingName != null) {
      await removeQuickSearch(existingName);
      toast('unFavoriteUploaderSuccess'.tr);
      return;
    }

    await addQuickSearch('${'uploader'.tr}: $uploader', SearchConfig(keyword: uploaderKeyword(uploader)));
  }

  Future<void> reOrderQuickSearch(int oldIndex, int newIndex) async {
    log.info('reOrder quick search, oldIndex:$oldIndex, newIndex:$newIndex');

    List<MapEntry<String, SearchConfig>> entries = quickSearchConfigs.entries.toList();
    final MapEntry<String, SearchConfig> item = entries.removeAt(oldIndex);
    entries.insert(newIndex, item);

    quickSearchConfigs = LinkedHashMap.fromEntries(entries);
    await saveBeanConfig();
    updateSafely();
  }

  Future<void> handleUpdateQuickSearch(MapEntry<String, SearchConfig> oldConfig) async {
    Map<String, dynamic>? result = await Get.dialog(
      EHSearchConfigDialog(
        type: EHSearchConfigDialogType.update,
        quickSearchName: oldConfig.key,
        searchConfig: oldConfig.value,
      ),
    );

    if (result == null) {
      return;
    }

    log.info('Update quick search: ${oldConfig.key}');
    String quickSearchName = result['quickSearchName'];
    SearchConfig searchConfig = result['searchConfig'];

    if (oldConfig.key != quickSearchName && quickSearchConfigs.containsKey(quickSearchName)) {
      toast('sameNameExists'.tr);
      return;
    }

    /// keep order
    List<MapEntry<String, SearchConfig>> entries = quickSearchConfigs.entries.toList();
    int index = entries.indexWhere((e) => e.key == oldConfig.key);

    entries.removeAt(index);
    if (index == entries.length) {
      entries.add(MapEntry(quickSearchName, searchConfig));
    } else {
      entries.insert(index, MapEntry(quickSearchName, searchConfig));
    }

    quickSearchConfigs = LinkedHashMap.fromEntries(entries);
    await saveBeanConfig();
    updateSafely();
    
    toast('updateSuccess'.tr);
  }
}




/// 在 attach 时自动跳回上次记录的偏移量，解决 Drawer 卸载重挂后位置丢失的问题
class _PersistentScrollController extends ScrollController {
  double _savedOffset = 0.0;

  _PersistentScrollController() : super(keepScrollOffset: false) {
    addListener(_onScroll);
  }

  void _onScroll() {
    if (hasClients) {
      _savedOffset = offset;
    }
  }

  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    if (_savedOffset > 0.0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (hasClients && position.hasContentDimensions) {
          final double target = _savedOffset.clamp(position.minScrollExtent, position.maxScrollExtent);
          if ((position.pixels - target).abs() > 0.5) {
            position.jumpTo(target);
          }
        }
      });
    }
  }

  @override
  void dispose() {
    removeListener(_onScroll);
    super.dispose();
  }
}
