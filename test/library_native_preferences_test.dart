import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';

// Native preferences cross a platform codec on startup. Unlike the standard
// in-memory fake, the codec returns lists without a List<String> runtime type.
class _NativeCodecPreferences extends InMemorySharedPreferencesStore {
  _NativeCodecPreferences() : super.empty();

  @override
  Future<Map<String, Object>> getAll() async {
    const codec = StandardMessageCodec();
    final decoded = codec.decodeMessage(
      codec.encodeMessage(await super.getAll()),
    );
    return Map<String, Object>.from(decoded as Map);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final original = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _NativeCodecPreferences();
    addTearDown(() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = original;
    });
  });

  test('online shelf survives a cold native preferences reload', () async {
    final novel = demoNovels.first;
    final library = await LibraryState.load();
    await library.toggleShelf(novel.id, novel: novel);
    expect(library.contains(novel.id), isTrue);
    library.dispose();

    SharedPreferences.resetStatic();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('shelf'), contains('${novel.id}'));
    expect(prefs.get(restoreJournalKey), isNull);
    expect(prefs.get('shelf'), isNot(isA<List<String>>()));
    final reopened = await LibraryState.load();
    addTearDown(reopened.dispose);
    expect(reopened.contains(novel.id), isTrue);
  });

  test(
    'cold reload preserves existing shelf when another book is added',
    () async {
      final first = demoNovels[0];
      final second = demoNovels[1];
      final library = await LibraryState.load();
      await library.setShelfMembership(first.id, true, novel: first);
      library.dispose();

      SharedPreferences.resetStatic();
      final reopened = await LibraryState.load();
      await reopened.setShelfMembership(second.id, true, novel: second);
      reopened.dispose();

      SharedPreferences.resetStatic();
      final again = await LibraryState.load();
      addTearDown(again.dispose);
      expect(again.shelf, {first.id, second.id});
    },
  );

  test(
    'startup migrates legacy local IDs without losing online shelf',
    () async {
      final store = SharedPreferencesStorePlatform.instance;
      final online = demoNovels.first.id;
      await store.setValue('StringList', 'flutter.shelf', [
        '$online',
        '${0x60000001}',
      ]);
      final library = await LibraryState.load();
      addTearDown(library.dispose);
      expect(library.shelf, {online});
      expect((await SharedPreferences.getInstance()).getStringList('shelf'), [
        '$online',
      ]);
    },
  );

  test('search and hidden book lists survive a cold native reload', () async {
    final library = await LibraryState.load();
    final online = demoNovels.first.id;
    const local = 0x60000001;
    await library.recordSearch('重启保留搜索');
    await library.setChapter(online, 1);
    await library.hideReadingHistory(online);
    await library.setLocalBookHidden(local, true);
    library.dispose();

    SharedPreferences.resetStatic();
    final reopened = await LibraryState.load();
    addTearDown(reopened.dispose);
    expect(reopened.recentSearches, ['重启保留搜索']);
    expect(reopened.readingHistoryIds, isNot(contains(online)));
    expect(reopened.localBookVisible(local), isFalse);
  });
}
