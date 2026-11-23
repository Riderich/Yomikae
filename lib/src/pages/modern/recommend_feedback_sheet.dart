import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/service/recommend_service.dart';
import 'package:jhentai/src/service/taste_service.dart';
import 'package:jhentai/src/utils/search_util.dart';

/// Long-press feedback on recommendations: like or dislike a work, its tags,
/// an artist or a seed tag. The next recommendation takes it into account.
class RecommendFeedbackSheet {
  static const Color likeColor = Colors.green;
  static const Color dislikeColor = Colors.redAccent;

  static Widget voteIcon(int vote, {double size = 16}) {
    if (vote > 0) {
      return Icon(Icons.thumb_up, size: size, color: likeColor);
    }
    if (vote < 0) {
      return Icon(Icons.thumb_down, size: size, color: dislikeColor);
    }
    return const SizedBox.shrink();
  }

  /// Like / dislike a recommended work, and its tags one by one.
  static Future<void> showForGallery(BuildContext context, Gallery gallery) async {
    final List<String> tags = _feedbackTags(recommendService.tagsOf(gallery));
    recommendService.translateTags(tags);
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => GetBuilder<RecommendService>(
        id: RecommendService.stateId,
        builder: (_) {
          final int vote = recommendService.galleryVote(gallery.gid);
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(gallery.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _VoteButton(
                            icon: Icons.thumb_up_outlined,
                            label: 'recommendLike'.tr,
                            color: likeColor,
                            selected: vote > 0,
                            onPressed: () {
                              recommendService.voteGallery(gallery, vote > 0 ? 0 : 1);
                              if (vote <= 0) {
                                _toast(messenger, 'recommendLiked'.tr);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _VoteButton(
                            icon: Icons.thumb_down_outlined,
                            label: 'recommendDislike'.tr,
                            color: dislikeColor,
                            selected: vote < 0,
                            onPressed: () {
                              if (vote < 0) {
                                recommendService.undoDislike(gallery, -1);
                                return;
                              }
                              final int index = recommendService.voteGallery(gallery, -1);
                              Navigator.of(context).pop();
                              _toast(messenger, 'recommendDisliked'.tr, undo: () => recommendService.undoDislike(gallery, index));
                            },
                          ),
                        ),
                      ],
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text('recommendTagsFeedback'.tr, style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: tags.map((tag) {
                          final int tagVote = recommendService.tagVote(tag);
                          return FilterChip(
                            avatar: tagVote == 0 ? null : voteIcon(tagVote),
                            showCheckmark: false,
                            selected: tagVote != 0,
                            selectedColor: (tagVote > 0 ? likeColor : dislikeColor).withValues(alpha: 0.15),
                            label: Text(recommendService.label(tag)),
                            tooltip: tag,
                            // none -> like -> dislike -> none
                            onSelected: (_) => recommendService.voteTag(tag, tagVote == 0 ? 1 : (tagVote > 0 ? -1 : 0)),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 8),
                      Text('recommendDislikeEverywhere'.tr, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Like / dislike one tag or artist (`namespace:key`).
  static Future<void> showForTag(BuildContext context, String tag, {String? keyword}) async {
    recommendService.translateTags([tag]);
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => GetBuilder<RecommendService>(
        id: RecommendService.stateId,
        builder: (_) {
          final int vote = recommendService.tagVote(tag);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(recommendService.label(tag), style: Theme.of(context).textTheme.titleMedium),
                  Text(tag, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _VoteButton(
                          icon: Icons.thumb_up_outlined,
                          label: 'recommendTagLike'.tr,
                          color: likeColor,
                          selected: vote > 0,
                          onPressed: () => recommendService.voteTag(tag, vote > 0 ? 0 : 1),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _VoteButton(
                          icon: Icons.thumb_down_outlined,
                          label: 'recommendTagDislike'.tr,
                          color: dislikeColor,
                          selected: vote < 0,
                          onPressed: () => recommendService.voteTag(tag, vote < 0 ? 0 : -1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('recommendDislikeEverywhere'.tr, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
                  const SizedBox(height: 4),
                  TextButton.icon(
                    icon: const Icon(Icons.search),
                    label: Text('search'.tr),
                    onPressed: () {
                      Navigator.of(context).pop();
                      newSearch(keyword: keyword ?? TasteService.searchTerm(tag), forceNewRoute: true);
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Artists, circles, series, characters and content tags; not languages
  /// or the bookkeeping tags.
  static List<String> _feedbackTags(List<String> tags) {
    const List<String> order = ['artist', 'group', 'parody', 'character', 'female', 'male', 'mixed', 'other'];
    final List<String> result = tags.toSet().where((t) {
      final int colon = t.indexOf(':');
      return colon > 0 && order.contains(t.substring(0, colon)) && !TasteService.isUninformative(t) && t != 'parody:original';
    }).toList();
    int rank(String t) => order.indexOf(t.substring(0, t.indexOf(':')));
    result.sort((a, b) => rank(a).compareTo(rank(b)));
    return result;
  }

  static void _toast(ScaffoldMessengerState? messenger, String message, {VoidCallback? undo}) {
    if (messenger == null) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        // a snack bar with an action would otherwise stay until dismissed
        persist: false,
        action: undo == null ? null : SnackBarAction(label: 'recommendUndo'.tr, onPressed: undo),
      ));
  }
}

class _VoteButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  const _VoteButton({required this.icon, required this.label, required this.color, required this.selected, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
        icon: Icon(icon),
        label: Text(label),
        onPressed: onPressed,
      );
    }
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(foregroundColor: color),
      icon: Icon(icon),
      label: Text(label),
      onPressed: onPressed,
    );
  }
}
