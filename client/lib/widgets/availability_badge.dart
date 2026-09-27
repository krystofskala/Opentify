import 'package:flutter/material.dart';

import '../models/availability.dart';

/// Vizuální odlišení `available`/`provisionable`/`unavailable` napříč celou
/// appkou (search výsledky, tracklist alba, doporučení) -- jedno místo pro
/// barvy a ikony, aby se stavy nezačaly v UI rozcházet.
class AvailabilityBadge extends StatelessWidget {
  const AvailabilityBadge({super.key, required this.availability});

  final Availability availability;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (availability) {
      Availability.available => (Icons.check_circle, Colors.greenAccent, 'K dispozici'),
      Availability.provisionable => (Icons.cloud_download_outlined, Colors.amberAccent, 'Lze obstarat'),
      Availability.unavailable => (Icons.block, Colors.grey, 'Nedostupné'),
    };
    return Tooltip(
      message: label,
      child: Icon(icon, size: 18, color: color),
    );
  }
}
