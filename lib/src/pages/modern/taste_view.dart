import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/follow_service.dart';
import 'package:jhentai/src/service/taste_service.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/search_util.dart';

/// What the user's favourites have in common: the artists, circles, uploaders,
/// series, characters and tags that come up most. Tap to search, star to follow.
class TasteView extends StatelessWidget {
  const TasteView({super.key});

  static const Map<TasteSection, (String, IconData)> _sections = {
    TasteSection.artist: ('tasteArtists', Icons.brush_outlined),
    TasteSection.group: ('tasteGroups', Icons.groups_outlined),
    TasteSection.uploader: ('tasteUploaders', Icons.person_outline),
    TasteSection.tag: ('tasteTags', Icons.label_outline),
    TasteSection.parody: ('tasteParodies', Icons.movie_outlined),
    TasteSection.character: ('tasteCharacters', Icons.face_outlined),
  };

  @override
  Widget build(BuildContext context) {
    return GetBuilder<TasteService>(
      id: TasteService.stateId,
      builder: (_) => GetBuilder<FollowService>(
        id: FollowService.entriesId,
        builder: (_) {
          if (!userSetting.hasLoggedIn() && TasteService.testSource.isEmpty) {
            return _buildMessage(context, Icons.lock_outline, 'needLoginToOperate'.tr,
                action: FilledButton(onPressed: () => toRoute(Routes.login), child: Text('login'.tr)));
          }
          if (tasteService.galleries.isEmpty && !tasteService.refreshing) {
            return _buildMessage(
              context,
              Icons.insights_outlined,
              tasteService.error == null ? 'tasteIntro'.tr : '${'tasteFailed'.tr}\n${tasteService.error}',
              action: FilledButton.icon(icon: const Icon(Icons.play_arrow), label: Text('tasteStart'.tr), onPressed: tasteService.analyze),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (tasteService.refreshing) _buildProgress(context),
              if (tasteService.error != null && !tasteService.refreshing)
                Card(child: ListTile(leading: const Icon(Icons.error_outline), title: Text('tasteFailed'.tr), subtitle: Text(tasteService.error!))),
              for (MapEntry<TasteSection, (String, IconData)> section in _sections.entries)
                if (tasteService.sections[section.key]?.isNotEmpty ?? false) _buildSection(context, section.value.$1.tr, section.value.$2, tasteService.sections[section.key]!),
              const SizedBox(height: 16),
              if (tasteService.updateTime != null)
                Text(
                  'tasteFooter'.trParams({
                    'count': '${tasteService.galleries.length}',
                    'time': DateFormat('yyyy-MM-dd HH:mm').format(tasteService.updateTime!),
                  }),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMessage(BuildContext context, IconData icon, String message, {Widget? action}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 20), action],
          ],
        ),
      ),
    );
  }

  Widget _buildProgress(BuildContext context) {
    final bool listing = tasteService.phase == TasteRefreshPhase.listing;
    final String text = listing
        ? 'tasteListing'.trParams({'count': '${tasteService.progressDone}'})
        : 'tasteFetching'.trParams({'done': '${tasteService.progressDone}', 'total': '${tasteService.progressTotal}'});
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(text),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: listing || tasteService.progressTotal == 0 ? null : tasteService.progressDone / tasteService.progressTotal,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, IconData icon, List<TasteItem> items) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            // with enough recurring entries, one-off ones are just noise
            children: (items.where((i) => i.count >= 2).length >= 4 ? items.where((i) => i.count >= 2) : items).take(24).map((item) {
              final bool following = followService.isFollowing(item.namespace, item.key);
              return InputChip(
                label: Text('${item.displayName}  ${item.count}'),
                tooltip: item.displayName == item.key ? null : '${item.namespace}:${item.key}',
                onPressed: () => newSearch(keyword: item.keyword, forceNewRoute: true),
                deleteIcon: Icon(following ? Icons.star : Icons.star_border, size: 18, color: following ? Colors.amber : null),
                deleteButtonTooltipMessage: following ? 'unfollow'.tr : 'follow'.tr,
                onDeleted: () => followService.toggle(item.namespace, item.key, label: item.label),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
