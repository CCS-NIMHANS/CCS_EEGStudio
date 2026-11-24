import 'package:ccs_eeg_app/src/update_checker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compares release versions numerically', () {
    expect(UpdateChecker.compareVersions('v1.10.0', '1.9.9'), greaterThan(0));
    expect(UpdateChecker.compareVersions('1.2.0', '1.2'), 0);
    expect(UpdateChecker.compareVersions('1.2.0', '1.2.1'), lessThan(0));
  });

  test('selects the canonical package for every platform', () {
    final assets = <Map<String, dynamic>>[
      {
        'name': 'CCSEEGStudio-linux-x86_64.rpm',
        'browser_download_url': 'https://example.test/app.rpm',
        'size': 10,
      },
      {
        'name': 'CCSEEGStudio-macos.zip',
        'browser_download_url': 'https://example.test/app.zip',
        'size': 20,
      },
      {
        'name': 'CCSEEGStudio-Installer.exe',
        'browser_download_url': 'https://example.test/app.exe',
        'size': 30,
      },
      {
        'name': 'CCSEEGStudio-linux-amd64.deb',
        'browser_download_url': 'https://example.test/app.deb',
        'size': 40,
      },
    ];

    expect(
      UpdateChecker.findAsset(assets, platform: UpdatePlatform.macOS)?.name,
      'CCSEEGStudio-macos.zip',
    );
    expect(
      UpdateChecker.findAsset(assets, platform: UpdatePlatform.windows)?.name,
      'CCSEEGStudio-Installer.exe',
    );
    expect(
      UpdateChecker.findAsset(
        assets,
        platform: UpdatePlatform.linuxDebian,
      )?.name,
      'CCSEEGStudio-linux-amd64.deb',
    );
    expect(
      UpdateChecker.findAsset(assets, platform: UpdatePlatform.linuxRpm)?.name,
      'CCSEEGStudio-linux-x86_64.rpm',
    );
  });

  testWidgets(
    'FormattedReleaseNotes and AppUpdateDialog format markdown cleanly without raw syntax',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 750));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const md = '''
### Multi-Factor **Group Stats** (`ccs-eeg-engine`)

- **Standalone Native Engine (`factorial_lmm`)**
  - Runs _REML MixedLM_ and Type III tests on `mean_amplitude_ERP`
  - See [Code Signing Policy](CODE_SIGNING_POLICY.md)
- Second bullet item
#### Sub-heading with `inline_code`
> Important note: no Python needed.

```
flutter test
```
''';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppUpdateDialog(
              info: const UpdateInfo(
                currentVersion: '1.2.63',
                latestVersion: '1.2.64',
                hasUpdate: true,
                releaseNotes: md,
                releaseUrl: 'https://example.test/release',
                asset: ReleaseAsset(
                  name: 'CCSEEGStudio-macos.zip',
                  downloadUrl: 'https://example.test/app.zip',
                  sizeBytes: 150000000,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final richTextContent = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText())
          .join('\n');
      expect(richTextContent, contains('Multi-Factor Group Stats'));
      expect(richTextContent, contains('Standalone Native Engine'));
      expect(richTextContent, contains('mean_amplitude_ERP'));
      expect(richTextContent, contains('Code Signing Policy'));
      expect(richTextContent, contains('Important note: no Python needed.'));
      expect(richTextContent, contains('flutter test'));
      expect(richTextContent, isNot(contains('**')));
      expect(richTextContent, isNot(contains('`')));
      expect(richTextContent, isNot(contains('(CODE_SIGNING_POLICY.md)')));
      expect(richTextContent, isNot(contains('### ')));
      expect(find.text('◦'), findsNWidgets(2));
      expect(find.text('•'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
