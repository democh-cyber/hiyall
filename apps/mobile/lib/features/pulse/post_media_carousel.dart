import 'package:flutter/material.dart';

import '../../core/api.dart';
import 'pulse_common.dart';

class PostMediaCarousel extends StatefulWidget {
  final List<PostMedia> media;
  final VoidCallback onDoubleTap;
  const PostMediaCarousel({
    super.key,
    required this.media,
    required this.onDoubleTap,
  });
  @override
  State<PostMediaCarousel> createState() => _PostMediaCarouselState();
}

class _PostMediaCarouselState extends State<PostMediaCarousel> {
  int page = 0;
  bool burst = false;

  void doubleTap() {
    widget.onDoubleTap();
    setState(() => burst = true);
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => burst = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Portrait down to 4:5, landscape up to 1.91:1, like most photo feeds.
    final aspect = widget.media.first.aspect.clamp(0.8, 1.91);
    return AspectRatio(
      aspectRatio: aspect,
      child: GestureDetector(
        onDoubleTap: doubleTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              itemCount: widget.media.length,
              onPageChanged: (i) => setState(() => page = i),
              itemBuilder: (_, i) => PostPhoto(widget.media[i]),
            ),
            if (widget.media.length > 1) ...[
              PositionedDirectional(
                top: 10,
                end: 10,
                child: _PageCounter(page: page, count: widget.media.length),
              ),
              PositionedDirectional(
                bottom: 10,
                start: 0,
                end: 0,
                child: _PageDots(page: page, count: widget.media.length),
              ),
            ],
            IgnorePointer(
              child: AnimatedScale(
                scale: burst ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                child: const Center(
                  child: Text('❤️', style: TextStyle(fontSize: 96)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageCounter extends StatelessWidget {
  final int page, count;
  const _PageCounter({required this.page, required this.count});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      '${page + 1}/$count',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _PageDots extends StatelessWidget {
  final int page, count;
  const _PageDots({required this.page, required this.count});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 0; i < count; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: i == page ? 16 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: i == page ? Colors.white : Colors.white60,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
    ],
  );
}
