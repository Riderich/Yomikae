import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/recommend_feedback.dart';
import 'package:jhentai/src/service/taste_service.dart';

TasteGallery g(int gid, List<String> tags) => TasteGallery(gid: gid, token: 't', title: '$gid', category: 'Manga', tags: tags);

void main() {
  final Map<String, double> profile = {'female:glasses': 2, 'female:ponytail': 1.5, 'female:maid': 1};
  final List<(TasteGallery, double)> candidates = [
    (g(1, ['female:glasses', 'female:ponytail']), 4.5),
    (g(2, ['female:glasses', 'female:maid', 'female:netorare']), 4.5),
    (g(3, ['female:maid', 'artist:alice']), 4.5),
    (g(4, ['female:glasses', 'female:tentacles']), 4.5),
  ];

  test('a disliked tag removes its works and leaves the profile and seeds', () {
    final RecommendFeedback f = RecommendFeedback()..voteTag(0, 'female:netorare', -1);
    expect(f.rank(0, candidates, profile, const {}).map((r) => r.$1), isNot(contains(2)));
    // dislikes count in every folder
    expect(f.tagVote(5, 'female:netorare'), -1);

    f.voteTag(0, 'female:glasses', -1);
    expect(f.adjustProfile(0, profile, const {}).containsKey('female:glasses'), isFalse);
    expect(f.adjustSeeds(0, ['female:glasses', 'female:maid'], const {}), ['female:maid']);
  });

  test('a liked tag becomes the first seed and a top profile tag, in its folder only', () {
    final RecommendFeedback f = RecommendFeedback()..voteTag(1, 'female:maid', 1);
    expect(f.adjustSeeds(1, ['female:glasses', 'female:ponytail'], const {}), ['female:maid', 'female:glasses', 'female:ponytail']);
    expect(f.adjustProfile(1, profile, const {})['female:maid'], 2);
    expect(f.adjustProfile(0, profile, const {})['female:maid'], 1);
    expect(f.tagVote(0, 'female:maid'), 0);
  });

  test('works close to a disliked work drop', () {
    final RecommendFeedback f = RecommendFeedback();
    final List<int> before = f.rank(null, candidates, profile, const {}).map((r) => r.$1).toList();
    f.voteGallery(null, 99, ['female:glasses', 'female:tentacles'], -1);
    final List<int> after = f.rank(null, candidates, profile, const {}).map((r) => r.$1).toList();
    expect(before.indexOf(4), lessThan(after.indexOf(4)));
  });

  test('a liked work pulls similar works up and is not shown again', () {
    final RecommendFeedback f = RecommendFeedback();
    double scoreOf(List<(int, double)> ranked, int gid) => ranked.firstWhere((r) => r.$1 == gid).$2;
    final double before = scoreOf(f.rank(null, candidates, profile, const {}), 3);
    f.voteGallery(null, 3, ['female:maid', 'artist:alice'], 1);
    final Map<String, double> adjusted = f.adjustProfile(null, profile, const {});
    expect(adjusted['female:maid']!, greaterThan(profile['female:maid']!));
    final List<(int, double)> ranked = f.rank(null, [...candidates, (g(5, ['female:maid']), 4.5)], adjusted, const {});
    expect(ranked.map((r) => r.$1), isNot(contains(3)));
    expect(scoreOf(ranked, 5), greaterThan(before * 0.9));
  });

  test('works shown before go after the new ones', () {
    final RecommendFeedback f = RecommendFeedback()..addShown(null, [1]);
    final List<int> ranked = f.rank(null, candidates, profile, const {}).map((r) => r.$1).toList();
    expect(ranked.last, 1);
    expect(f.rank(0, candidates, profile, const {}).first.$1, 1);
  });

  test('json round trip', () {
    final RecommendFeedback f = RecommendFeedback()
      ..voteTag(null, 'female:maid', 1)
      ..voteTag(2, 'female:netorare', -1)
      ..voteGallery(2, 7, ['female:glasses'], 1)
      ..voteGallery(null, 8, ['male:x'], -1)
      ..addShown(2, [1, 2, 3]);
    f.cursors['2'] = {'q': '123'};
    final RecommendFeedback back = RecommendFeedback.fromJson(jsonDecode(jsonEncode(f.toJson())));
    expect(back.tagVote(null, 'female:maid'), 1);
    expect(back.tagVote(0, 'female:netorare'), -1);
    expect(back.galleryVote(2, 7), 1);
    expect(back.galleryVote(0, 8), -1);
    expect(back.shownOf(2), {1, 2, 3});
    expect(back.cursors['2'], {'q': '123'});
    back.clear();
    expect(back.isEmpty, isTrue);
  });
}
