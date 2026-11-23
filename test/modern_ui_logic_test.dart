import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/follow_service.dart';
import 'package:jhentai/src/service/taste_service.dart';

void main() {
  group('follow entries', () {
    test('search keywords', () {
      expect(FollowEntry(namespace: 'uploader', key: 'Some Group').keyword, 'uploader:"Some Group"');
      expect(FollowEntry(namespace: 'artist', key: 'akashi rokuro').keyword, r'artist:"akashi rokuro$"');
    });

    test('json round trip keeps the update state', () {
      final FollowEntry entry = FollowEntry(namespace: 'female', key: 'glasses', label: '眼镜', seenGid: 10, latestGid: 20, newCount: 3);
      final FollowEntry copy = FollowEntry.fromJson(entry.toJson());
      expect(copy.id, 'female:glasses');
      expect(copy.displayName, '眼镜');
      expect((copy.seenGid, copy.latestGid, copy.newCount), (10, 20, 3));
      expect(copy.followedAt.millisecondsSinceEpoch, entry.followedAt.millisecondsSinceEpoch);
    });

    test('display name falls back to the key', () {
      expect(FollowEntry(namespace: 'uploader', key: 'abc').displayName, 'abc');
      expect(FollowEntry(namespace: 'uploader', key: 'abc', label: '').displayName, 'abc');
    });
  });

  group('taste ranking', () {
    TasteGallery g(int gid, List<String> tags, {String? uploader}) =>
        TasteGallery(gid: gid, token: 'abcdefghij', title: '', category: 'Manga', uploader: uploader, tags: tags);

    test('counts artists, circles and uploaders by how many favourites have them', () {
      final Map<TasteSection, List<TasteItem>> r = TasteService.rank([
        g(1, ['artist:a', 'group:x'], uploader: 'u1'),
        g(2, ['artist:a', 'artist:b'], uploader: 'u1'),
        g(3, ['artist:a', 'group:x'], uploader: 'u2'),
      ], {});
      expect(r[TasteSection.artist]!.map((i) => (i.key, i.count)), [('a', 3), ('b', 1)]);
      expect(r[TasteSection.group]!.single.count, 2);
      expect(r[TasteSection.uploader]!.map((i) => (i.key, i.count)), [('u1', 2), ('u2', 1)]);
      expect(r[TasteSection.uploader]!.first.keyword, 'uploader:"u1"');
    });

    test('drops tags that say nothing about taste', () {
      final Map<TasteSection, List<TasteItem>> r = TasteService.rank([
        g(1, ['other:full color', 'parody:original', 'language:chinese', 'female:glasses']),
        g(2, ['other:full color', 'parody:original', 'female:glasses']),
      ], {});
      expect(r[TasteSection.tag]!.map((i) => i.key), ['glasses']);
      expect(r[TasteSection.parody], isEmpty);
    });

    test('prefers tags typical of the collection over tags that are everywhere', () {
      final List<TasteGallery> galleries = [
        for (int i = 0; i < 5; i++) g(i, ['female:big breasts', if (i < 3) 'female:glasses']),
      ];
      // without site counts: plain frequency
      expect(TasteService.rank(galleries, {})[TasteSection.tag]!.first.key, 'big breasts');
      // with site counts: a tag on 3 of 5 favourites but rare on the site wins
      expect(TasteService.rank(galleries, {'female:big breasts': 1300000, 'female:glasses': 20000})[TasteSection.tag]!.first.key, 'glasses');
    });

    test('duplicate tags within one gallery count once', () {
      final Map<TasteSection, List<TasteItem>> r = TasteService.rank([g(1, ['artist:a', 'artist:a'])], {});
      expect(r[TasteSection.artist]!.single.count, 1);
    });

    test('an artist whose work matches the taste beats a one-off that does not', () {
      final List<TasteGallery> galleries = [
        // newest first: the off-taste artist is even newer
        g(1, ['artist:off', 'female:tentacles']),
        for (int i = 2; i < 8; i++) g(i, ['artist:main$i', 'female:glasses', 'female:ponytail']),
        g(9, ['artist:match', 'female:glasses', 'female:ponytail']),
      ];
      final List<String> artists = TasteService.rank(galleries, {})[TasteSection.artist]!.map((i) => i.key).toList();
      expect(artists.indexOf('match'), lessThan(artists.indexOf('off')));
    });

    test('favouriting most of a small body of work counts more than a little of a big one', () {
      final List<TasteGallery> galleries = [
        g(1, ['artist:prolific', 'female:glasses']),
        g(2, ['artist:niche', 'female:glasses']),
      ];
      final Map<String, int> counts = {'artist:prolific': 800, 'artist:niche': 2, 'female:glasses': 20000};
      expect(TasteService.rank(galleries, counts)[TasteSection.artist]!.first.key, 'niche');
      expect(TasteService.hitFactor(2, 2), greaterThan(TasteService.hitFactor(2, 800)));
      expect(TasteService.hitFactor(1, null), 0.8);
    });

    test('recent favourites weigh more, old ones still count half', () {
      expect(TasteService.recency(0, 100), 1);
      expect(TasteService.recency(30, 100), closeTo(0.75, 1e-9));
      expect(TasteService.recency(100000, 100), closeTo(0.5, 1e-6));
      final List<TasteGallery> galleries = [
        g(1, ['artist:new']),
        for (int i = 2; i < 200; i++) g(i, ['female:glasses']),
        g(200, ['artist:old']),
      ];
      expect(TasteService.rank(galleries, {})[TasteSection.artist]!.first.key, 'new');
    });

    test('cosine similarity', () {
      expect(TasteService.cosine({'a': 1, 'b': 1}, {'a': 2, 'b': 2}), closeTo(1, 1e-9));
      expect(TasteService.cosine({'a': 1}, {'b': 1}), 0);
      expect(TasteService.cosine({}, {'b': 1}), 0);
    });
  });

  group('taste recommendations', () {
    TasteGallery g(int gid, List<String> tags) => TasteGallery(gid: gid, token: 'abcdefghij', title: '', category: 'Manga', tags: tags);

    test('recall searches pairs of the strongest common-enough tags', () {
      final Map<String, double> profile = {'female:glasses': 5, 'female:ponytail': 4, 'female:rare': 9, 'male:x': 3};
      final Map<String, int> counts = {'female:glasses': 20000, 'female:ponytail': 30000, 'female:rare': 10, 'male:x': 5000};
      final List<String> seeds = TasteService.seedTags(profile, counts);
      expect(seeds, ['female:glasses', 'female:ponytail', 'male:x']);
      expect(TasteService.recallQueries(seeds, 'chinese'), [
        r'female:"glasses$" female:"ponytail$" language:"chinese$"',
        r'female:"glasses$" male:"x$" language:"chinese$"',
        r'female:"ponytail$" male:"x$" language:"chinese$"',
      ]);
      expect(TasteService.recallQueries(['female:glasses'], null), [r'female:"glasses$"']);
      expect(TasteService.recallQueries([], null), isEmpty);
    });

    test('dominant language needs half of the favourites', () {
      expect(TasteService.dominantLanguage([g(1, ['language:chinese', 'language:translated']), g(2, ['language:chinese']), g(3, [])]), 'chinese');
      expect(TasteService.dominantLanguage([g(1, ['language:chinese']), g(2, ['language:english']), g(3, [])]), isNull);
    });

    test('ranks unknown artists by closeness to the profile and rating', () {
      final Map<String, double> profile = {'female:glasses': 2, 'female:ponytail': 2};
      final List<TasteItem> items = TasteService.recommend([
        (g(1, ['artist:close', 'female:glasses', 'female:ponytail']), 4.8),
        (g(2, ['artist:far', 'female:glasses', 'male:a', 'male:b', 'male:c']), 4.8),
        (g(3, ['artist:known', 'female:glasses', 'female:ponytail']), 5.0),
        (g(4, ['artist:unrelated', 'male:a']), 5.0),
      ], profile, {'artist:known'}, {});
      expect(items.map((i) => i.key), ['close', 'far']);
      expect(items.first.keyword, r'artist:"close$"');
    });

    test('items survive the cache', () {
      final TasteItem copy = TasteItem.fromJson(TasteItem('artist', 'a', 3, siteCount: 12, score: 1.5).toJson());
      expect((copy.namespace, copy.key, copy.count, copy.siteCount, copy.score), ('artist', 'a', 3, 12, 1.5));
    });
  });
}
