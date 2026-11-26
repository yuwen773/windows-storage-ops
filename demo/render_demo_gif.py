"""Render demo/captured_session.json into a crisp animated terminal GIF (assets/demo.gif)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import List, Tuple

from PIL import Image, ImageDraw, ImageFont

REPO_ROOT = Path(__file__).resolve().parent.parent
INPUT_JSON = REPO_ROOT / "demo" / "captured_session.json"
OUTPUT_GIF = REPO_ROOT / "assets" / "demo.gif"

WIDTH, HEIGHT = 920, 560
BG_OUTER = (19, 22, 33)
BG_TERM = (26, 27, 38)
BG_TITLEBAR = (36, 40, 59)
BG_PILL_OFF = (41, 46, 66)
BG_PILL_ON = (122, 162, 247)
BORDER_COLOR = (65, 72, 104)

TEXT_DEFAULT = (192, 202, 245)
TEXT_MUTED = (120, 128, 165)
TEXT_CYAN = (125, 207, 255)
TEXT_GREEN = (158, 206, 106)
TEXT_YELLOW = (224, 175, 104)
TEXT_RED = (247, 118, 142)
TEXT_PURPLE = (187, 154, 247)
TEXT_DARK = (26, 27, 38)


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for candidate in (
        r"C:\Windows\Fonts\CascadiaMono.ttf",
        r"C:\Windows\Fonts\consola.ttf",
        r"C:\Windows\Fonts\lucon.ttf",
    ):
        p = Path(candidate)
        if p.exists():
            return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


FONT_TITLE = load_font(14)
FONT_PILL = load_font(13)
FONT_BODY = load_font(13)


def pick_color(line: str) -> Tuple[int, int, int]:
    u = line.upper()
    if any(k in u for k in ("BLOCKED", "FAILED", "ERROR", "EXIT=2", "LOCKER")):
        return TEXT_RED
    if any(k in u for k in ("[OK]", "[UNDO VERIFIED]", "ALL DONE", "HANDLE_LOCK: 0", "PROC_REFS  : 0", "ENV_REFS   : NONE")):
        return TEXT_GREEN
    if any(k in u for k in ("[DRY-RUN]", "WARNING", "COULD NOT", "ACL_LOCKED : TRUE")):
        return TEXT_YELLOW
    if line.startswith("===") or line.startswith("---") or line.startswith("[1/") or line.startswith("[2/") or line.startswith("[3/"):
        return TEXT_CYAN
    if "COUPLING" in u or "SUMMARY" in u or "ROLLBACK SCRIPT" in u:
        return TEXT_PURPLE
    if line.strip().startswith("Drive ") or line.strip().startswith("JSON Report") or line.strip().startswith("Full Log"):
        return TEXT_CYAN
    return TEXT_DEFAULT


def wrap_line(text: str, max_chars: int = 104) -> List[str]:
    if not text:
        return [""]
    out: List[str] = []
    cur = text
    while len(cur) > max_chars:
        out.append(cur[:max_chars])
        cur = "  " + cur[max_chars:]
    out.append(cur)
    return out


def prepare_display_lines(raw_lines: List[str], max_rows: int = 19) -> List[str]:
    filtered: List[str] = []
    for ln in raw_lines:
        s = ln.rstrip("\r\n")
        if s.strip() == "" and (not filtered or filtered[-1] == ""):
            continue
        # Skip verbose transcript path banner lines to keep frames crisp
        if "Transcript started" in s or "Transcript stopped" in s or "Windows PowerShell" in s:
            continue
        for wl in wrap_line(s):
            filtered.append(wl)
    if len(filtered) > max_rows:
        kept = filtered[: max_rows - 1]
        kept.append("  ... (verified output continues in %LOCALAPPDATA%\\windows-storage-ops\\logs)")
        return kept
    return filtered


def render_frame(
    pills: List[str],
    active_idx: int,
    scene_title: str,
    prompt_cmd: str,
    output_lines: List[str],
    exit_code: int | None = None,
    cursor: bool = False,
) -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT), BG_OUTER)
    draw = ImageDraw.Draw(img)

    # Terminal window card
    x0, y0, x1, y1 = 16, 14, WIDTH - 16, HEIGHT - 14
    draw.rounded_rectangle([x0, y0, x1, y1], radius=12, fill=BG_TERM, outline=BORDER_COLOR, width=2)

    # Title bar
    draw.rounded_rectangle([x0, y0, x1, y0 + 40], radius=12, fill=BG_TITLEBAR)
    draw.rectangle([x0, y0 + 26, x1, y0 + 40], fill=BG_TITLEBAR)
    # Window dots
    for i, col in enumerate([(247, 118, 142), (224, 175, 104), (158, 206, 106)]):
        cx = x0 + 22 + i * 20
        cy = y0 + 20
        draw.ellipse([cx - 6, cy - 6, cx + 6, cy + 6], fill=col)

    draw.text((x0 + 92, y0 + 11), "Windows Storage Master — Live Verified Replay", fill=TEXT_DEFAULT, font=FONT_TITLE)

    # Top stage pills bar
    py = y0 + 50
    px = x0 + 20
    for idx, label in enumerate(pills):
        is_active = idx == active_idx
        pw = 196
        fill = BG_PILL_ON if is_active else BG_PILL_OFF
        fg = TEXT_DARK if is_active else TEXT_MUTED
        draw.rounded_rectangle([px, py, px + pw, py + 28], radius=7, fill=fill)
        draw.text((px + 12, py + 6), label, fill=fg, font=FONT_PILL)
        px += pw + 12

    # Scene subtitle
    sy = py + 38
    draw.text((x0 + 22, sy), scene_title, fill=TEXT_MUTED, font=FONT_PILL)

    # Command prompt line
    cy = sy + 24
    prompt_prefix = "PS D:\\DemoWorkstation> "
    draw.text((x0 + 22, cy), prompt_prefix, fill=TEXT_PURPLE, font=FONT_BODY)
    cmd_x = x0 + 22 + len(prompt_prefix) * 8
    cmd_text = prompt_cmd + ("_" if cursor else "")
    for idx, part in enumerate(wrap_line(cmd_text, 82)):
        draw.text((cmd_x if idx == 0 else x0 + 42, cy + idx * 18), part, fill=TEXT_CYAN, font=FONT_BODY)

    cmd_rows = max(1, len(wrap_line(cmd_text, 82)))
    oy = cy + cmd_rows * 18 + 10

    # Output lines
    for ln in output_lines:
        if oy > y1 - 36:
            break
        draw.text((x0 + 22, oy), ln, fill=pick_color(ln), font=FONT_BODY)
        oy += 17

    # Footer exit badge
    if exit_code is not None:
        badge = f"ExitCode: {exit_code}  |  Zero private paths  |  Full log saved"
        bcol = TEXT_GREEN if exit_code == 0 else TEXT_RED
        draw.text((x0 + 22, y1 - 26), badge, fill=bcol, font=FONT_PILL)

    return img.convert("P", palette=Image.Palette.ADAPTIVE, colors=64)


def main() -> None:
    data = json.loads(INPUT_JSON.read_text(encoding="utf-8-sig"))
    scenes = data["scenes"]
    pills = [s["pill"] for s in scenes]

    frames: List[Image.Image] = []
    durations: List[int] = []

    for idx, sc in enumerate(scenes):
        cmd = sc["command"]
        title = sc["title"]
        lines = prepare_display_lines(sc["lines"])
        exit_code = int(sc["exitCode"])

        # Typing animation (chunks for compact GIF size)
        steps = [0.25, 0.55, 0.85, 1.0]
        for ratio in steps:
            n = max(1, int(len(cmd) * ratio))
            frames.append(render_frame(pills, idx, title, cmd[:n], [], None, cursor=True))
            durations.append(180 if ratio < 1.0 else 320)

        # Reveal output in 3 smooth waves
        total = len(lines)
        if total > 0:
            for cut in (max(1, total // 3), max(2, (total * 2) // 3)):
                frames.append(render_frame(pills, idx, title, cmd, lines[:cut], None, cursor=False))
                durations.append(350)

        # Final hold frame with exit code badge
        frames.append(render_frame(pills, idx, title, cmd, lines, exit_code, cursor=False))
        durations.append(2800 if idx < len(scenes) - 1 else 3600)

    OUTPUT_GIF.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        OUTPUT_GIF,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        optimize=True,
    )
    size_kb = OUTPUT_GIF.stat().st_size / 1024.0
    print(f"Generated {OUTPUT_GIF} ({len(frames)} frames, {size_kb:.1f} KB)")


if __name__ == "__main__":
    main()
