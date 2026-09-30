import 'package:flutter/material.dart';

import 'screens/projects_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenFicFApp());
}

class OpenFicFApp extends StatelessWidget {
  const OpenFicFApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenFicF',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: const ProjectsScreen(),
    );
  }
}