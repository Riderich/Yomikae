import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/pages/modern/favorite_folder_chips.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/follow_service.dart';
import 'package:jhentai/src/service/recommend_service.dart';
import 'package:jhentai/src/service/taste_service.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/search_util.dart';
import 'package:jhentai/src/widget/eh_gallery_collection.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

/// "For you": works and artists close to the taste of a favourites folder.
class RecommendPage extends StatefulWidget {
  const RecommendPage({super.key});

  @override
  State<RecommendPage> createState() => _RecommendPageState();
}

class _RecommendPageState extends State<RecommendPage> {
  @override
  void initState() {
    super.initState();
    // a folder from an older analysis may be gone
    if (recommendService.folder != null && !tasteService.folderCounts.containsKey(recommendService.folder)) {
      recommendService.selectFolder(null);
    }
    if (recommendService.current == null && tasteService.galleries.isNotEmpty) {
      recommendService.recommend(recommendService.folder);
    }
  }

  void _selectFolder(int? folder) {
    recommendService.selectFolder(folder);
    if (recommendService.current == null) {
      recommendService.recommend(folder);
    }
  }

  Future<void> _analyzeThenRecommend() async {
    await tasteService.analyze();
    if (tasteService.galleries.isNotEmpty) {
      await recommendService.recommend(recommendService.folder);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<TasteService>(
      id: TasteService.stateId,
      builder: (_) => GetBuilder<RecommendService>(
        id: RecommendService.stateId,
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text('recommendForYou'.tr),
            actions: [
              if (tasteService.galleries.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'refresh'.tr,
                  onPressed: recommendService.running ? null : () => recommendService.recommend(recommendService.folder),
                ),
            ],
          ),
          body: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!userSetting.hasLoggedIn() && TasteService.testSource.isEmpty) {
      return _message(context, Icons.lock_outline, 'needLoginToOperate'.tr, FilledButton(onPressed: () => toRoute(Routes.login), child: Text('login'.tr)));
    }
    if (tasteService.galleries.isEmpty) {
      if (tasteService.refreshing) {
        return _message(context, Icons.hourglass_top, 'recommendAnalyzing'.tr, const CircularProgressIndicator());
      }
      return _message(
        context,
        Icons.auto_awesome_outlined,
        'recommendNeedTaste'.tr,
        FilledButton.icon(icon: const Icon(Icons.play_arrow), label: Text('tasteStart'.tr), onPressed: _analyzeThenRecommend),
      );
    }

    final Recommendation? r = recommendService.current;
    final TextTheme text = Theme.of(context).textTheme;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          sliver: SliverList.list(
            children: [
              FavoriteFolderChips(
                selected: recommendService.folder,
                counts: tasteService.folderCounts,
                enabled: !recommendService.running,
                onSelected: _selectFolder,
              ),
              if (recommendService.running) _buildProgress(context),
              if (recommendService.error != null && !recommendService.running)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: Text('recommendFailed'.tr),
                    subtitle: Text(recommendService.error!),
                    trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: () => recommendService.recommend(recommendService.folder)),
                  ),
                ),
              if (r == null && !recommendService.running && recommendService.error == null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: Text('recommendIntro'.tr),
                    trailing: FilledButton(onPressed: () => recommendService.recommend(recommendService.folder), child: Text('recommendStart'.tr)),
                  ),
                ),
              if (r != null) ...[
                const SizedBox(height: 8),
                Text(_basis(r), style: text.bodySmall),
                if (r.artists.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _title(context, Icons.brush_outlined, 'recommendArtists'.tr),
                  const SizedBox(height: 8),
                  _buildArtists(r),
                ],
                const SizedBox(height: 20),
                _title(context, Icons.collections_bookmark_outlined, 'recommendGalleries'.tr),
                if (r.galleries.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('recommendEmpty'.tr)),
                const SizedBox(height: 4),
              ],
            ],
          ),
        ),
        if (r != null && r.galleries.isNotEmpty)
          EHGalleryCollection(
            context: context,
            galleries: r.galleries,
            listMode: styleSetting.listMode.value,
            loadingState: LoadingState.success,
            handleTapCard: (Gallery gallery) => toRoute(Routes.details, arguments: DetailsPageArgument(galleryUrl: gallery.galleryUrl, gallery: gallery)),
          ),
        if (r != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            sliver: SliverToBoxAdapter(
              child: Text(
                'recommendFooter'.trParams({'time': DateFormat('yyyy-MM-dd HH:mm').format(r.time)}),
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ),
          ),
      ],
    );
  }

  /// "Based on: glasses · ponytail · ... | chinese"
  String _basis(Recommendation r) {
    final List<String> parts = [
      r.seeds.map(recommendService.label).join(' · '),
      ...r.styles.map(recommendService.label),
      if (r.language != null) recommendService.label('language:${r.language}'),
    ];
    return 'recommendBasis'.trParams({'basis': parts.where((p) => p.isNotEmpty).join('  |  ')});
  }

  Widget _title(BuildContext context, IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildArtists(Recommendation r) {
    return GetBuilder<FollowService>(
      id: FollowService.entriesId,
      builder: (_) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: r.artists.map((item) {
          final bool following = followService.isFollowing(item.namespace, item.key);
          return InputChip(
            label: Text(item.displayName),
            tooltip: item.displayName == item.key ? null : '${item.namespace}:${item.key}',
            onPressed: () => newSearch(keyword: item.keyword, forceNewRoute: true),
            deleteIcon: Icon(following ? Icons.star : Icons.star_border, size: 18, color: following ? Colors.amber : null),
            deleteButtonTooltipMessage: following ? 'unfollow'.tr : 'follow'.tr,
            onDeleted: () => followService.toggle(item.namespace, item.key, label: item.label),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildProgress(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('recommendProgress'.trParams({'done': '${recommendService.progressDone}', 'total': '${recommendService.progressTotal}'})),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: recommendService.progressTotal == 0 ? null : recommendService.progressDone / recommendService.progressTotal),
          ],
        ),
      ),
    );
  }

  Widget _message(BuildContext context, IconData icon, String message, Widget action) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            action,
          ],
        ),
      ),
    );
  }
}
