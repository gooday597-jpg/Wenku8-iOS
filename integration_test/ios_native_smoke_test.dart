import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:xml/xml.dart';

import '../test/local_books_test.dart' show epubFixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native TXT/EPUB import persists readable local chapters', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('iOS 文档导入验证'))),
    );
    final support = await getApplicationSupportDirectory();
    final directory = await Directory(
      '${support.path}/ios-import-smoke',
    ).create(recursive: true);
    final documents = BookDocuments();
    final store = LocalBookStore(Directory('${directory.path}/books'));
    await store.load();
    String? decoded;
    try {
      final original = File('${directory.path}/test.txt');
      await original.writeAsBytes(utf8.encode('第一章 试读\n中文本地正文。'));
      decoded = await documents.decodeTextFile(original.path);
      final textBook = await store.importFile(
        'test.txt',
        original.path,
        decodedPath: decoded,
      );
      expect(
        await store.chapterContent(textBook.id, textBook.chapters.first),
        contains('中文本地正文'),
      );
      final gbk = File('${directory.path}/gbk.txt');
      await gbk.writeAsBytes([0xd6, 0xd0, 0xce, 0xc4]);
      expect(await documents.decodeText(gbk.path, encoding: 'GB18030'), '中文');
      final epub = File('${directory.path}/test.epub');
      await epub.writeAsBytes(epubFixture());
      final epubBook = await store.importFile('test.epub', epub.path);
      expect(epubBook.chapters.length, 2);
      expect(
        await store.chapterContent(epubBook.id, epubBook.chapters.first),
        contains('第一段'),
      );
      final reopened = LocalBookStore(Directory('${directory.path}/books'));
      try {
        await reopened.load();
        expect(reopened.book(textBook.id), isNotNull);
        expect(reopened.book(epubBook.id), isNotNull);
        expect(
          await reopened.chapterContent(textBook.id, textBook.chapters.first),
          contains('中文本地正文'),
        );
      } finally {
        reopened.dispose();
      }
      const settings = MethodChannel('org.mewx.wenku8/custom_speech');
      await settings.invokeMethod<void>('write', '{"smoke":true}');
      expect(await settings.invokeMethod<String>('read'), '{"smoke":true}');
      await settings.invokeMethod<void>('write');
      expect(await settings.invokeMethod<String>('read'), isNull);
      expect(
        await const MethodChannel(
          'org.mewx.wenku8/reader_controls',
        ).invokeMethod<double>('brightness'),
        inInclusiveRange(0, 1),
      );
    } finally {
      store.dispose();
      if (decoded != null) {
        await documents.releaseBooks([
          BookDocumentSelection(name: 'decoded.txt', path: decoded),
        ]);
      }
      await directory.delete(recursive: true);
    }
  });

  testWidgets('native online relay returns real book metadata', (tester) async {
    final response = await LegacyTransport.request(
      'action=novellist&sort=lastupdate&page=1&t=0',
    );
    final root = XmlDocument.parse(response).rootElement;
    expect(root.name.local, 'result');
    expect(root.findElements('item'), isNotEmpty);
  });
}
