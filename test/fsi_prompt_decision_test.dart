import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/fsi_prompt_decision.dart';

void main() {
  group('decideFsiPrompt', () {
    test('granted permission never shows the dialog', () {
      expect(
        decideFsiPrompt(canUseFullScreenIntent: true, dontAskAgain: false),
        FsiPromptDecision.granted,
      );
    });

    test('granted permission wins over dontAskAgain', () {
      expect(
        decideFsiPrompt(canUseFullScreenIntent: true, dontAskAgain: true),
        FsiPromptDecision.granted,
      );
    });

    test('denied permission prompts when user has not opted out', () {
      expect(
        decideFsiPrompt(canUseFullScreenIntent: false, dontAskAgain: false),
        FsiPromptDecision.showDialog,
      );
    });

    test('denied permission stays silent after "Don\'t ask again"', () {
      expect(
        decideFsiPrompt(canUseFullScreenIntent: false, dontAskAgain: true),
        FsiPromptDecision.skipDontAskAgain,
      );
    });

    test(
      'the dialog is reachable again after denial — unlike the old '
      'fsi_prompt_shown flag, "Later" is not persisted',
      () {
        // The decision is stateless: only an explicit dontAskAgain suppresses
        // the prompt. Each new check with dontAskAgain=false must decide
        // showDialog again.
        for (var i = 0; i < 3; i++) {
          expect(
            decideFsiPrompt(canUseFullScreenIntent: false, dontAskAgain: false),
            FsiPromptDecision.showDialog,
          );
        }
      },
    );
  });
}
