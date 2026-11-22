import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/follow_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/search_util.dart';

/// Followed uploaders, artists, circles and tags, newest activity first.
class FollowPage extends StatefulWidget {
  const FollowPage({super.key});

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> {
  @override
  void initState() {
    super.initState();
    followService.checkUpdates();
  }

  static IconData _icon(String namespace) => switch (namespace) {
        'uploader' => Icons.person_outline,
        'artist' => Icons.brush_outlined,
        'group' => Icons.groups_outlined,
        'parody' => Icons.movie_outlined,
        'character' => Icons.face_outlined,
        _ => Icons.label_outline,
      };

  void _open(FollowEntry entry) {
    followService.markSeen(entry);
    newSearch(keyword: entry.keyword, forceNewRoute: true);
  }

  Future<bool> _confirmUnfollow(FollowEntry entry) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('unfollow'.tr),
        content: Text(entry.displayName),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('cancel'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('OK'.tr)),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('follow'.tr),
        centerTitle: false,
        actions: [
          IconButton(icon: const Icon(Icons.visibility_outlined), tooltip: 'ehWatchedTags'.tr, onPressed: () => toRoute(Routes.watched)),
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh'.tr, onPressed: () => followService.checkUpdates(force: true)),
        ],
      ),
      body: GetBuilder<FollowService>(
        id: FollowService.entriesId,
        builder: (_) {
          final List<FollowEntry> entries = List.of(followService.entries)..sort((a, b) => b.newCount.compareTo(a.newCount));
          return Column(
            children: [
              if (followService.checking)
                LinearProgressIndicator(value: entries.isEmpty ? null : followService.checkedCount / entries.length),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => followService.checkUpdates(force: true),
                  child: entries.isEmpty ? _buildEmpty(context) : _buildList(context, entries),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 48),
        Icon(Icons.star_outline, size: 56, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text('followEmptyHint'.tr, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.visibility_outlined),
            label: Text('ehWatchedTags'.tr),
            onPressed: () => toRoute(Routes.watched),
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, List<FollowEntry> entries) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final FollowEntry entry = entries[index];
        return Dismissible(
          key: ValueKey(entry.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Theme.of(context).colorScheme.errorContainer,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.onErrorContainer),
          ),
          confirmDismiss: (_) => _confirmUnfollow(entry),
          onDismissed: (_) => followService.unfollow(entry.namespace, entry.key),
          child: ListTile(
            leading: CircleAvatar(child: Icon(_icon(entry.namespace), size: 20)),
            title: Text(entry.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              entry.displayName == entry.key ? entry.namespace.tr : '${entry.namespace.tr} · ${entry.key}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: entry.newCount > 0
                ? Badge(label: Text(entry.newCount >= 25 ? '25+' : '${entry.newCount}'), largeSize: 20)
                : const Icon(Icons.chevron_right),
            onTap: () => _open(entry),
            onLongPress: () async {
              if (await _confirmUnfollow(entry)) {
                followService.unfollow(entry.namespace, entry.key);
              }
            },
          ),
        );
      },
    );
  }
}
