import 'package:flutter/material.dart';

import '../models/channel.dart';

class ChannelLogo extends StatelessWidget {
  const ChannelLogo({super.key, required this.channel, this.size = 48});
  final Channel channel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Center(
      child: Text(
        _initials(channel.name),
        style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: scheme.surfaceContainerHighest,
        child: channel.logo == null
            ? fallback
            : Image.network(
                channel.logo!,
                fit: BoxFit.contain,
                cacheWidth: (size * 2).round(),
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }

  static String _initials(String name) {
    final t = name.trim();
    if (t.isEmpty) return 'TV';
    return t.substring(0, t.length < 2 ? t.length : 2).toUpperCase();
  }
}
