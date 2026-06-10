"""Render the Codex sidebar status icons (working / thinking / idle).

Ports the CodexRing math from the design preview (StatusIconsPreview.jsx):
an 8-bump gradient blob with a white `>` prompt and `_` cursor, stacked
above a state strip (typing lines / thinking dots / static lines) from
the card bottom-half — readability-tuned for ~28pt: two thicker lines
and bigger dots instead of the jsx's three thin lines. Three states map
onto Glint's PaneAgentStatus the same way the Claude mascot icons do:

  working   -> tool          (cursor blink, typing lines)
  thinking  -> thinking      (sway + breathe, bouncing dots)
  idle      -> idle / done   (static, cursor on, resting lines)

Output is APNG, not GIF: the strip animates through semi-transparent
alpha on a transparent canvas, which GIF's 1-bit transparency cannot
represent. The in-app decoder (GIFFrameCache) goes through ImageIO and
handles APNG natively.

Usage:
  python3 scripts/generate_codex_action_gifs.py            # apngs into design/codex-apng-actions
  python3 scripts/generate_codex_action_gifs.py --preview  # one contact-sheet png in /tmp
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "design" / "codex-apng-actions"
SIZE = 128
SCALE = 4
FPS_MS = 60
LOOP = 120  # frames per seamless loop, matches the jsx preview

# Official Codex gradient (top-left -> bottom-right).
GRAD_STOPS = [(0.0, (0xAC, 0xA0, 0xF6)), (0.55, (0x6C, 0x58, 0xEF)), (1.0, (0x4A, 0x38, 0xE2))]
WHITE = (255, 255, 255)


def grad_color(t: float) -> tuple[int, int, int]:
    t = min(1.0, max(0.0, t))
    for (t0, c0), (t1, c1) in zip(GRAD_STOPS, GRAD_STOPS[1:]):
        if t <= t1:
            k = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * k) for a, b in zip(c0, c1))
    return GRAD_STOPS[-1][1]


def blob_polygon(cx: float, cy: float, r: float, bumps: int, amp: float, pts: int = 192) -> list[tuple[float, float]]:
    out = []
    for k in range(pts):
        th = (k / pts) * math.tau
        rr = r * (1 + amp * math.cos(bumps * th))
        out.append((cx + math.cos(th) * rr, cy + math.sin(th) * rr))
    return out


def render_emblem(size: int, rotation_deg: float, scale: float, cursor_opacity: float) -> Image.Image:
    """One frame of the Codex emblem on a transparent canvas."""
    canvas = size * SCALE
    s = canvas  # shorthand matching the jsx `size`
    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    cx = cy = s / 2
    R = s * 0.37

    # Gradient fill masked by the blob: project each pixel onto the
    # (65%, 100%) gradient axis. Build a small gradient strip and resize —
    # exact per-pixel projection at 512px is needlessly slow in pure PIL.
    mask = Image.new("L", (canvas, canvas), 0)
    ImageDraw.Draw(mask).polygon(blob_polygon(cx, cy, R, 8, 0.075), fill=255)
    gvx, gvy = 0.65 * s, 1.0 * s
    glen2 = gvx * gvx + gvy * gvy
    grad = Image.new("RGBA", (canvas, canvas))
    gpx = grad.load()
    step = SCALE  # one gradient sample per output pixel is plenty
    for y in range(0, canvas, step):
        for x in range(0, canvas, step):
            t = (x * gvx + y * gvy) / glen2
            c = grad_color(t)
            for dy in range(step):
                for dx in range(step):
                    gpx[x + dx, y + dy] = (*c, 255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img, "RGBA")

    # Soft top highlight.
    hi = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    hx, hy = cx - R * 0.28, cy - R * 0.48
    ImageDraw.Draw(hi).ellipse(
        (hx - R * 0.5, hy - R * 0.26, hx + R * 0.5, hy + R * 0.26),
        fill=(255, 255, 255, round(0.16 * 255)),
    )
    img = Image.alpha_composite(img, Image.composite(hi, Image.new("RGBA", hi.size, (0, 0, 0, 0)), mask))
    d = ImageDraw.Draw(img, "RGBA")

    # `>` prompt — stroked polyline with round caps.
    x0, x1 = s * 0.345, s * 0.475
    yt, ym, yb = s * 0.4, s * 0.5, s * 0.6
    w = s * 0.072
    d.line([(x0, yt), (x1, ym), (x0, yb)], fill=WHITE, width=round(w), joint="curve")
    for px, py in ((x0, yt), (x1, ym), (x0, yb)):
        d.ellipse((px - w / 2, py - w / 2, px + w / 2, py + w / 2), fill=WHITE)

    # `_` cursor.
    if cursor_opacity > 0.01:
        cur = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        ImageDraw.Draw(cur).rounded_rectangle(
            (s * 0.535, s * 0.578, s * 0.535 + s * 0.14, s * 0.578 + s * 0.055),
            radius=s * 0.027,
            fill=(*WHITE, round(255 * cursor_opacity)),
        )
        img = Image.alpha_composite(img, cur)

    if abs(rotation_deg) > 0.01:
        img = img.rotate(-rotation_deg, resample=Image.BICUBIC, center=(cx, cy))
    if abs(scale - 1) > 0.001:
        sz = round(canvas * scale)
        scaled = img.resize((sz, sz), Image.LANCZOS)
        img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        img.paste(scaled, (round((canvas - sz) / 2), round((canvas - sz) / 2)), scaled)
    return img.resize((size, size), Image.LANCZOS)


# ---- stacked variant: emblem on top, jsx card bottom-half below ----
# Readability variant for ~28pt: 2 thicker lines / bigger dots, not the
# jsx's faithful 3-line proportions (those blur out below ~32pt).

LINE_COLORS = [(0xC2, 0xC0, 0xB6), (0x8A, 0x84, 0x78)]
CURSOR_PURPLE = (0x8B, 0x7B, 0xF2)
THINK_PURPLE = (0xA9, 0x9B, 0xD9)
LINE_STARTS = [10, 50]
LINE_DURS = [30, 28]


def ease_out_quad(t: float) -> float:
    return 1 - (1 - t) * (1 - t)


def clamp01(v: float) -> float:
    return min(1.0, max(0.0, v))


def render_block(size: int, state: str, f: int) -> Image.Image:
    """The icon's bottom strip (typing lines / dots / static lines) on a
    full-canvas transparent layer, supersampled like the emblem."""
    c = size * SCALE
    img = Image.new("RGBA", (c, c), (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")

    line_h = 0.085 * c
    gap = 0.07 * c
    widths = [0.46 * c, 0.30 * c]
    indents = [0.0, 0.08 * c]
    x0 = 0.23 * c
    y0 = 0.72 * c

    def line_y(i: int) -> float:
        return y0 + i * (line_h + gap)

    if state == "working":
        fade = clamp01((f - 106) / 12) ** 2
        for i in range(2):
            p = ease_out_quad(clamp01((f - LINE_STARTS[i]) / LINE_DURS[i]))
            if p <= 0:
                continue
            a = round((0.4 + 0.6 * p) * (1 - fade) * 255)
            d.rounded_rectangle(
                (x0 + indents[i], line_y(i), x0 + indents[i] + widths[i] * p, line_y(i) + line_h),
                radius=line_h / 2, fill=(*LINE_COLORS[i], a))
        active = next((i for i in range(2)
                       if LINE_STARTS[i] <= f < LINE_STARTS[i] + LINE_DURS[i] + 18), 1)
        if (f // 15) % 2 == 0 and fade < 1:
            ap = clamp01((f - LINE_STARTS[active]) / LINE_DURS[active])
            cx = x0 + indents[active] + widths[active] * ap + 0.02 * c
            d.rounded_rectangle(
                (cx, line_y(active), cx + 0.085 * c, line_y(active) + line_h),
                radius=line_h / 2, fill=(*CURSOR_PURPLE, round(255 * (1 - fade))))
    elif state == "thinking":
        dot = 0.12 * c
        pitch = 0.17 * c
        total = dot + 2 * pitch
        bx = (c - total) / 2
        base = y0 + 0.07 * c
        for i in range(3):
            ph = math.sin((f / LOOP) * math.pi * 4 - i * 0.9)
            lift = max(0.0, ph) * 0.07 * c
            a = round((0.45 + max(0.0, ph) * 0.55) * 255)
            x = bx + i * pitch
            d.ellipse((x, base - lift, x + dot, base - lift + dot), fill=(*THINK_PURPLE, a))
    else:  # idle / done: plain static lines
        for i, a in enumerate((0.95, 0.7)):
            d.rounded_rectangle(
                (x0 + indents[i], line_y(i), x0 + indents[i] + widths[i], line_y(i) + line_h),
                radius=line_h / 2, fill=(*LINE_COLORS[i], round(a * 255)))

    return img.resize((size, size), Image.LANCZOS)


def render_stacked(size: int, state: str, f: int) -> Image.Image:
    """Emblem (top 62%) + bottom state strip, one square icon frame."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    em_size = round(size * 0.62)
    em_state = "idle" if state in ("idle", "done") else state
    em = render_emblem(em_size, *frame_params(em_state, f))
    img.alpha_composite(em, ((size - em_size) // 2, 0))
    img.alpha_composite(render_block(size, state, f))
    return img


def frame_params(state: str, f: int) -> tuple[float, float, float]:
    """(rotation, scale, cursor_opacity) for frame f — same math as the jsx."""
    t = (f % LOOP) / LOOP
    if state == "working":
        breathe = math.sin(t * math.pi * 4)
        cursor = 1.0 if (f % LOOP) // 15 % 2 == 0 else 0.15
        return 0.0, 1 + breathe * 0.025, cursor
    if state == "thinking":
        rotation = math.sin(t * math.tau) * 6
        b = math.sin(t * math.pi * 4)
        cursor = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * math.pi * 4))
        return rotation, 1 + b * 0.05, cursor
    return 0.0, 1.0, 1.0  # idle / done


