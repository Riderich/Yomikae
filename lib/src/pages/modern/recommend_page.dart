import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/pages/modern/favorite_folder_chips.dart';
import 'package:jhentai/src/pages/modern/recommend_feedback_sheet.dart';
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
  /// The extra taste tags start folded: they are for tuning, not reading.
  bool _tasteTagsOpen = false;
  bool _artistsOpen = false;

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
              if (recommendService.newVotes > 0 && !recommendService.running) _buildPendingFeedback(context),
              if (r != null) ...[
                const SizedBox(height: 8),
                _buildBasis(context, r),
                if (r.artists.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _title(context, Icons.brush_outlined, 'recommendArtists'.tr),
                  const SizedBox(height: 8),
                  _buildArtists(context, r),
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
            handleLongPressCard: (Gallery gallery, _) => RecommendFeedbackSheet.showForGallery(context, gallery),
          ),
        if (!recommendService.feedback.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            sliver: SliverToBoxAdapter(child: _buildFeedbackSummary(context)),
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

  /// "Based on: [glasses] [ponytail] ... 3d | chinese", the tags can be
  /// searched (tap) and rated (long press).
  Widget _buildBasis(BuildContext context, Recommendation r) {
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    final List<String> extra = [
      ...r.styles.map(recommendService.label),
      if (r.language != null) recommendService.label('language:${r.language}'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(extra.isEmpty ? 'recommendBasis'.tr : '${'recommendBasis'.tr}  ·  ${'recommendLimit'.trParams({'limit': extra.join(' · ')})}', style: small),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: r.seeds.map((tag) => _tagChip(context, tag)).toList(),
        ),
        const SizedBox(height: 6),
        Text('recommendFeedbackHint'.tr, style: small?.copyWith(color: Theme.of(context).colorScheme.outline)),
        if (recommendService.tasteTags.isNotEmpty) ...[
          const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _tasteTagsOpen = !_tasteTagsOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'recommendMoreTasteTagsTitle'.trParams({'count': '${recommendService.tasteTags.length}'}),
                      style: small?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(_tasteTagsOpen ? Icons.expand_less : Icons.expand_more, size: 20, color: Theme.of(context).colorScheme.outline),
                ],
              ),
            ),
          ),
          if (_tasteTagsOpen) ...[
            Text('recommendMoreTasteTags'.tr, style: small?.copyWith(color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: recommendService.tasteTags.map((tag) => _votingChip(context, tag)).toList(),
            ),
          ],
        ],
      ],
    );
  }

  /// Tap: none -> want more -> want less -> none. Long press: the sheet, with search.
  Widget _votingChip(BuildContext context, String tag) {
    final int vote = recommendService.tagVote(tag);
    return GestureDetector(
      onLongPress: () => RecommendFeedbackSheet.showForTag(context, tag),
      child: FilterChip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelStyle: const TextStyle(fontSize: 12.5),
        avatar: vote == 0 ? null : RecommendFeedbackSheet.voteIcon(vote, size: 14),
        showCheckmark: false,
        selected: vote != 0,
        selectedColor: (vote > 0 ? RecommendFeedbackSheet.likeColor : RecommendFeedbackSheet.dislikeColor).withValues(alpha: 0.15),
        label: Text(recommendService.label(tag)),
        onSelected: (_) => recommendService.voteTag(tag, vote == 0 ? 1 : (vote > 0 ? -1 : 0)),
      ),
    );
  }

  Widget _tagChip(BuildContext context, String tag, {VoidCallback? onDeleted}) {
    final int vote = recommendService.tagVote(tag);
    return GestureDetector(
      onLongPress: () => RecommendFeedbackSheet.showForTag(context, tag),
      child: InputChip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelStyle: const TextStyle(fontSize: 12.5),
        avatar: vote == 0 ? null : RecommendFeedbackSheet.voteIcon(vote, size: 14),
        label: Text(recommendService.label(tag)),
        onPressed: () => RecommendFeedbackSheet.showForTag(context, tag),
        onDeleted: onDeleted,
      ),
    );
  }

  Widget _buildPendingFeedback(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.how_to_vote_outlined),
        title: Text('recommendFeedbackPending'.trParams({'count': '${recommendService.newVotes}'})),
        trailing: FilledButton(onPressed: () => recommendService.recommend(recommendService.folder), child: Text('refresh'.tr)),
      ),
    );
  }

  /// Everything rated so far; a chip's x forgets that vote.
  Widget _buildFeedbackSummary(BuildContext context) {
    final int? folder = recommendService.folder;
    final List<String> liked = recommendService.feedback.likedTagsOf(folder).toList()..sort();
    final List<String> disliked = recommendService.feedback.dislikedTags.toList()..sort();
    final int likedWorks = recommendService.feedback.likedGalleriesOf(folder).length;
    final int dislikedWorks = recommendService.feedback.dislikedGalleries.length;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _title(context, Icons.how_to_vote_outlined, 'recommendYourFeedback'.tr)),
            TextButton(onPressed: recommendService.clearFeedback, child: Text('recommendClearFeedback'.tr)),
          ],
        ),
        if (likedWorks > 0 || dislikedWorks > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              [
                if (likedWorks > 0) 'recommendLikedWorks'.trParams({'count': '$likedWorks'}),
                if (dislikedWorks > 0) 'recommendDislikedWorks'.trParams({'count': '$dislikedWorks'}),
              ].join(' · '),
              style: small,
            ),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ...liked.map((tag) => _tagChip(context, tag, onDeleted: () => recommendService.voteTag(tag, 0))),
            ...disliked.map((tag) => _tagChip(context, tag, onDeleted: () => recommendService.voteTag(tag, 0))),
          ],
        ),
      ],
    );
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

  Widget _buildArtists(BuildContext context, Recommendation r) {
    return GetBuilder<FollowService>(
      id: FollowService.entriesId,
      builder: (_) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          ...(_artistsOpen ? r.artists : r.artists.take(6)).map((item) {
            final bool following = followService.isFollowing(item.namespace, item.key);
            final int vote = recommendService.tagVote('${item.namespace}:${item.key}');
            return GestureDetector(
              onLongPress: () => RecommendFeedbackSheet.showForTag(context, '${item.namespace}:${item.key}', keyword: item.keyword),
              child: InputChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelStyle: const TextStyle(fontSize: 12.5),
                avatar: vote == 0 ? null : RecommendFeedbackSheet.voteIcon(vote, size: 14),
                label: Text(item.displayName),
                onPressed: () => newSearch(keyword: item.keyword, forceNewRoute: true),
                deleteIcon: Icon(following ? Icons.star : Icons.star_border, size: 16, color: following ? Colors.amber : null),
                deleteButtonTooltipMessage: following ? 'unfollow'.tr : 'follow'.tr,
                onDeleted: () => followService.toggle(item.namespace, item.key, label: item.label),
              ),
            );
          }),
          if (r.artists.length > 6)
            ActionChip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              label: Text(
                _artistsOpen ? 'tasteCollapse'.tr : 'tasteShowAll'.trParams({'count': '${r.artists.length}'}),
                style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.outline),
              ),
              onPressed: () => setState(() => _artistsOpen = !_artistsOpen),
            ),
        ],
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
