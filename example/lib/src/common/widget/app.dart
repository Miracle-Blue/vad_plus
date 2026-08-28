import 'package:flutter/material.dart';

import '../../feature/home/screen/home_screen.dart';

/// {@template app}
/// App widget.
/// {@endtemplate}
class App extends StatelessWidget {
  /// {@macro app}
  const App({
    super.key, // ignore: unused_element
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.dark().copyWith(
      colorScheme: ColorScheme.dark(primary: Colors.teal, secondary: Colors.tealAccent, surface: Colors.grey.shade900),
    ),
    home: HomeScreen(),
  );
}
