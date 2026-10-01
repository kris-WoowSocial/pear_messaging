library;

import 'package:flutter/material.dart';
import 'package:social_media_recorder/provider/sound_record_notifier.dart';

/// Shows the lock/unlock icon above the record button while recording.
class LockRecord extends StatefulWidget {
  final SoundRecordNotifier soundRecorderState;
  final Widget? lockIcon;

  const LockRecord({
    this.lockIcon,
    required this.soundRecorderState,
    super.key,
  });

  @override
  _LockRecordState createState() => _LockRecordState();
}

class _LockRecordState extends State<LockRecord>
    with TickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    if (!widget.soundRecorderState.buttonPressed) return Container();

    return AnimatedPadding(
      duration: const Duration(seconds: 1),
      padding:
          EdgeInsets.all(widget.soundRecorderState.second % 2 == 0 ? 0 : 8),
      child: Transform.translate(
        offset: const Offset(0, -70),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeIn,
            opacity: widget.soundRecorderState.edge >= 50 ? 0 : 1,
            child: Container(
              height: 50 - widget.soundRecorderState.heightPosition < 0
                  ? 0
                  : 50 - widget.soundRecorderState.heightPosition,
              color: Colors.grey.shade100,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: widget.lockIcon ??
                    Stack(
                      children: [
                        Align(
                          alignment: Alignment.topCenter,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeIn,
                            opacity:
                                widget.soundRecorderState.second % 2 != 0 ? 0 : 1,
                            child: const Icon(Icons.lock_outline_rounded),
                          ),
                        ),
                        Align(
                          alignment: Alignment.topCenter,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeIn,
                            opacity:
                                widget.soundRecorderState.second % 2 == 0 ? 0 : 1,
                            child: const Icon(Icons.lock_open_rounded),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
