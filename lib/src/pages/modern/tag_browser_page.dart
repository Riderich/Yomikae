import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/database/dao/tag_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/service/follow_service.dart';
import 'package:jhentai/src/service/tag_search_order_service.dart';
import 'package:jhentai/src/service/tag_translation_service.dart';
import 'package:jhentai/src/setting/preference_setting.dart';
import 'package:jhentai/src/utils/search_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

/// Every known tag of one namespace (from the local tag translation database),
/// with translated names, most used first (when the tag count data is installed),
/// filterable. Tap to search, star to follow.
class TagBrowserPage extends StatefulWidget {
  const TagBrowserPage({super.key});

  @override
  State<TagBrowserPage> createState() => _TagBrowserPageState();
}

class _TagBrowserPageState extends State<TagBrowserPage> {
  static const int _pageSize = 60;

  late final String namespace = Get.arguments as String;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _filterController = TextEditingController();
  Timer? _debounce;

  final List<(TagData, int)> _tags = [];
  bool _loading = false;
  bool _noMore = false;
  bool? _hasDatabase;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels > _scrollController.position.maxScrollExtent - 600) {
        _loadMore();
      }
    });
    _init();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final int count = await TagDao.countTags();
    if (!mounted) {
      return;
    }
    setState(() => _hasDatabase = count > 0);
    if (count > 0) {
      _loadMore();
    }
  }

  void _onFilterChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _generation++;
      setState(() {
        _tags.clear();
        _noMore = false;
        _loading = false;
      });
      _loadMore();
    });
  }

  Future<void> _loadMore() async {
    if (_loading || _noMore || _hasDatabase != true) {
      return;
    }
    final int generation = _generation;
    setState(() => _loading = true);
    final List<(TagData, int)> page =
        await TagDao.selectTagsOfNamespaceWithCount(namespace, filter: _filterController.text, limit: _pageSize, offset: _tags.length);
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _tags.addAll(page);
      _noMore = page.length < _pageSize;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${'browseTags'.tr} · ${namespace.tr}')),
      body: _hasDatabase == null
          ? const Center(child: CircularProgressIndicator())
          : _hasDatabase == false
              ? _buildSetup(context)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: TextField(
                        controller: _filterController,
                        onChanged: _onFilterChanged,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.filter_list),
                          hintText: 'filterTagsHint'.tr,
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                      ),
                    ),
                    Obx(() => tagSearchOrderOptimizationService.loadingState.value == LoadingState.success
                        ? const SizedBox()
                        : _buildCountHint(context)),
                    Expanded(child: _buildList(context)),
                  ],
                ),
    );
  }

  Widget _buildCountHint(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.info_outline),
      title: Text('tagCountMissingHint'.tr),
      trailing: Obx(() => tagSearchOrderOptimizationService.loadingState.value == LoadingState.loading
          ? Text(tagSearchOrderOptimizationService.downloadProgress.value)
          : TextButton(
              onPressed: () async {
                await preferenceSetting.saveEnableTagZHSearchOrderOptimization(true);
                await tagSearchOrderOptimizationService.fetchDataFromGithub();
                _generation++;
                setState(() {
                  _tags.clear();
                  _noMore = false;
                  _loading = false;
                });
                _loadMore();
              },
              child: Text('download'.tr),
            )),
    );
  }

  Widget _buildSetup(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.travel_explore, size: 48),
            const SizedBox(height: 16),
            Text('tagDatabaseMissingHint'.tr, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Obx(() => tagTranslationService.loadingState.value == LoadingState.loading
                ? Column(children: [const CircularProgressIndicator(), const SizedBox(height: 8), Text(tagTranslationService.downloadProgress.value)])
                : FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: Text('downloadTagDatabase'.tr),
                    onPressed: () async {
                      await preferenceSetting.saveEnableTagZHTranslation(true);
                      await tagTranslationService.fetchDataFromGithub();
                      _init();
                    },
                  )),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_tags.isEmpty && !_loading) {
      return Center(child: Text('noData'.tr));
    }
    return GetBuilder<FollowService>(
      id: FollowService.entriesId,
      builder: (_) => ListView.builder(
        controller: _scrollController,
        itemCount: _tags.length + (_noMore ? 0 : 1),
        itemBuilder: (context, index) {
          if (index >= _tags.length) {
            return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
          }
          final (TagData tag, int count) = _tags[index];
          final String name = tag.tagName?.isNotEmpty == true ? tag.tagName! : tag.key;
          final bool following = followService.isFollowing(tag.namespace, tag.key);
          return ListTile(
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(count > 0 ? '${tag.key} · ${_formatCount(count)}' : tag.key, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: Icon(following ? Icons.star : Icons.star_border, color: following ? Colors.amber : null),
              tooltip: following ? 'unfollow'.tr : 'follow'.tr,
              onPressed: () => followService.toggle(tag.namespace, tag.key, label: tag.tagName),
            ),
            onTap: () => newSearch(keyword: '${tag.namespace}:"${tag.key}\$"', forceNewRoute: true),
            onLongPress: () => _showIntro(context, tag),
          );
        },
      ),
    );
  }

  void _showIntro(BuildContext context, TagData tag) {
    final String intro = (tag.intro ?? '').replaceAll(RegExp(r'<[^>]*>|!\[[^\]]*\]\([^)]*\)'), '').trim();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tag.tagName ?? tag.key, style: Theme.of(context).textTheme.titleLarge),
              Text('${tag.namespace}:${tag.key}', style: Theme.of(context).textTheme.bodySmall),
              if (intro.isNotEmpty) ...[const SizedBox(height: 12), Text(intro, maxLines: 12, overflow: TextOverflow.ellipsis)],
            ],
          ),
        ),
      ),
    );
  }

  static String _formatCount(int count) => NumberFormat.compact(locale: Get.locale?.toString()).format(count);
}
