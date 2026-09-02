library social_media_recorder;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:social_media_recorder/audio_encoder_type.dart';
import 'package:social_media_recorder/provider/sound_record_notifier.dart';
import 'package:social_media_recorder/widgets/lock_record.dart';
import 'package:social_media_recorder/widgets/show_counter.dart';
import 'package:social_media_recorder/widgets/show_mic_with_text.dart';
import 'package:social_media_recorder/widgets/sound_recorder_when_locked_design.dart';

class SocialMediaRecorder extends StatefulWidget {
  /// Background color of the cancel text.
  final Color? cancelTextBackGroundColor;

  /// Function that returns the recorded sound file and duration string.
  final Function(File soundFile, String time) sendRequestFunction;

  /// Called when recording starts.
  final Function()? startRecording;

  /// Called when recording stops; receives the duration (even if < 1 sec).
  final Function(String time)? stopRecording;

  /// Called when microphone permission is denied while trying to record.
  final Function()? onPermissionDenied;

  /// Icon shown on the record button.
  final Widget? recordIcon;

  /// Icon shown when recording is locked.
  final Widget? recordIconWhenLockedRecord;

  /// Background color of the record button while recording.
  final Color? recordIconBackGroundColor;

  /// Background color of the record button when locked.
  final Color? recordIconWhenLockBackGroundColor;

  /// Background color of the whole recording widget.
  final Color? backGroundColor;

  /// Style of the counter text.
  final TextStyle? counterTextStyle;

  /// Text hint telling the user to drag left to cancel.
  final String? slideToCancelText;

  /// Style of the slide-to-cancel text.
  final TextStyle? slideToCancelTextStyle;

  /// Text shown when recording is locked.
  final String? cancelText;

  /// Style of the cancel text.
  final TextStyle? cancelTextStyle;

  /// Optional directory to store recordings. If empty, a temp directory is used.
  final String? storeSoundRecoringPath;

  /// Audio encoder type.
  final AudioEncoderType encode;

  /// Border radius of the idle record button.
  final BorderRadius? radius;

  /// Background color of the counter.
  final Color? counterBackGroundColor;

  /// Custom lock icon.
  final Widget? lockButton;

  /// Custom send icon shown when locked.
  final Widget? sendButtonIcon;

  /// Maximum recording time in seconds.
  final int? maxRecordTimeInSecond;

  /// Full height of the recording package.
  final double fullRecordPackageHeight;

  /// Width of the idle record button.
  final double initRecordPackageWidth;

  // ignore: sort_constructors_first
  const SocialMediaRecorder({
    this.sendButtonIcon,
    this.initRecordPackageWidth = 40,
    this.fullRecordPackageHeight = 50,
    this.maxRecordTimeInSecond,
    this.storeSoundRecoringPath = '',
    required this.sendRequestFunction,
    this.startRecording,
    this.stopRecording,
    this.onPermissionDenied,
    this.recordIcon,
    this.lockButton,
    this.counterBackGroundColor,
    this.recordIconWhenLockedRecord,
    this.recordIconBackGroundColor = Colors.blue,
    this.recordIconWhenLockBackGroundColor = Colors.blue,
    this.backGroundColor,
    this.cancelTextStyle,
    this.counterTextStyle,
    this.slideToCancelTextStyle,
    this.slideToCancelText = ' Slide to Cancel >',
    this.cancelText = 'Cancel',
    this.encode = AudioEncoderType.AAC,
    this.cancelTextBackGroundColor,
    this.radius,
    Key? key,
  }) : super(key: key);

  @override
  _SocialMediaRecorderState createState() => _SocialMediaRecorderState();
}

class _SocialMediaRecorderState extends State<SocialMediaRecorder> {
  late SoundRecordNotifier soundRecordNotifier;

