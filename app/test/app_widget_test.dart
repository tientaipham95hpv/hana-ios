import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hana_app/app/hana_app.dart';
import 'package:hana_app/app/providers.dart';
import 'package:hana_app/character/manifest/manifest_loader.dart';

import 'support/canonical_manifest.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('hana/secure_window'),
          (_) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('hana/secure_window'),
          null,
        );
  });

  testWidgets(
    'cold launch never blank: visible status, media notice, chat controls',
    (tester) async {
      await tester.pumpWidget(testApp());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backend-status')), findsOneWidget);
      expect(find.text('Backend: Chưa cấu hình'), findsOneWidget);
      expect(
        find.text('Character media not downloaded yet — silhouette shown.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
      expect(find.byKey(const Key('send-message')), findsOneWidget);
      expect(find.byKey(const Key('ptt-button')), findsOneWidget);
      expect(find.text('Voice input not configured'), findsOneWidget);
      expect(find.text('Chat'), findsWidgets);
    },
  );

  testWidgets('app launches with visible no-vault fallback and chat shell', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    expect(find.text('Đang chờ thư viện vault'), findsOneWidget);
    expect(find.byKey(const Key('backend-status')), findsOneWidget);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    expect(find.byKey(const Key('ptt-button')), findsOneWidget);
    expect(find.byKey(const Key('media-bootstrap-notice')), findsOneWidget);
    expect(find.byKey(const Key('mock-conversation')), findsOneWidget);
  });

  testWidgets('Character Lab exposes ten state choices and diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Character Lab'));
    await tester.pumpAndSettle();
    expect(find.text('Character Lab · debug'), findsOneWidget);
    expect(find.textContaining('Candidate pool:'), findsOneWidget);
    await tester.tap(find.textContaining('State: idle'));
    await tester.pumpAndSettle();
    expect(find.text('State: sleep'), findsOneWidget);
  });

  testWidgets('private route opens and locks a dedicated session', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cài đặt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('private-mode-entry')));
    await tester.pumpAndSettle();
    expect(find.text('Private engine đang hoạt động'), findsOneWidget);
    expect(find.text('Context: private'), findsOneWidget);
    await tester.tap(find.byKey(const Key('lock-private')));
    await tester.pumpAndSettle();
    expect(find.text('Cài đặt'), findsOneWidget);
  });

  testWidgets('sensitive daily override requires explicit confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cài đặt'));
    await tester.pumpAndSettle();
    final policyControl = find.byKey(const Key('per-clip-policy-mock'));
    await tester.ensureVisible(policyControl);
    await tester.tap(policyControl);
    await tester.pumpAndSettle();
    expect(find.text('confirm_sensitive'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-sensitive-allow')));
    await tester.pumpAndSettle();
    expect(
      find.text('Daily override đang bật cho clip nhạy cảm mẫu.'),
      findsOneWidget,
    );
  });

  testWidgets('manifest validation failure keeps chat shell and silhouette', (
    tester,
  ) async {
    await tester.pumpWidget(
      testApp(manifestResult: ManifestLoadResult.invalid('bad schema')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Đang chờ thư viện vault'), findsOneWidget);
    expect(find.byKey(const Key('backend-status')), findsOneWidget);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    expect(find.byKey(const Key('ptt-button')), findsOneWidget);
    await tester.tap(find.byTooltip('Cài đặt'));
    await tester.pumpAndSettle();
    expect(find.text('Cài đặt'), findsOneWidget);
    expect(find.byKey(const Key('per-clip-policy-mock')), findsNothing);
  });

  testWidgets('release-like routes cannot bypass private or Character Lab', (
    tester,
  ) async {
    await tester.pumpWidget(testApp(developerSurfaces: false));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Character Lab'), findsNothing);
    expect(find.byKey(const Key('mock-conversation')), findsNothing);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pushNamed('/private');
    await tester.pumpAndSettle();
    expect(find.text('Context: private'), findsNothing);
    expect(
      find.text('Tính năng này chưa khả dụng trong bản phát hành.'),
      findsOneWidget,
    );
    navigator.pop();
    navigator.pushNamed('/character-lab');
    await tester.pumpAndSettle();
    expect(find.text('Character Lab · debug'), findsNothing);
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cài đặt'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('private-mode-entry')), findsNothing);
    expect(find.byKey(const Key('private-mode-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('per-clip-policy-mock')), findsNothing);
  });

  testWidgets('backend misconfigured and media unavailable are explicit', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    expect(find.text('Backend: Chưa cấu hình'), findsOneWidget);
    expect(
      find.text(
        'Backend chưa cấu hình — tin nhắn sẽ báo lỗi cho tới khi cấu hình.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Character media not downloaded yet — silhouette shown.'),
      findsOneWidget,
    );
  });

  testWidgets('PTT unavailable state is visible', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    expect(find.text('Voice input not configured'), findsOneWidget);
    expect(find.byKey(const Key('ptt-button')), findsOneWidget);
  });

  testWidgets('Voice Lab accessible from settings in dev build', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cài đặt'));
    await tester.pumpAndSettle();
    final voiceLab = find.byKey(const Key('ios-voice-lab'));
    await tester.scrollUntilVisible(
      voiceLab,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(voiceLab, findsOneWidget);
    await tester.tap(voiceLab);
    await tester.pumpAndSettle();
    expect(find.text('iOS Voice Lab'), findsOneWidget);
  });

  testWidgets('Phase 6.6 uses full-screen Stack with overlay controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    final root = find.byKey(const Key('character-stage-root'));
    final stageViewport = find.byKey(const Key('character-stage-viewport'));
    final chat = find.byKey(const Key('chat-overlay'));
    final composer = find.byKey(const Key('composer-overlay'));
    expect(root, findsOneWidget);
    expect(stageViewport, findsOneWidget);
    expect(chat, findsOneWidget);
    expect(composer, findsOneWidget);
    expect(tester.getSize(root), const Size(390, 844));
    expect(tester.getSize(stageViewport), const Size(390, 844));
    expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard moves composer without shrinking character stage', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    final root = find.byKey(const Key('character-stage-root'));
    final stageViewport = find.byKey(const Key('character-stage-viewport'));
    final composer = find.byKey(const Key('composer-overlay'));
    expect(tester.getSize(root), const Size(390, 844));
    expect(tester.getSize(stageViewport), const Size(390, 844));
    expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(524));
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    expect(find.byKey(const Key('send-message')), findsOneWidget);
    expect(find.byKey(const Key('ptt-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small portrait viewport keeps safe controls visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    expect(find.byTooltip('Cài đặt'), findsOneWidget);
    expect(find.byKey(const Key('composer-overlay')), findsOneWidget);
    expect(find.byKey(const Key('ptt-status')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget testApp({ManifestLoadResult? manifestResult, bool? developerSurfaces}) =>
    ProviderScope(
      overrides: [
        manifestLoadResultProvider.overrideWithValue(
          manifestResult ?? ManifestLoadResult.valid(canonicalManifest()),
        ),
      ],
      child: HanaApp(developerSurfaces: developerSurfaces),
    );
