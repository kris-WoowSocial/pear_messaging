#!/usr/bin/env python3
"""Structural check: every code path in pushRegistry(_:didReceiveIncomingPushWith:for:completion:)
must report to CallKit (showCallkitIncoming) before completion().

iOS terminates the app for VoIP pushes that are not reported; this check
prevents regressions like the old `call_cancelled` early-return that called
completion() without any report.

Rule: inside the handler body, each `completion()` must have its nearest
preceding control landmark be either `showCallkitIncoming(` or the
`guard type == .voIP` early exit (non-VoIP pushes are exempt from the
report contract — PushKit only ever delivers .voIP anyway).
"""
import re
import sys

PATH = "ios/Runner/AppDelegate.swift"


def extract_handler_body(src: str) -> str:
    m = re.search(
        r"func pushRegistry\(_\s*registry:\s*PKPushRegistry,\s*didReceiveIncomingPushWith", src
    )
    if not m:
        sys.exit("FAIL: didReceiveIncomingPushWith handler not found")
    start = src.index("{", m.end())
    depth = 0
    for i in range(start, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i]
    sys.exit("FAIL: unbalanced braces in handler")


def main() -> int:
    body = extract_handler_body(open(PATH).read())
    landmarks = []
    for n, raw in enumerate(body.split("\n")):
        line = raw.split("//", 1)[0]  # strip line comments
        if "showCallkitIncoming(" in line:
            landmarks.append((n, "report"))
        elif "guard type == .voIP" in line:
            landmarks.append((n, "guard"))
        elif "completion()" in line:
            landmarks.append((n, "completion"))

    violations = []
    for idx, (n, kind) in enumerate(landmarks):
        if kind != "completion":
            continue
        prev = landmarks[idx - 1][1] if idx > 0 else None
        if prev not in ("report", "guard"):
            violations.append(n + 1)

    # Also: at least one completion() must exist and at least one report call.
    reports = sum(1 for _, k in landmarks if k == "report")
    completions = sum(1 for _, k in landmarks if k == "completion")
    if completions == 0:
        violations.append("no completion() found in handler")
    if reports == 0:
        violations.append("no showCallkitIncoming report found in handler")

    if violations:
        print(f"FAIL: completion() reachable without CallKit report at lines {violations}")
        return 1
    print(f"OK: {completions} completion() site(s), {reports} report site(s) — all covered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
