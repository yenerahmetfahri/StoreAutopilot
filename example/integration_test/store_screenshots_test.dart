// StoreAutopilot store screenshots. Run by `storeautopilot shots` / `release` once per locale and platform.
// Start the app with demo data (no real accounts, no network), navigate to each screen and call
// takeStoreScreenshot(tester, '<id>') for every id listed under `screenshots` in storeautopilot.yml.
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show Key, WidgetsApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:storeautopilot_example/main.dart';

/// Locale id from storeautopilot.yml (e.g. 'en'); use it to start the app in that language.
const storeLocale = String.fromEnvironment('STORE_LOCALE', defaultValue: 'en');

/// 'phone' or 'tablet' (iPad), if a screen should look different on the larger display.
const storeDevice = String.fromEnvironment('STORE_DEVICE', defaultValue: 'phone');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetsApp.debugAllowBannerOverride = false; // no DEBUG ribbon in store screenshots
  var surfaceConverted = false;

  Future<void> takeStoreScreenshot(WidgetTester tester, String id) async {
    await tester.pumpAndSettle();
    if (Platform.isAndroid && !surfaceConverted) {
      await binding.convertFlutterSurfaceToImage();
      surfaceConverted = true;
      await tester.pumpAndSettle();
    }
    await binding.takeScreenshot(id);
  }

  testWidgets('store screenshots', (tester) async {
    await tester.pumpWidget(ExampleApp(locale: storeLocale));
    await takeStoreScreenshot(tester, '01_tasks');

    await tester.tap(find.byKey(const Key('stats')));
    await takeStoreScreenshot(tester, '02_stats');
  });
}
