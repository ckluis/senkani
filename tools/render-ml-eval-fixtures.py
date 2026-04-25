#!/usr/bin/env python3
"""Render the 10 vision fixtures referenced by MLTierEvalTasks.visionTasks().

Output: Sources/Bench/Resources/MLEvalImages/<imageRef>.png

Each PNG is a small (≤200 KB), text-based scene that unambiguously matches
its descriptor in MLTierEvalTasks.swift. The vision-eval harness loads
these via Bundle.module on a real machine with a Gemma VLM tier installed.

Re-run this script if the descriptor list in MLTierEvalTasks.visionTasks()
changes; the image set is meant to be regenerated from source, not edited
in place.
"""

from __future__ import annotations

import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT_DIR = Path(__file__).resolve().parent.parent / "Sources/Bench/Resources/MLEvalImages"


def font(size: int) -> ImageFont.ImageFont:
    # PIL default bitmap font is portable across machines and tiny on disk.
    return ImageFont.load_default(size=size)


def new_canvas(w: int = 480, h: int = 320, bg: str = "#101418") -> Image.Image:
    return Image.new("RGB", (w, h), bg)


def save(img: Image.Image, name: str) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{name}.png"
    img.save(path, format="PNG", optimize=True)
    size = path.stat().st_size
    if size > 200_000:
        raise SystemExit(f"{name}.png is {size} bytes (>200 KB cap)")
    print(f"  {name}.png  {size:>6} bytes")


def draw_lines(img: Image.Image, lines: list[tuple[str, str, int]], x: int = 16, y: int = 16, line_h: int = 18) -> None:
    d = ImageDraw.Draw(img)
    for i, (text, color, size) in enumerate(lines):
        d.text((x, y + i * line_h), text, fill=color, font=font(size))


# ---- 10 fixtures ------------------------------------------------------------

def vision_terminal_error() -> Image.Image:
    img = new_canvas()
    draw_lines(img, [
        ("$ swift build", "#9aa0a6", 14),
        ("error: no such file or directory: 'Sources/Foo.swift'", "#ff5c57", 14),
        ("compilation failed", "#ff5c57", 14),
        ("exit code: 1", "#9aa0a6", 14),
    ])
    return img


def vision_diff_summary() -> Image.Image:
    img = new_canvas()
    draw_lines(img, [
        ("--- a/Sources/Greeter.swift", "#9aa0a6", 12),
        ("+++ b/Sources/Greeter.swift", "#9aa0a6", 12),
        ("@@ -1,4 +1,5 @@", "#5fa8d3", 12),
        (" func greet(name: String) {", "#d0d0d0", 12),
        ("-    print(\"hi\")", "#ff5c57", 12),
        ("+    print(\"hello, \\(name)\")", "#a8e10c", 12),
        ("+    log(name)", "#a8e10c", 12),
        (" }", "#d0d0d0", 12),
    ])
    return img


def vision_swift_signature() -> Image.Image:
    img = new_canvas()
    draw_lines(img, [
        ("// Sources/Core/Filter.swift", "#9aa0a6", 12),
        ("public func filter(", "#5fa8d3", 14),
        ("    input: String,", "#d0d0d0", 14),
        ("    rules: [Rule]", "#d0d0d0", 14),
        (") async throws -> FilterResult {", "#5fa8d3", 14),
        ("    // ...", "#9aa0a6", 12),
        ("}", "#5fa8d3", 14),
    ])
    return img


def vision_chart_axes() -> Image.Image:
    img = new_canvas()
    d = ImageDraw.Draw(img)
    # Axes
    d.line([(60, 40), (60, 260)], fill="#d0d0d0", width=2)   # Y axis
    d.line([(60, 260), (440, 260)], fill="#d0d0d0", width=2) # X axis
    # Ticks
    for i in range(5):
        x = 60 + i * 80
        d.line([(x, 258), (x, 264)], fill="#d0d0d0")
        d.text((x - 6, 268), str(i), fill="#d0d0d0", font=font(12))
        y = 260 - i * 50
        d.line([(56, y), (62, y)], fill="#d0d0d0")
        d.text((36, y - 7), str(i * 25), fill="#d0d0d0", font=font(12))
    # Labels
    d.text((220, 290), "X: time (s)", fill="#5fa8d3", font=font(14))
    d.text((10, 10), "Y: tokens", fill="#5fa8d3", font=font(14))
    # Sample line
    pts = [(60 + i * 80, 260 - (i * 35 + 10)) for i in range(5)]
    d.line(pts, fill="#a8e10c", width=2)
    return img


def vision_test_fail() -> Image.Image:
    img = new_canvas()
    draw_lines(img, [
        ("Test Suite 'GreeterTests' failed", "#ff5c57", 13),
        ("  testGreetReturnsHello (GreeterTests)", "#ff5c57", 13),
        ("    XCTAssertEqual failed:", "#ff5c57", 12),
        ("      expected: \"hello, world\"", "#d0d0d0", 12),
        ("      got:      \"hi\"", "#d0d0d0", 12),
        ("Executed 1 test, with 1 failure", "#ff5c57", 13),
    ])
    return img


