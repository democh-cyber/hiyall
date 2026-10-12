import 'package:flutter/material.dart';

/// What sits on top of a received photo while it is not (yet) a picture: a
/// progress ring that says what it is waiting for, a clear failure with a
/// Retry, or a plain "expired". Each is a small dark plate, so the words read
/// over any photo, and each scales down rather than spill out of a small
/// (320 px wide, wide-aspect) photo. No decorative placeholder art: the only
/// picture behind them is the blurred preview of the real photo.
const _plate = Color(0xcc101310);

/// A scrim over the photo with [child] centred on a dark plate.
class PhotoStatePlate extends StatelessWidget {
  final Widget child;
  const PhotoStatePlate({super.key, required this.child});
  @override
  Widget build(BuildContext context) => MediaQuery(
    // The photo is a fixed size: text may grow a little, not push the plate
    // out of it.
    data: MediaQuery.of(context).copyWith(
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
    ),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 190),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _plate,
              borderRadius: BorderRadius.circular(18),
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
}

const _label = TextStyle(
  color: Colors.white,
  fontSize: 13,
  height: 1.25,
  fontWeight: FontWeight.w700,
);
const _detail = TextStyle(
  color: Color(0xffd9ddd4),
  fontSize: 12,
  height: 1.3,
  fontWeight: FontWeight.w500,
);

/// A ring (filling with [progress] once the download reports it, spinning
/// until then) with "Loading photo…" beside the blurred preview.
class PhotoLoadingState extends StatelessWidget {
  /// 0 to 1, or 0 / null while nothing has been reported.
  final double? progress;
  const PhotoLoadingState({super.key, this.progress});
  @override
  Widget build(BuildContext context) => PhotoStatePlate(
    child: Semantics(
      label: 'Loading photo',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                key: const Key('photo-loading-ring'),
                value: progress != null && progress! > 0 ? progress : null,
                color: Colors.white,
                backgroundColor: Colors.white24,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 8),
            const Text('Loading photo…', style: _label),
          ],
        ),
      ),
    ),
  );
}

/// "Couldn't load photo" with a Retry button, for a download that failed in a
/// way trying again may fix.
class PhotoRetryState extends StatelessWidget {
  final VoidCallback onRetry;

  /// The key of the Retry button (the photo's own, so tests and screen readers
  /// can tell two photos apart).
  final Key? retryKey;
  const PhotoRetryState({super.key, required this.onRetry, this.retryKey});
  @override
  Widget build(BuildContext context) => PhotoStatePlate(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 22),
        const SizedBox(height: 6),
        const Text(
          'Couldn’t load photo',
          textAlign: TextAlign.center,
          style: _label,
        ),
        const SizedBox(height: 8),
        Semantics(
          button: true,
          label: 'Retry loading photo',
          excludeSemantics: true,
          onTap: onRetry,
          child: GestureDetector(
            key: retryKey,
            behavior: HitTestBehavior.opaque,
            onTap: onRetry,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44, minWidth: 96),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.refresh_rounded,
                        size: 18,
                        color: Color(0xff20231f),
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Retry',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xff20231f),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// A photo that is gone for good: expired, removed by the sender or no longer
/// for this account. Retrying cannot help, so there is no button, only the
/// reason.
class PhotoExpiredState extends StatelessWidget {
  const PhotoExpiredState({super.key});
  @override
  Widget build(BuildContext context) => const PhotoStatePlate(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hide_image_outlined, color: Colors.white, size: 24),
        SizedBox(height: 6),
        Text('Photo expired', textAlign: TextAlign.center, style: _label),
        SizedBox(height: 3),
        Text(
          'Photos are removed 30 days after they’re sent.',
          textAlign: TextAlign.center,
          style: _detail,
        ),
      ],
    ),
  );
}

/// A photo that arrived but cannot be opened (damaged or tampered with).
class PhotoDamagedState extends StatelessWidget {
  const PhotoDamagedState({super.key});
  @override
  Widget build(BuildContext context) => const PhotoStatePlate(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, color: Colors.white, size: 24),
        SizedBox(height: 6),
        Text(
          'Can’t open this photo',
          textAlign: TextAlign.center,
          style: _label,
        ),
      ],
    ),
  );
}
