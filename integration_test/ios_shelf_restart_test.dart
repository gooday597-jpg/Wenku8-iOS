import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';

// CI uses flutter drive --keep-app-running and simctl terminate between runs,
// launching this app twice without uninstalling its real UserDefaults container.
// The second process must recover the shelf written by the first process.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const verify = bool.fromEnvironment('VERIFY_SHELF_RESTART');

  testWidgets(
    verify
        ? 'online bookshelf survives a fresh iOS app process'
        : 'save online bookshelf before iOS app termination',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final library = await LibraryState.load();
      addTearDown(library.dispose);
      final first = demoNovels[0];
      final second = demoNovels[1];
      if (!verify) {
        await library.setShelfMembership(first.id, true, novel: first);
        await library.setShelfMembership(second.id, true, novel: second);
        await library.recordSearch('重启保留书架');
        await library.setChapter(first.id, 1);
        await library.setTheme(ThemeMode.dark);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getStringList('shelf'),
          containsAll(['${first.id}', '${second.id}']),
        );
      }
      expect(library.shelf, containsAll([first.id, second.id]));
      expect(library.cachedNovel(first.id)?.title, first.title);
      expect(library.chapterFor(first.id), 1);
      expect(library.recentSearches, contains('重启保留书架'));
      expect(library.theme, ThemeMode.dark);
    },
  );
}