def vision_warn_count() -> Image.Image:
    img = new_canvas()
    draw_lines(img, [
        ("$ swift build 2>&1 | tee build.log", "#9aa0a6", 12),
        ("warning: unused variable 'x'", "#f0a500", 12),
        ("warning: deprecated API: foo()", "#f0a500", 12),
        ("warning: cast always succeeds", "#f0a500", 12),
        ("Build complete! 0 errors, 3 warnings", "#a8e10c", 13),
    ])
    return img


def vision_ui_button() -> Image.Image:
    img = new_canvas(bg="#1c1f24")
    d = ImageDraw.Draw(img)
    # Card
    d.rectangle([(60, 60), (420, 240)], outline="#3a3f47", width=2, fill="#22262d")
    d.text((80, 80), "Sign in to Senkani", fill="#d0d0d0", font=font(16))
    d.text((80, 110), "email@example.com", fill="#9aa0a6", font=font(13))
    d.line([(80, 132), (400, 132)], fill="#3a3f47", width=1)
    # Primary button
    d.rectangle([(80, 170), (240, 210)], fill="#5fa8d3", outline="#5fa8d3")
    d.text((128, 182), "Submit", fill="#0b0d10", font=font(14))
    # Secondary button
    d.rectangle([(260, 170), (400, 210)], outline="#3a3f47", fill="#22262d", width=2)
    d.text((310, 182), "Cancel", fill="#9aa0a6", font=font(14))
    return img


def vision_panes_count() -> Image.Image:
    img = new_canvas(w=520, h=320, bg="#0e1014")
    d = ImageDraw.Draw(img)
    # 4 panes in a 2x2 grid — labelled so the descriptor is unambiguous.
    panes = [
        (10, 10, 250, 150, "pane 1: $ swift build"),
        (260, 10, 510, 150, "pane 2: $ swift test"),
        (10, 160, 250, 310, "pane 3: $ git status"),
        (260, 160, 510, 310, "pane 4: $ tail -f log"),
    ]
    for x0, y0, x1, y1, label in panes:
        d.rectangle([(x0, y0), (x1, y1)], outline="#3a3f47", fill="#16191f", width=2)
        d.text((x0 + 8, y0 + 8), label, fill="#a8e10c", font=font(12))
    return img


def vision_stack_trace() -> Image.Image:
    img = new_canvas()
    draw_lines(img, [
        ("Crash report — Senkani v0.2.0", "#ff5c57", 13),
        ("Thread 0 crashed:", "#ff5c57", 12),
        ("0  Senkani  0x100abcd  Greeter.greet(name:)  +24", "#d0d0d0", 11),
        ("1  Senkani  0x100abef  AppDelegate.run()     +88", "#d0d0d0", 11),
        ("2  Senkani  0x100ac01  main                  +12", "#d0d0d0", 11),
        ("3  dyld     0x180abcd  start                 +520", "#d0d0d0", 11),
        ("Termination reason: SIGABRT", "#ff5c57", 12),
    ])
    return img


def vision_progress_bar() -> Image.Image:
    img = new_canvas(w=520, h=200)
    d = ImageDraw.Draw(img)
    d.text((20, 30), "Downloading gemma-4-e4b.gguf...", fill="#d0d0d0", font=font(14))
    # Bar frame
    d.rectangle([(20, 80), (500, 120)], outline="#3a3f47", width=2, fill="#16191f")
    # Fill — 65%
    fill_x = 20 + int((500 - 20) * 0.65)
    d.rectangle([(22, 82), (fill_x, 118)], fill="#5fa8d3")
    d.text((230, 132), "65 %", fill="#a8e10c", font=font(16))
    d.text((20, 160), "312 MB / 480 MB", fill="#9aa0a6", font=font(12))
    return img


FIXTURES = [
    ("vision_terminal_error", vision_terminal_error),
    ("vision_diff_summary", vision_diff_summary),
    ("vision_swift_signature", vision_swift_signature),
    ("vision_chart_axes", vision_chart_axes),
    ("vision_test_fail", vision_test_fail),
    ("vision_warn_count", vision_warn_count),
    ("vision_ui_button", vision_ui_button),
    ("vision_panes_count", vision_panes_count),
    ("vision_stack_trace", vision_stack_trace),
    ("vision_progress_bar", vision_progress_bar),
]


def main() -> None:
    print(f"Rendering {len(FIXTURES)} ML-eval vision fixtures →")
    print(f"  {OUT_DIR}")
    for name, fn in FIXTURES:
        save(fn(), name)
    print(f"done. {len(FIXTURES)} PNGs in {OUT_DIR}")


if __name__ == "__main__":
    main()