def write_apng(state: str, path: Path, stacked: bool = False) -> None:
    """APNG keeps 8-bit alpha — fading/semi-transparent elements over a
    transparent canvas, which GIF's 1-bit transparency cannot hold."""
    n_frames = 1 if state == "idle" else LOOP
    if stacked:
        frames = [render_stacked(SIZE, state, f) for f in range(n_frames)]
    else:
        frames = [render_emblem(SIZE, *frame_params(state, f)) for f in range(n_frames)]
    frames[0].save(
        path,
        save_all=True,
        append_images=frames[1:],
        duration=FPS_MS,
        loop=0,
        disposal=1,  # OP_BACKGROUND: clear before each full-canvas frame
        blend=0,     # OP_SOURCE: frame replaces, no compositing
    )
    print(f"wrote {path} ({n_frames} frames)")


def write_preview(path: Path) -> None:
    """Contact sheet: key frames per state, plus actual sidebar size."""
    big, small, pad = 112, 28, 18
    rows = [
        ("working", [0, 15, 30, 45]),       # blink phases + breathe extremes
        ("thinking", [0, 15, 30, 45, 60]),  # sway left/right + cursor fade
        ("idle-done", [0]),
    ]
    cols = max(len(fr) for _, fr in rows) + 1  # +1 for the small version
    W = pad + cols * (big + pad)
    H = pad + len(rows) * (big + pad + 22)
    sheet = Image.new("RGBA", (W, H), (0x16, 0x14, 0x11, 255))
    d = ImageDraw.Draw(sheet)
    for row, (state, frames) in enumerate(rows):
        y = pad + row * (big + pad + 22)
        key = "idle" if state == "idle-done" else state
        stacked = "--stacked" in sys.argv

        def render(sz: int, f: int) -> Image.Image:
            return render_stacked(sz, key, f) if stacked \
                else render_emblem(sz, *frame_params(key, f))

        for col, f in enumerate(frames):
            x = pad + col * (big + pad)
            sheet.alpha_composite(render(big, f), (x, y))
            d.text((x, y + big + 4), f"{state} f{f}", fill=(0x8A, 0x84, 0x78, 255))
        # rightmost: the 28pt sidebar size on a card-ish backdrop
        x = pad + (cols - 1) * (big + pad)
        d.rounded_rectangle((x, y, x + big, y + big), radius=16, fill=(0x21, 0x1F, 0x1C, 255))
        sheet.alpha_composite(
            render(small, frames[0]),
            (x + (big - small) // 2, y + (big - small) // 2),
        )
        d.text((x, y + big + 4), "28pt", fill=(0x8A, 0x84, 0x78, 255))
    sheet.save(path)
    print(f"wrote {path}")


if __name__ == "__main__":
    if "--preview" in sys.argv:
        write_preview(Path("/tmp/codex-icons-preview.png"))
    else:
        OUT.mkdir(parents=True, exist_ok=True)
        # Shipped icons are emblem-only; agent state lives in the card's
        # traffic-light badge. `--stacked` keeps the emblem+strip variant
        # around for design exploration.
        stacked = "--stacked" in sys.argv
        suffix = "-stacked" if stacked else ""
        for state, name in (("working", f"codex-working{suffix}.png"),
                            ("thinking", f"codex-thinking{suffix}.png"),
                            ("idle", f"codex-idle{suffix}.png")):
            write_apng(state, OUT / name, stacked=stacked)
