"""Claude "spark" status icon family — faithful port of StatusIconsPreview.jsx.

Generates, into design/claude-spark-v2/:
  • static marks:       claude-spark-{24,48,128}.png  (crisp, no glow)
  • GIF animations:     claude-spark-<state>.gif      (1-bit alpha → glow OFF,
                        hard alpha threshold like generate_claude_action_gifs.py)
  • APNG animations:    apng/claude-spark-<state>.png (real alpha, glow ON —
                        what the app should ship; AnimatedGIFView already
                        decodes APNG, same as the Codex icons)
  • preview.html        dark-background contact page for review

States map the JSX's three modes onto Glint's six datasets:
  idle        gentle breathe (no rotation)
  thinking    JSX thinking: ±10° pendulum, ±9% scale, per-ray shimmer, purple
  tool-call   brisk seamless rotation (1 rev / 1.5s), no burst
  working     JSX working: 1 rev / 4s + breathe + mid-loop particle burst
  compressing rays squeeze toward the core twice per loop (suck-in)
  complete    JSX done: inertia brake + pop + celebrate particles + green ✓ badge

Geometry is the JSX's, verbatim: 12 hand-tuned rays (angle, length), tapered
quads with a quadratic-bezier tip cap, core dot. Rotation/scale are applied to
the geometry (not via image rotation) so edges stay crisp at 4× supersampling.
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "design" / "claude-spark-v2"
APNG_OUT = OUT / "apng"

SIZE = 128
SS = 4  # supersample factor
FPS_MS = 33  # 30fps, same as the JSX
LOOP = 120
DONE_DUR = 90

# Colors from the JSX, not the old mascot palette.
CLAUDE = (215, 123, 96)        # #D77B60
THINK = (169, 155, 217)        # #A99BD9
DONE_GREEN = (156, 185, 126)   # #9CB97E
BADGE_INK = (23, 21, 18)       # #171512
GLOW_ALPHA = 0.35

# (angle°, length) — "参考图逐像素重建" ray table from the JSX.
RAYS = [
    (17, 0.91), (40, 0.87), (59, 0.90), (95, 0.95),
    (120, 0.90), (142, 0.89), (174, 0.89), (213, 0.93),
    (239, 1.00), (279, 0.84), (310, 0.87), (354, 0.83),
]


def clamp(v: float, a: float, b: float) -> float:
    return min(b, max(a, v))


def lerp_f(frame: float, f0: float, f1: float, v0: float, v1: float, ease=None) -> float:
    t = clamp((frame - f0) / (f1 - f0), 0.0, 1.0)
    if ease:
        t = ease(t)
    return v0 + (v1 - v0) * t


def ease_out_quad(t: float) -> float:
    return 1 - (1 - t) * (1 - t)


def ease_in_quad(t: float) -> float:
    return t * t


def ease_out_back(t: float) -> float:
    c = 1.70158
    return 1 + (c + 1) * (t - 1) ** 3 + c * (t - 1) ** 2


def quad_bezier(p0, p1, p2, steps: int = 10) -> list[tuple[float, float]]:
    pts = []
    for k in range(1, steps + 1):
        t = k / steps
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
    return pts


def ray_polygon(cx, cy, angle_deg, r0, r1, wb, wt) -> list[tuple[float, float]]:
    """JSX rayPath: tapered quad bottom→tip with a rounded bezier cap."""
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    px, py = -dy, dx
    bl = (cx + dx * r0 + px * wb, cy + dy * r0 + py * wb)
    tl = (cx + dx * r1 + px * wt, cy + dy * r1 + py * wt)
    tr = (cx + dx * r1 - px * wt, cy + dy * r1 - py * wt)
    br = (cx + dx * r0 - px * wb, cy + dy * r0 - py * wb)
    cap = (cx + dx * (r1 + wt * 1.4), cy + dy * (r1 + wt * 1.4))
    return [bl, tl, *quad_bezier(tl, cap, tr), br]


def transform(pts, cx, cy, rot_deg: float, scale: float):
    """Rotate+scale around center — geometry-space, keeps edges crisp."""
    a = math.radians(rot_deg)
    ca, sa = math.cos(a), math.sin(a)
    out = []
    for x, y in pts:
        x, y = (x - cx) * scale, (y - cy) * scale
        out.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    return out


def spark_layer(
    *,
    color: tuple[int, int, int],
    rotation: float = 0.0,
    scale: float = 1.0,
    burst: float = 0.0,
    squeeze: float = 0.0,
    shimmer_t: float | None = None,
    particles: list[tuple[float, float, float, float]] | None = None,
    glow_opacity: float = 0.0,
    with_glow: bool = True,
) -> Image.Image:
    """One frame of the spark on a transparent SS-supersampled canvas.

    particles: list of (angle°, radius_px, size_px, opacity) in unscaled space.
    squeeze: 0..1 pulls ray tips toward the core (compressing).
    """
    c = SIZE * SS
    cx = cy = c / 2
    R = c * 0.40          # slightly under the JSX's 0.46 so thinking's ×1.09
    core = R * 0.19       # breathe never clips the 128px canvas
    wb = R * 0.10
    wt = R * 0.072

    img = Image.new("RGBA", (c, c), (0, 0, 0, 0))

    if with_glow and glow_opacity > 0.01:
        glow = Image.new("RGBA", (c, c), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        gr = c * 0.36 * scale
        ga = int(255 * GLOW_ALPHA * clamp(glow_opacity, 0, 1))
        gd.ellipse((cx - gr, cy - gr, cx + gr, cy + gr), fill=(*color, ga))
        glow = glow.filter(ImageFilter.GaussianBlur(c * 0.10))
        img.alpha_composite(glow)

    d = ImageDraw.Draw(img, "RGBA")

    for i, (ang, length) in enumerate(RAYS):
        r1 = core + (R * length - wt - core) * (1 - burst)
        r1 -= (r1 - core) * 0.35 * squeeze
        opacity = 1 - burst
        if shimmer_t is not None:
            a_rad = math.radians(ang)
            opacity = 0.5 + 0.5 * (0.5 + 0.5 * math.sin(shimmer_t * math.tau - a_rad))
        if opacity <= 0.01:
            continue
        poly = ray_polygon(cx, cy, ang, core * 0.4, r1,
                           wb * (1 - burst * 0.5), wt * (1 - burst))
        poly = transform(poly, cx, cy, rotation, scale)
        d.polygon(poly, fill=(*color, int(255 * opacity)))

    if particles:
        for ang, pr, ps, op in particles:
            if op <= 0.01:
                continue
            a = math.radians(ang)
            px = cx + math.cos(a) * pr * SS
            py = cy + math.sin(a) * pr * SS
            pt = transform([(px, py)], cx, cy, rotation, scale)[0]
            r = ps * SS * scale
            d.ellipse((pt[0] - r, pt[1] - r, pt[0] + r, pt[1] + r),
                      fill=(*color, int(255 * clamp(op, 0, 1))))

    core_r = core * (1 - burst * 0.96) * scale
    d.ellipse((cx - core_r, cy - core_r, cx + core_r, cy + core_r), fill=(*color, 255))
    return img


def done_badge(img: Image.Image, frame: float) -> None:
    """Green ✓ badge at 80%,80% — JSX DoneBadge (pop + check draw-in)."""
    pop = lerp_f(frame, 26, 44, 0, 1, ease_out_back)
    check = lerp_f(frame, 38, 56, 0, 1, ease_out_quad)
    if pop <= 0:
        return
    c = img.width
    bx, by = c * 0.78, c * 0.78
    br = c * 0.145 * pop
    d = ImageDraw.Draw(img, "RGBA")
    d.ellipse((bx - br, by - br, bx + br, by + br),
              fill=(*DONE_GREEN, 255), outline=(*BADGE_INK, 255),
              width=max(1, int(c * 0.022)))
    if check > 0.01:
        rr = c * 0.145 * pop
        p1 = (bx - rr * 0.45, by + rr * 0.02)
        p2 = (bx - rr * 0.10, by + rr * 0.38)
        p3 = (bx + rr * 0.48, by - rr * 0.32)
        seg1 = math.dist(p1, p2)
        seg2 = math.dist(p2, p3)
        total = (seg1 + seg2) * check
        w = max(1, int(c * 0.038))
        if total <= seg1:
            t = total / seg1
            end = (p1[0] + (p2[0] - p1[0]) * t, p1[1] + (p2[1] - p1[1]) * t)
            d.line([p1, end], fill=(*BADGE_INK, 255), width=w, joint="curve")
        else:
            t = (total - seg1) / seg2
            end = (p2[0] + (p3[0] - p2[0]) * t, p2[1] + (p3[1] - p2[1]) * t)
            d.line([p1, p2, end], fill=(*BADGE_INK, 255), width=w, joint="curve")


def downsample(img: Image.Image) -> Image.Image:
    return img.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


# ---------------------------------------------------------------- states

def frame_idle(i: int, n: int, with_glow: bool) -> Image.Image:
    t = i / n
    b = math.sin(t * math.tau)  # one full cycle → seamless
    return downsample(spark_layer(
        color=CLAUDE, scale=1 + b * 0.02,
        glow_opacity=0.45 + b * 0.20, with_glow=with_glow))


def frame_thinking(i: int, n: int, with_glow: bool) -> Image.Image:
    t = i / n
    b = math.sin(t * math.tau * 2)
    return downsample(spark_layer(
        color=THINK,
        rotation=math.sin(t * math.tau) * 10,
        scale=1 + b * 0.09,
        shimmer_t=t,
        glow_opacity=0.5 + b * 0.35,
        with_glow=with_glow))


def frame_tool(i: int, n: int, with_glow: bool) -> Image.Image:
    t = i / n
    b = math.sin(t * math.tau * 2)
    return downsample(spark_layer(
        color=CLAUDE,
        rotation=t * 360,           # integer revolution → seamless
        scale=1 + b * 0.03,
        glow_opacity=0.55 + b * 0.20,
        with_glow=with_glow))


def frame_working(i: int, n: int, with_glow: bool) -> Image.Image:
    f = i * (LOOP / n)
    t = f / LOOP
    breathe = math.sin(t * math.tau * 2)
    burst = (lerp_f(f, 60, 76, 0, 1, ease_out_quad)
             * (1 - lerp_f(f, 96, 114, 0, 1, ease_in_quad)))
    drift = (lerp_f(f, 60, 88, 0, 1, ease_out_quad)
             * (1 - lerp_f(f, 88, 114, 0, 1, ease_in_quad)))
    glow_op = (0.55 + breathe * 0.25) * (1 - burst) + 0.45 * burst
    particles = []
    if burst > 0.01:
        R_px = SIZE * 0.40
        wt_px = R_px * 0.072
        for k, (ang, length) in enumerate(RAYS):
            jitter = (((k * 5) % 12) - 5.5) * 1.4
            brightness = 0.55 + 0.45 * (((k * 7) % 12) / 11)
            pr = R_px * length * (0.45 + 0.4 * drift)
            ps = wt_px * 1.45 * (0.7 + 0.3 * brightness)
            particles.append((ang + jitter, pr, ps, burst * brightness))
    return downsample(spark_layer(
        color=CLAUDE,
        rotation=t * 360,
        scale=1 + breathe * 0.04,
        burst=burst,
        particles=particles,
        glow_opacity=glow_op,
        with_glow=with_glow))


def frame_compressing(i: int, n: int, with_glow: bool) -> Image.Image:
    t = i / n
    pulse = 0.5 - 0.5 * math.cos(t * math.tau * 2)  # two squeezes per loop
    return downsample(spark_layer(
        color=CLAUDE,
        rotation=math.sin(t * math.tau) * 4,
        scale=1 - pulse * 0.04,
        squeeze=pulse,
        glow_opacity=0.55 - pulse * 0.30,
        with_glow=with_glow))


def frame_complete(i: int, n: int, with_glow: bool) -> Image.Image:
    f = min(i, DONE_DUR)
    rotation = lerp_f(f, 0, 20, 42, 0, ease_out_quad)
    scale = lerp_f(f, 6, 28, 0.93, 1, ease_out_back)
    celebrate = lerp_f(f, 14, 44, 0, 1, ease_out_quad)
    glow_op = (lerp_f(f, 14, 26, 0, 0.8, ease_out_quad)
               * lerp_f(f, 30, 72, 1, 0.4, ease_in_quad))
    particles = []
    if 0.02 < celebrate < 0.98:
        R_px = SIZE * 0.40
        wt_px = R_px * 0.072
        for k, (ang, length) in enumerate(RAYS):
            jitter = (((k * 5) % 12) - 5.5) * 1.4
            brightness = 0.55 + 0.45 * (((k * 7) % 12) / 11)
            pr = R_px * length * (0.95 + 0.55 * celebrate)
            ps = wt_px * 1.45 * (0.7 + 0.3 * brightness) * (1 - celebrate * 0.5)
            particles.append((ang + jitter, pr, ps, (1 - celebrate) * 0.9 * brightness))
    img = spark_layer(
        color=CLAUDE, rotation=rotation, scale=scale,
        particles=particles, glow_opacity=glow_op, with_glow=with_glow)
    done_badge(img, f)
    return downsample(img)


# ---------------------------------------------------------------- export

# The app surfaces these icons sit on are all dark warm/indigo; flattening
# semi-alpha against this matte (instead of the canvas's transparent BLACK)
# is what kills the dirty dark fringes the previous spark GIFs had.
GIF_MATTE = (20, 18, 26)


def gif_safe(frame: Image.Image) -> Image.Image:
    """GIF transparency is 1-bit, so partial alpha must be resolved here:
    blend every covered pixel onto the dark app matte, then hard-cut the
    alpha. Shimmer/particle pixels keep their intended brightness against
    the matte; fully-outside pixels stay transparent."""
    frame = frame.convert("RGBA")
    px = frame.load()
    w, h = frame.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 16:
                px[x, y] = (0, 0, 0, 0)
            else:
                t = a / 255
                px[x, y] = (
                    int(r * t + GIF_MATTE[0] * (1 - t)),
                    int(g * t + GIF_MATTE[1] * (1 - t)),
                    int(b * t + GIF_MATTE[2] * (1 - t)),
                    255,
                )
    return frame


def save_gif(path: Path, frames: list[Image.Image], hold_last: int = 0) -> None:
    frames = [gif_safe(f) for f in frames]
    if hold_last:
        frames += [frames[-1]] * hold_last
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=FPS_MS, loop=0, disposal=2, transparency=0,
                   optimize=False)


def save_apng(path: Path, frames: list[Image.Image], hold_last: int = 0) -> None:
    durations = [FPS_MS] * len(frames)
    if hold_last:
        durations[-1] = FPS_MS * hold_last
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=durations, loop=0, format="PNG")


STATES = {
    # name: (frame_fn, frame_count, hold_last)
    "idle": (frame_idle, 90, 0),
    "thinking": (frame_thinking, LOOP, 0),
    "tool-call": (frame_tool, 45, 0),
    "working": (frame_working, LOOP, 0),
    "compressing": (frame_compressing, 90, 0),
    "complete": (frame_complete, DONE_DUR, 30),
}

# What actually ships in Assets.xcassets. The sidebar maps justCompleted/
# needsPermission/failed onto idle for this family (the traffic-light dot
# carries those), so no Complete dataset. The Thinking slot ships the
# WORKING animation, not the purple pendulum: every other state is Claude
# orange, and flipping to purple and back on each thought read as jarring.
ASSET_ROOT = ROOT / "Glint" / "Resources" / "Assets.xcassets"
APP_SIZE = 96          # icons render at ≤40pt (80px @2x); 96 keeps headroom
APP_STATES = {
    "idle": ("ClaudeSparkIdle", 2),          # name, frame step (2 → 15fps)
    "working": ("ClaudeSparkThinking", 2),
    "tool-call": ("ClaudeSparkToolCall", 1), # rotation chops at 15fps
    "compressing": ("ClaudeSparkCompressing", 2),
}


def install_app_assets() -> None:
    """Write APNG datasets + the static mark imageset into Assets.xcassets.
    Pure catalog additions — no pbxproj surgery needed."""
    for state, (asset, step) in APP_STATES.items():
        fn, count, _ = STATES[state]
        frames = [fn(i, count, True).resize((APP_SIZE, APP_SIZE), Image.Resampling.LANCZOS)
                  for i in range(0, count, step)]
        ds = ASSET_ROOT / f"{asset}.dataset"
        ds.mkdir(exist_ok=True)
        fname = f"claude-spark-{state}.png"
        frames[0].save(ds / fname, save_all=True, append_images=frames[1:],
                       duration=FPS_MS * step, loop=0, format="PNG")
        (ds / "Contents.json").write_text(
            '{\n  "data" : [\n    { "filename" : "%s", "idiom" : "universal" }\n  ],\n'
            '  "info" : { "author" : "xcode", "version" : 1 }\n}\n' % fname)

    iset = ASSET_ROOT / "ClaudeSpark.imageset"
    iset.mkdir(exist_ok=True)
    static_mark(128).save(iset / "claude-spark.png")
    (iset / "Contents.json").write_text(
        '{\n  "images" : [\n    { "filename" : "claude-spark.png", "idiom" : "universal" }\n  ],\n'
        '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')


def static_mark(size: int) -> Image.Image:
    img = spark_layer(color=CLAUDE, glow_opacity=0, with_glow=False)
    return img.resize((size, size), Image.Resampling.LANCZOS)


def contact_sheet(rows: list[tuple[str, list[Image.Image]]], path: Path) -> None:
    """name + 5 key frames per row, on the app's dark background."""
    pad, cell = 10, SIZE
    w = pad + 5 * (cell + pad)
    h = pad + len(rows) * (cell + pad)
    sheet = Image.new("RGB", (w, h), (23, 21, 18))
    for r, (_, frames) in enumerate(rows):
        idx = [0, len(frames) // 4, len(frames) // 2, 3 * len(frames) // 4, len(frames) - 1]
        for c, fi in enumerate(idx):
            f = frames[fi]
            sheet.paste(f, (pad + c * (cell + pad), pad + r * (cell + pad)), f)
    sheet.save(path)


def write_preview_html() -> None:
    rows = "".join(
        f"""
        <tr><td class="n">{name}</td>
        <td><img src="claude-spark-{name}.gif" width="96"></td>
        <td><img src="apng/claude-spark-{name}.png" width="96"></td></tr>"""
        for name in STATES
    )
    (OUT / "preview.html").write_text(f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Claude Spark v2</title><style>
  body {{ background:#16141a; color:#b7b9c8; font:14px -apple-system,sans-serif;
         display:flex; flex-direction:column; align-items:center; padding:40px; }}
  table {{ border-collapse:collapse; }}
  td {{ padding:14px 28px; text-align:center; }}
  .n {{ font-family:ui-monospace,monospace; color:#7e8290; }}
  th {{ color:#7e8290; font-weight:600; padding-bottom:6px; }}
  .marks img {{ margin:0 12px; vertical-align:middle; }}
  .cap {{ color:#5c574e; font-size:12px; margin-top:6px; }}
</style></head><body>
<h3 style="color:#ecedf2">Claude Spark v2 — StatusIconsPreview.jsx 复刻</h3>
<div class="marks">
  <img src="claude-spark-24.png" width="24">
  <img src="claude-spark-48.png" width="48">
  <img src="claude-spark-128.png" width="128">
  <div class="cap">static mark · 24 / 48 / 128</div>
</div>
<table>
<tr><th></th><th>GIF（1-bit alpha，无辉光）</th><th>APNG（真 alpha，带辉光）</th></tr>
{rows}
</table>
</body></html>""")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    APNG_OUT.mkdir(parents=True, exist_ok=True)

    for size in (24, 48, 128):
        static_mark(size).save(OUT / f"claude-spark-{size}.png")

    sheet_rows = []
    for name, (fn, count, hold) in STATES.items():
        gif_frames = [fn(i, count, False) for i in range(count)]
        apng_frames = [fn(i, count, True) for i in range(count)]
        save_gif(OUT / f"claude-spark-{name}.gif", gif_frames, hold_last=hold)
        save_apng(APNG_OUT / f"claude-spark-{name}.png", apng_frames, hold_last=hold)
        sheet_rows.append((name, apng_frames))
        print(f"  {name}: {count} frames")

    contact_sheet(sheet_rows, OUT / "contact-sheet.png")
    write_preview_html()
    install_app_assets()
    print(f"done → {OUT} (+ app assets in Assets.xcassets)")


if __name__ == "__main__":
    main()
