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
  });
}
