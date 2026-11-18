import 'dart:async';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      MediaKit.ensureInitialized();
      FilePicker.skipEntitlementsChecks();
      PlatformDispatcher.instance.onError = (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
        return true;
      };
      runApp(const CcsEegApp());
    },
    (error, stack) => FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    ),
  );
}