  @override
  void initState() {
    soundRecordNotifier = SoundRecordNotifier(
      maxRecordTime: widget.maxRecordTimeInSecond,
      startRecording: widget.startRecording ?? () {},
      stopRecording: widget.stopRecording ?? (String x) {},
      sendRequestFunction: widget.sendRequestFunction,
      onPermissionDenied: widget.onPermissionDenied,
    );
    soundRecordNotifier.initialStorePathRecord =
        widget.storeSoundRecoringPath ?? '';
    soundRecordNotifier.encode = widget.encode;
    soundRecordNotifier.isShow = false;
    soundRecordNotifier.voidInitialSound();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    soundRecordNotifier.maxRecordTime = widget.maxRecordTimeInSecond;
    soundRecordNotifier.startRecording = widget.startRecording ?? () {};
    soundRecordNotifier.stopRecording = widget.stopRecording ?? (String x) {};
    soundRecordNotifier.sendRequestFunction = widget.sendRequestFunction;
    soundRecordNotifier.onPermissionDenied = widget.onPermissionDenied;

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SoundRecordNotifier>.value(
          value: soundRecordNotifier,
        ),
      ],
      child: Consumer<SoundRecordNotifier>(
        builder: (context, value, _) {
          return Directionality(
            textDirection: TextDirection.rtl,
            child: makeBody(value),
          );
        },
      ),
    );
  }

  Widget makeBody(SoundRecordNotifier state) {
    return Column(
      children: [
        GestureDetector(
          onHorizontalDragUpdate: (scrollEnd) {
            state.updateScrollValue(scrollEnd.globalPosition, context);
          },
          onHorizontalDragEnd: (x) {
            if (state.buttonPressed && !state.isLocked) state.finishRecording();
          },
          child: Container(
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: recordVoice(state),
          ),
        ),
      ],
    );
  }

  Widget recordVoice(SoundRecordNotifier state) {
    if (state.lockScreenRecord) {
      return SoundRecorderWhenLockedDesign(
        cancelText: widget.cancelText,
        fullRecordPackageHeight: widget.fullRecordPackageHeight,
        sendButtonIcon: widget.sendButtonIcon,
        cancelTextBackGroundColor: widget.cancelTextBackGroundColor,
        cancelTextStyle: widget.cancelTextStyle,
        counterBackGroundColor: widget.counterBackGroundColor,
        recordIconWhenLockBackGroundColor:
            widget.recordIconWhenLockBackGroundColor ?? Colors.blue,
        counterTextStyle: widget.counterTextStyle,
        recordIconWhenLockedRecord: widget.recordIconWhenLockedRecord,
        sendRequestFunction: widget.sendRequestFunction,
        soundRecordNotifier: state,
        stopRecording: widget.stopRecording,
      );
    }

    return Listener(
      onPointerDown: (details) async {
        state.setNewInitialDraggableHeight(details.position.dy);
        state.resetEdgePadding();
        soundRecordNotifier.isShow = true;
        state.record(widget.startRecording);
      },
      onPointerUp: (details) async {
        if (!state.isLocked) {
          state.finishRecording();
        }
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: soundRecordNotifier.isShow ? 0 : 300),
        height: widget.fullRecordPackageHeight,
        width: soundRecordNotifier.isShow
            ? MediaQuery.of(context).size.width
            : widget.initRecordPackageWidth,
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: EdgeInsets.only(right: state.edge),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: soundRecordNotifier.isShow
                        ? BorderRadius.circular(12)
                        : widget.radius != null && !soundRecordNotifier.isShow
                            ? widget.radius
                            : BorderRadius.circular(0),
                    color: widget.backGroundColor ?? Colors.grey.shade100,
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: ShowMicWithText(
                          initRecordPackageWidth: widget.initRecordPackageWidth,
                          counterBackGroundColor:
                              widget.counterBackGroundColor,
                          backGroundColor: widget.recordIconBackGroundColor,
                          fullRecordPackageHeight:
                              widget.fullRecordPackageHeight,
                          recordIcon: widget.recordIcon,
                          shouldShowText: soundRecordNotifier.isShow,
                          soundRecorderState: state,
                          slideToCancelTextStyle: widget.slideToCancelTextStyle,
                          slideToCancelText: widget.slideToCancelText,
                        ),
                      ),
                      if (soundRecordNotifier.isShow)
                        Center(
                          child: ShowCounter(
                            counterBackGroundColor:
                                widget.counterBackGroundColor,
                            soundRecorderState: state,
                            fullRecordPackageHeight:
                                widget.fullRecordPackageHeight,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 60,
              child: LockRecord(
                soundRecorderState: state,
                lockIcon: widget.lockButton,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
