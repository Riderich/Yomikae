import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/pages/gallery/dashboard/dashboard_page.dart';
import 'package:jhentai/src/pages/modern/favorite_folder_chips.dart';
import 'package:jhentai/src/pages/modern/recommend_feedback_sheet.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/recommend_service.dart';
import 'package:jhentai/src/service/taste_service.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_gallery_collection.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

/// What opening the app shows: the rank list and popular strips, then an
/// endless feed of works picked by the user's taste (favourites, reading
/// history and feedback). Taste is read and the feed refreshed on its own;
/// scrolling to the end recommends more.
class DiscoverPage extends DashboardPage {
  const DiscoverPage({super.key});

  @override
  AppBar? buildAppBar(BuildContext context) {
    return AppBar(
      title: Text('discover'.tr),
      centerTitle: false,
      actions: [
        IconButton(icon: const Icon(Icons.search), tooltip: 'search'.tr, onPressed: () => toRoute(Routes.mobileV2Search)),
      ],
    );
  }

  @override
  List<Widget> buildMainSlivers(BuildContext context) {
    return [
      SliverToBoxAdapter(child: _FeedHeader()),
      GetBuilder<RecommendService>(
        id: RecommendService.stateId,
        builder: (_) {
          final Recommendation? r = recommendService.current;
          if (r == null || r.galleries.isEmpty) {
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          }
          return EHGalleryCollection(
            key: const PageStorageKey('discoverFeed'),
            context: context,
            galleries: r.galleries,
            listMode: styleSetting.listMode.value,
            loadingState: LoadingState.success,
            handleTapCard: (Gallery gallery) => toRoute(Routes.details, arguments: DetailsPageArgument(galleryUrl: gallery.galleryUrl, gallery: gallery)),
            handleLongPressCard: (Gallery gallery, _) => RecommendFeedbackSheet.showForGallery(context, gallery),
          );
        },
      ),
      // a lazily built item: the footer exists only near the end of the list
      SliverList(delegate: SliverChildBuilderDelegate((_, __) => const _FeedFooter(), childCount: 1)),
    ];
  }
}

/// "For you · folder", refresh and the page with the details; or what is
/// happening while there is nothing to show yet.
class _FeedHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GetBuilder<TasteService>(
      id: TasteService.stateId,
      builder: (_) => GetBuilder<RecommendService>(
        id: RecommendService.stateId,
        builder: (_) {
          // read the favourites / recommend again when needed; cheap when fresh
          WidgetsBinding.instance.addPostFrameCallback((_) => recommendService.ensureFresh());
          final TextTheme text = Theme.of(context).textTheme;
          final Recommendation? r = recommendService.current;
          final String? folder = recommendService.folder == null ? null : FavoriteFolderChips.folderName(recommendService.folder!);
          final bool startingOver = recommendService.running && !recommendService.runningMore;
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 20, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text('✨ ', style: TextStyle(fontSize: 16)),
                    Expanded(
                      child: Text(
                        folder == null ? 'recommendForYou'.tr : '${'recommendForYou'.tr} · $folder',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                    IconButton(
                      tooltip: 'recommendRefresh'.tr,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.refresh),
                      onPressed: recommendService.running || !recommendService.canRecommend(recommendService.folder)
                          ? null
                          : () => recommendService.recommend(recommendService.folder),
                    ),
                    IconButton(
                      tooltip: 'recommendTune'.tr,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.tune),
                      onPressed: () => toRoute(Routes.recommend),
                    ),
                  ],
                ),
                if (r != null && recommendService.newVotes > 0 && !recommendService.running)
                  Text('recommendFeedbackPending'.trParams({'count': '${recommendService.newVotes}'}), style: text.bodySmall),
                if (r != null && recommendService.newVotes == 0 && !recommendService.running)
                  Text('recommendFeedbackHint'.tr, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
                if (tasteService.refreshing)
                  _progress(context, 'feedReadingFavorites'.trParams({'count': '${tasteService.progressDone}'}), null)
                else if (startingOver)
                  _progress(
                    context,
                    'recommendProgress'.trParams({'done': '${recommendService.progressDone}', 'total': '${recommendService.progressTotal}'}),
                    recommendService.progressTotal == 0 ? null : recommendService.progressDone / recommendService.progressTotal,
                  )
                else if (recommendService.error != null && r == null)
                  _message(context, '${'recommendFailed'.tr}\n${recommendService.error}',
                      FilledButton(onPressed: () => recommendService.recommend(recommendService.folder), child: Text('retry'.tr)))
                else if (r == null && !recommendService.canRecommend(recommendService.folder))
                  _message(
                    context,
                    'feedNeedSignal'.tr,
                    userSetting.hasLoggedIn() ? null : FilledButton(onPressed: () => toRoute(Routes.login), child: Text('login'.tr)),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _progress(BuildContext context, String label, double? value) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: value),
        ],
      ),
    );
  }

  Widget _message(BuildContext context, String message, Widget? action) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action],
          ],
        ),
      ),
    );
  }
}

/// The end of the feed: recommends more as it comes into view.
class _FeedFooter extends StatelessWidget {
  const _FeedFooter();

  @override
  Widget build(BuildContext context) {
    return GetBuilder<RecommendService>(
      id: RecommendService.stateId,
      builder: (_) {
        final Recommendation? r = recommendService.current;
        if (r == null || r.galleries.isEmpty) {
          return const SizedBox(height: 40);
        }
        final TextStyle? small = Theme.of(context).textTheme.bodySmall;
        Widget child;
        if (recommendService.runningMore) {
          child = Column(
            children: [
              const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(height: 8),
              Text('feedLoadingMore'.trParams({'done': '${recommendService.progressDone}', 'total': '${recommendService.progressTotal}'}), style: small),
            ],
          );
        } else if (recommendService.exhausted) {
          child = Text('feedNoMore'.tr, style: small);
        } else if (recommendService.error != null) {
          child = TextButton(onPressed: recommendService.loadMore, child: Text('${'recommendFailed'.tr} · ${'retry'.tr}'));
        } else {
          // built only when the end of the list comes near: load the next part
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // still near the end after this frame's layout
            if (context.mounted) {
              recommendService.loadMore();
            }
          });
          child = const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
        }
        return Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), child: Center(child: child));
      },
    );
  }
}
