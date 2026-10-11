#!/usr/bin/env python3
"""Generate App Store 6.9"-class screenshots at exactly 1290x2796.

Input: recordings/*.png (750x1334 SE3 captures, dark mode, real UI).
Output: appstore/screenshots/*.png — 1290x2796 RGB PNG, no alpha.
Framed marketing style: headline + scaled real UI + caption.
Passes App Store Connect pixel-exact validator.
"""
from PIL import Image, ImageDraw, ImageFont
import os

W, H = 1290, 2796
BG = (9, 20, 16)          # deep green-black (matches icon/launch)
CARD = (22, 34, 29)
ACCENT = (52, 199, 123)   # icon green
TEXT = (245, 245, 244)
SUB = (170, 185, 178)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def font(size, bold=False):
    # macOS Helvetica; fall back to default bitmap font.
    candidates = [
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for p in candidates:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size, index=0 if not bold else 1)
            except Exception:
                try:
                    return ImageFont.truetype(p, size)
                except Exception:
                    pass
    return ImageFont.load_default()

SHOTS = [
    ("01-loop.png", "Today's Loop", "Due-sorted queue",
     "Due / Total / Mastered at a glance. Open a verse to practice."),
    ("02-review-mistake.png", "Type first letters", "Reference tested last",
     "Right letter appears. Wrong letter buzzes red — and moves on."),
    ("03-review-forgiven.png", "Forgive slips", "Tap red to mark accidental",
     "Fat-finger? Tap any red word. Shake forgives the latest."),
    ("04-graded.png", "Grade honestly", "Real SM-2 + 8s Undo",
     "Again / Hard / Good / Easy drives ease and intervals."),
    ("06-add-verse.png", "Add any passage", "ESV fetch built in",
     "Ranges like Psalm 23:1-6 work. ESV fills in automatically."),
    ("05-settings.png", "Yours, truly", "Encrypted backup · Delete anytime",
     "Export JSON anytime. Delete All My Data erases device + cloud."),
]

def round_corners(im, radius):
    mask = Image.new("L", im.size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, im.size[0], im.size[1]], radius=radius, fill=255)
    im.putalpha(mask)
    bg = Image.new("RGBA", im.size, (0, 0, 0, 0))
    return Image.alpha_composite(bg, im)

def make(src_name, headline, sub, caption, out_path):
    src = Image.open(os.path.join(ROOT, "recordings", src_name)).convert("RGB")
    canvas = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(canvas)
    # top accent bar
    d.rectangle([0, 0, W, 14], fill=ACCENT)
    # headline
    f_head = font(84, bold=True)
    f_sub = font(46)
    f_cap = font(38)
    f_foot = font(32)
    y = 150
    d.text((80, y), headline, font=f_head, fill=TEXT)
    y += 120
    d.text((80, y), sub, font=f_sub, fill=ACCENT)
    y += 100
    # app shot: fit width 1130, keep aspect
    target_w = 1130
    scale = target_w / src.width
    target_h = int(src.height * scale)
    max_h = 1850
    if target_h > max_h:
        target_h = max_h
        target_w = int(target_h * (src.width / src.height))
    shot = src.resize((target_w, target_h), Image.LANCZOS)
    shot = round_corners(shot.convert("RGBA"), 64).convert("RGB", dither=None)
    # paste centered (on BG, rounded corners get BG fill via mask paste)
    x = (W - target_w) // 2
    sy = y + 20
    # re-add rounded mask paste for clean corners
    mask = Image.new("L", (target_w, target_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, target_w, target_h], radius=64, fill=255)
    canvas.paste(shot, (x, sy), mask)
    # caption below shot
    cy = sy + target_h + 60
    # wrap caption manually (two lines max)
    d.text((80, cy), caption, font=f_cap, fill=SUB)
    d.text((80, H - 140), "Verse Loop Daily  •  ESV-only  •  Offline-first  •  No account", font=f_foot, fill=(110, 125, 118))
    canvas.save(out_path, "PNG")
    print(out_path, canvas.size)

def main():
    outdir = os.path.join(ROOT, "appstore", "screenshots")
    os.makedirs(outdir, exist_ok=True)
    for i, (src, head, sub, cap) in enumerate(SHOTS, 1):
        out = os.path.join(outdir, f"{i:02d}-{src.replace('.png','')}-1290x2796.png")
        make(src, head, sub, cap, out)
    # verify
    for f in sorted(os.listdir(outdir)):
        im = Image.open(os.path.join(outdir, f))
        assert im.size == (W, H), (f, im.size)
        assert im.mode == "RGB", (f, im.mode)
    print("OK: 6 screenshots at 1290x2796 RGB")

if __name__ == "__main__":
    main()
