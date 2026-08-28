import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';

import 'src/common/widget/app.dart';

@pragma('vm:entry-point')
void main([List<String>? args]) => runZonedGuarded<Future<void>>(
  () async => runApp(const App()),
  (error, stackTrace) => log('Uncaught error: $error', stackTrace: stackTrace),
);
