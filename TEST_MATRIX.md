# Secure Call Device Test Matrix

Branches: `pear_messaging/video-integration` and `vant_chatting/turn-credentials`. Use two physical devices where possible; do not rely on a fresh socket for rows marked cold-start.

| ID | Scenario | Steps | Expected | Android | iOS |
|---|---|---|---|---|---|
| D1 | Late flag delivery | Open a 1:1 chat before Remote Config finishes; flip `ff_encrypted_signaling` and `ff_video_calling` on | Video icon appears without leaving/reopening the chat | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D2 | Cold-start REST accept | Force-kill callee, start voice call, accept from native notification, reopen app and send `call_resync` | Original SDP offer is delivered within the 45s REST resync grace; ring/resync timers clear | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D3 | Legacy store → new voice | Store-built caller calls new-build callee with encrypted/video flags off | Plain `sdpOffer`/`sdpAnswer`; voice connects; no crypto or video fields | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D4 | New → legacy store voice | New-build caller calls store-built callee with encrypted/video flags off | Plain `sdpOffer`/`sdpAnswer`; voice connects; no downgrade rejection | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D5 | Bound peer without `encrypted_call` | First-time bound callee did not register encrypted calling; send voice offer | Plain voice remains allowed; identity pin is not created by server metadata alone | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D6 | Signed encrypted floor | Contact once signed `encrypted_call`; attempt plain voice | Offer rejected `encryption_required`; encrypted path still works | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D7 | Plaintext downgrade in active encrypted call | Send encrypted offer, then tamper/plain `sdpAnswer` | Answer is rejected and not relayed; subsequent valid encrypted answer connects | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D8 | Cross-target capability replay | Send a valid signed capability announcement for B to A | A rejects it; target-bound signature cannot be replayed | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D9 | Capability rollback replay | Replay the same signed older-sequence announcement five times | One warning/contact entry; ack remains non-blocking `unchanged`; signed encrypted floor unchanged | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D10 | Re-verification recovery | From reset warning, run contact verification, then send a newer valid announcement | Warning clears; newer sequence becomes baseline; call policy stays encrypted if floored | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D11 | Video capability | Both peers 1.8+, encrypted+video flags on, callee advertises `video_call` | Caller opens `/call/video` immediately; callee opens it immediately after Accept; local camera is full-screen while ringing/connecting and remote video takes over on arrival | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D12 | Bounded crypto-session state | Exercise repeated reconnects/offers after >100k claim simulation | Oldest live claim evicts; newer claims stay valid; no clear-all outage | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |
| D13 | Ringing camera privacy release | Start a video call, confirm the camera indicator/privacy dot appears during ringing, then cancel before answer; repeat after decline/timeout/end | Camera indicator/privacy dot turns off immediately; no preview or camera session remains active | ☐ Pass ☐ Fail | ☐ Pass ☐ Fail |

Automation anchors: server `cold-started callee can REST accept and resync within grace`; client `five signed capability rollbacks warn once and preserve encrypted floor`; plus the mixed-version and downgrade tests in `server/tests/call_video_capability.test.js`.

## Two-device video regression checklist

Use two physical devices. Capture `flutter run --verbose` / logcat from each side for any failure. After the transport fix, the caller's camera track must be in the initial offer and the callee's camera track must be in the initial answer; both sides should see `m=video` `a=sendrecv` and rising outbound/inbound video stats.

| ID | Scenario | Check | Pass/Fail |
|---|---|---|---|
| V1 | Outgoing video call | Caller taps video; `/call/video` opens; local preview appears while offer is created; remote video appears after callee accepts | ☐ Pass ☐ Fail |
| V2 | Incoming video accept | Callee accepts from incoming screen; `/call/video` opens before `acceptCall` returns; both local and remote video visible after handshake | ☐ Pass ☐ Fail |
| V3 | Cold-start video accept | Force-kill callee, start video call, accept from native notification, reopen app | Resync delivers offer, video connects, remote video appears | ☐ Pass ☐ Fail |
| V4 | Video SDP direction | Inspect logs for `local offer`, `remote offer`, `local answer`, `remote answer` | All video sections show `a=sendrecv` (or `a=sendonly` for camera-off side only when toggled) | ☐ Pass ☐ Fail |
| V5 | Video stats flow | After `RTCPeerConnectionStateConnected` | `VIDEO OUT` bytes/frames increase on sender; `VIDEO IN` bytes/frames increase on receiver | ☐ Pass ☐ Fail |
| V6 | Camera toggle | Tap camera-off during connected video call | Local preview pauses, peer sees placeholder, `sendCallMediaUpdate(video=false)` log appears | ☐ Pass ☐ Fail |
| V7 | Camera flip | Tap flip during connected video call | Local preview switches front/rear and continues sending | ☐ Pass ☐ Fail |
| V8 | Network change | Move one device from Wi-Fi to mobile data during connected video call | Call stays connected or ICE restart recovers within ~10s; video resumes | ☐ Pass ☐ Fail |
| V9 | Mixed-version fallback | Store-built caller (pre-video) calls new-build callee | Plain audio call connects; callee does not show video route | ☐ Pass ☐ Fail |
| V10 | Camera privacy on cancel | Start video call, then caller cancels before answer | Camera privacy dot/indicator turns off; `Call ended and cleaned up` log appears | ☐ Pass ☐ Fail |

Log markers to look for:

- `📞 Local audio/video stream captured with hardware optimization`
- `📞 Active senders before createOffer/createAnswer: 2` (audio + video)
- `🧪 local offer SDP video m-line:` `m=video ...` `a=sendrecv`
- `🧪 remote answer SDP video m-line:` `m=video ...` `a=sendrecv`
- `📞 Remote track received`
- `📊 VIDEO OUT id=... bytes=... frames=...`
- `📊 VIDEO IN id=... bytes=... frames=...`
