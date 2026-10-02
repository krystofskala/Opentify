import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import 'player_bar.dart';
import 'state_views.dart';
import 'section_app_bar.dart';

/// Loading/error stav detailové obrazovky (Album/Interpret/Playlist/Skladba)
/// -- vždy s reálným `AppBar`em a tlačítkem zpět, ať pomalé načítání není
/// slepá ulička. Loading ukazuje skeleton hlavičky + seznamu, ne spinner.
class DetailLoadingScaffold extends StatelessWidget {
  const DetailLoadingScaffold({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SectionAppBar(''),
      bottomNavigationBar: const PlayerBar(),
      body: const SingleChildScrollView(
        physics: NeverScrollableScrollPhysics(),
        padding: EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SkeletonBox(width: 120, height: 120, radius: AppRadii.md),
                SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(width: 60, height: 10, radius: AppRadii.xs),
                      SizedBox(height: AppSpacing.xs),
                      SkeletonBox(width: 200, height: 22, radius: AppRadii.xs),
                      SizedBox(height: AppSpacing.xs),
                      SkeletonBox(width: 120, height: 14, radius: AppRadii.xs),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: AppSpacing.lg),
            SkeletonTrackList(count: 6),
          ],
        ),
      ),
    );
  }
}

class DetailErrorScaffold extends StatelessWidget {
  const DetailErrorScaffold({super.key, required this.message, this.error, this.onRetry});

  final String message;
  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SectionAppBar(''),
      bottomNavigationBar: const PlayerBar(),
      body: ErrorState(message: message, error: error, onRetry: onRetry),
    );
  }
}
