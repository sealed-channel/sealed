import 'package:flutter/material.dart';
import 'package:sealed_app/ui/shared/theme.dart';

class ComponentBuilder extends StatelessWidget {
  ComponentBuilder({super.key, required this.component});
  Widget component;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: neutralColor.withValues(alpha: 0.08),
      body: Container(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(child: component),
        ],
      )));
  }
}
