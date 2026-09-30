#!/usr/bin/env python3
"""Analyse technique d'une vidéo de référence en motion design.

Découpe la vidéo en plans, mesure le rythme (coupes, énergie de mouvement,
tempo et attaques du son), extrait la palette dominante et produit des
planches contact horodatées pour étudier l'animation image par image.

    python3 tools/analyze_reference.py refs/video.mp4
    python3 tools/analyze_reference.py "https://www.tiktok.com/@compte/video/123"
    python3 tools/analyze_reference.py refs/video.mp4 --range 2.0 3.2

Dépendances : pip install -r tools/requirements.txt
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import cv2
import imageio_ffmpeg
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.ticker import MultipleLocator  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
FONT_PATH = Path(matplotlib.get_data_path()) / "fonts/ttf/DejaVuSans.ttf"
ANALYSIS_W = 160  # largeur des images réduites servant aux mesures
SR, HOP, N_FFT = 22050, 512, 2048  # analyse audio : un pas ≈ 23 ms
THUMBS_PER_SHEET = 30
VIDEO_EXT = {".mp4", ".mov", ".webm", ".mkv", ".m4v"}

# Palette de référence dataviz (mode clair)
SURFACE, INK, INK_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3de"
MOTION_COLOR, AUDIO_COLOR, CUT_COLOR = "#2a78d6", "#eb6834", "#e34948"


def font(size):
    return ImageFont.truetype(str(FONT_PATH), size)


def download(url, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["yt-dlp", "--ffmpeg-location", FFMPEG, "--write-info-json",
         "-f", "b[ext=mp4]/bv*+ba/b", "--merge-output-format", "mp4",
         "-o", str(out_dir / "source.%(ext)s"), url],
        check=True,
    )
    return next(p for p in out_dir.glob("source.*") if p.suffix in VIDEO_EXT)


def measure(path):
    """Première passe : mouvement, distance colorimétrique et pixels échantillonnés par image."""
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        sys.exit(f"Impossible d'ouvrir la vidéo : {path}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    size = (ANALYSIS_W, max(1, round(h * ANALYSIS_W / w)))
    rng = np.random.default_rng(0)
    motion, active, hist_dist, samples = [], [], [], []
    prev_gray = prev_hist = None
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        small = cv2.resize(frame, size, interpolation=cv2.INTER_AREA)
        gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float32)
        hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
        hist = cv2.calcHist([hsv], [0, 1, 2], None, [8, 8, 8], [0, 180, 0, 256, 0, 256])
        if prev_gray is None:
            motion.append(0.0)
            active.append(0.0)
            hist_dist.append(0.0)
        else:
            diff = np.abs(gray - prev_gray)
            motion.append(float(diff.mean()) / 255)
            active.append(float((diff > 12).mean()))  # part de l'image qui change vraiment
            hist_dist.append(cv2.compareHist(prev_hist, hist, cv2.HISTCMP_BHATTACHARYYA))
        prev_gray, prev_hist = gray, hist
        if len(motion) % 3 == 1:
            px = small.reshape(-1, 3)
            samples.append((len(motion) - 1, px[rng.choice(len(px), min(256, len(px)), replace=False)]))
    cap.release()
    if not motion:
        sys.exit(f"Aucune image lisible dans {path}")
    return {"fps": fps, "width": w, "height": h, "n": len(motion),
            "motion": np.array(motion), "active": np.array(active), "hist": np.array(hist_dist),
            "samples": samples}


def detect_cuts(motion, hist_dist, fps):
    """Une coupe = pic isolé de (distance d'histogramme + écart de pixels) par rapport à son voisinage."""
    score = hist_dist + motion
    n, r = len(score), 8
    cuts = []
    for i in range(1, n):
        lo, hi = max(1, i - r), min(n, i + r + 1)
        neighbours = np.delete(score[lo:hi], i - lo)
        base = float(np.median(neighbours)) if neighbours.size else 0.0
        if score[i] > 0.35 and score[i] > 2.5 * base + 0.05:
            cuts.append(i)
    # Fusionne les pics trop rapprochés (flash, micro-fondu) en gardant le plus fort.
    merged, min_gap = [], max(2, round(0.1 * fps))
    for i in cuts:
        if merged and i - merged[-1] < min_gap:
            if score[i] > score[merged[-1]]:
                merged[-1] = i
        else:
            merged.append(i)
    return merged


def find_holds(active, fps, still=0.002, min_s=0.25):
    """Passages quasi figés (pause avant un impact, texte tenu à l'écran…) : (première, dernière image)."""
    holds, i, n = [], 1, len(active)
    while i < n:
        if active[i] < still:
            j = i
            while j < n and active[j] < still:
                j += 1
            if (j - i) / fps >= min_s:
                holds.append((i - 1, j - 1))
            i = j
        else:
            i += 1
    return holds


def motion_peaks(active, cuts, fps, count=5):
    """Moments d'animation les plus intenses à l'intérieur des plans (les coupes sont exclues)."""
    smooth = np.convolve(active, np.ones(3) / 3, mode="same")
    masked = smooth.copy()
    for c in cuts:
        masked[max(0, c - 1): c + 2] = 0
    picked = []
    for i in np.argsort(-masked):
        if masked[i] <= 0 or len(picked) == count:
            break
        if all(abs(int(i) - j) > 0.5 * fps for j in picked):
            picked.append(int(i))
    return sorted(picked), smooth, masked


def load_audio(path):
    out = subprocess.run(
        [FFMPEG, "-v", "error", "-i", str(path), "-vn", "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"],
        capture_output=True,
    ).stdout
    y = np.frombuffer(out, dtype=np.int16).astype(np.float32) / 32768
    return y if y.size > SR // 4 and np.abs(y).max() > 1e-3 else None


def analyse_audio(y):
    """Enveloppe RMS, flux spectral (force des attaques), attaques détectées et tempo estimé."""
    frames = np.lib.stride_tricks.sliding_window_view(np.pad(y, N_FFT // 2), N_FFT)[::HOP]
    rms = np.sqrt((frames ** 2).mean(axis=1))
    win = np.hanning(N_FFT).astype(np.float32)
    spec = np.concatenate([
        np.log1p(1000 * np.abs(np.fft.rfft(frames[k:k + 1024] * win, axis=1))).astype(np.float32)
        for k in range(0, len(frames), 1024)
    ])
    flux = np.concatenate([[0.0], np.maximum(0.0, np.diff(spec, axis=0)).sum(axis=1)])
    flux /= flux.max() or 1.0
    times = np.arange(len(flux)) * HOP / SR

    k = max(1, round(0.05 * SR / HOP))  # maximum local sur ±50 ms
    avg = np.convolve(flux, np.ones(21) / 21, mode="same")
    onsets = [i for i in range(len(flux))
              if flux[i] >= flux[max(0, i - k): i + k + 1].max()
              and flux[i] > avg[i] + 0.05 and flux[i] > 0.08]
    return {"times": times, "rms": rms / (rms.max() or 1.0), "onsets": times[onsets],
            "bpm": estimate_tempo(flux)}


def estimate_tempo(flux):
    """Autocorrélation du flux, pondérée autour de 120 BPM pour limiter les erreurs d'octave."""
    env = flux - flux.mean()
    ac = np.correlate(env, env, mode="full")[len(env) - 1:]
    if len(ac) < 3:
        return None
    rate = SR / HOP
    lags = np.arange(1, len(ac))
    bpm = 60 * rate / lags
    ok = (bpm >= 70) & (bpm <= 180)
    if not ok.any():
        return None
    weighted = ac[1:] * np.exp(-0.5 * (np.log2(bpm / 120) / 0.9) ** 2)
    weighted[~ok] = -np.inf
    lag = float(np.argmax(weighted) + 1)
    i = int(lag)
    if i + 1 < len(ac):  # interpolation parabolique du pic
        a, b, c = ac[i - 1], ac[i], ac[i + 1]
        if a - 2 * b + c:
            lag += 0.5 * (a - c) / (a - 2 * b + c)
    return float(60 * rate / lag)


def palette(pixels_bgr, k):
    """Couleurs dominantes (k-means dans l'espace Lab), triées par surface occupée."""
    lab = cv2.cvtColor(pixels_bgr.reshape(-1, 1, 3), cv2.COLOR_BGR2LAB).reshape(-1, 3).astype(np.float32)
    k = min(k, len(np.unique(lab, axis=0)))
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.5)
    _, labels, centers = cv2.kmeans(lab, k, None, crit, 3, cv2.KMEANS_PP_CENTERS)
    counts = np.bincount(labels.ravel(), minlength=k)
    order = np.argsort(-counts)
    bgr = cv2.cvtColor(np.clip(centers[order], 0, 255).astype(np.uint8).reshape(-1, 1, 3),
                       cv2.COLOR_LAB2BGR).reshape(-1, 3)
    return [{"hex": "#{:02x}{:02x}{:02x}".format(r, g, b), "share": round(float(c) / counts.sum(), 3)}
            for (b, g, r), c in zip(bgr, counts[order])]


def grab_frames(path, wanted):
    """Seconde passe : {index: largeur} -> {index: image PIL redimensionnée}."""
    cap = cv2.VideoCapture(str(path))
    out, i, last = {}, 0, max(wanted, default=-1)
    while i <= last:
        ok, frame = cap.read()
        if not ok:
            break
        if i in wanted:
            h, w = frame.shape[:2]
            tw = min(wanted[i], w)
            small = cv2.resize(frame, (tw, round(h * tw / w)), interpolation=cv2.INTER_AREA)
            out[i] = Image.fromarray(cv2.cvtColor(small, cv2.COLOR_BGR2RGB))
        i += 1
    cap.release()
    return out


def fit(im, w):
    return im if im.width == w else im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)


def contact_sheet(thumbs, labels, flagged, cols, path, title):
    tw, th = thumbs[0].size
    pad, bar, head = 8, 24, 40
    rows = -(-len(thumbs) // cols)
    sheet = Image.new("RGB", (pad + cols * (tw + pad), head + rows * (th + bar + pad)), SURFACE)
    d = ImageDraw.Draw(sheet)
    d.text((pad, 10), title, fill=INK, font=font(18))
    small = font(13)
    for k, (im, label, flag) in enumerate(zip(thumbs, labels, flagged)):
        x, y = pad + (k % cols) * (tw + pad), head + (k // cols) * (th + bar + pad)
        sheet.paste(im, (x, y))
        if flag:
            d.rectangle([x - 3, y - 3, x + tw + 2, y + th + 2], outline=CUT_COLOR, width=3)
        d.text((x, y + th + 5), label, fill=CUT_COLOR if flag else INK_2, font=small)
    sheet.save(path, quality=88)


def sheets(items, cols, out, prefix, title):
    """items : liste de (image, légende, signalée). Découpe en planches de THUMBS_PER_SHEET vignettes."""
    paths = []
    chunks = [items[k:k + THUMBS_PER_SHEET] for k in range(0, len(items), THUMBS_PER_SHEET)]
    for n, chunk in enumerate(chunks, 1):
        p = out / f"{prefix}_{n:02d}.jpg"
        contact_sheet(*zip(*chunk), cols, p, f"{title} ({n}/{len(chunks)})")
        paths.append(p)
    return paths


def plot_timeline(fps, smooth, in_shot, cuts, holds, audio, duration, path):
    """Petits multiples partageant l'axe du temps : mouvement en haut, son en bas (jamais deux axes Y)."""
    panels = [("Part de l'image en mouvement (%) · pointillés = coupes (pics écrêtés), zones grises = images figées",
               np.arange(len(smooth)) / fps, smooth * 100, MOTION_COLOR, float(in_shot.max()) * 100)]
    if audio:
        panels.append(("Volume sonore (enveloppe RMS normalisée) · traits en bas = attaques détectées",
                       audio["times"], audio["rms"], AUDIO_COLOR, 1.0))
    fig, axes = plt.subplots(len(panels), 1, figsize=(14, 2.4 * len(panels) + 0.8), dpi=110,
                             sharex=True, squeeze=False)
    fig.patch.set_facecolor(SURFACE)
    axes = axes[:, 0]
    for ax, (title, x, y, color, top_value) in zip(axes, panels):
        ax.set_facecolor(SURFACE)
        for a, b in holds:
            ax.axvspan(a / fps, b / fps, color=GRID, alpha=0.8, lw=0)
        for c in cuts:
            ax.axvline(c / fps, color=INK_2, lw=0.8, ls=(0, (3, 3)))
        ax.fill_between(x, y, color=color, alpha=0.15, lw=0)
        ax.plot(x, y, color=color, lw=1.5)
        ax.set_title(title, loc="left", fontsize=10, color=INK, pad=6)
        ax.set_ylim(0, max(top_value * 1.15, 1e-3))
        ax.grid(True, color=GRID, lw=0.6)
        ax.set_axisbelow(True)
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            ax.spines[side].set_color(GRID)
        ax.tick_params(colors=INK_2, labelsize=8)
    if audio and len(audio["onsets"]):
        ax = axes[1]
        ax.plot(audio["onsets"], np.full(len(audio["onsets"]), ax.get_ylim()[1] * 0.05), "|",
                color=INK_2, ms=8, mew=1)
    if len(cuts) <= 40:  # numéros de plan en étiquettes directes
        top = axes[0]
        for k, start in enumerate([0] + list(cuts), 1):
            top.text(start / fps + duration * 0.003, top.get_ylim()[1] * 0.97, f"P{k}",
                     fontsize=7, color=INK_2, va="top")
    step = 1 if duration <= 20 else 2 if duration <= 60 else 5
    axes[-1].xaxis.set_major_locator(MultipleLocator(step))
    axes[-1].set_xlim(0, duration)
    axes[-1].set_xlabel("temps (s)", color=INK_2, fontsize=9)
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)


def draw_palette(colors, path, width=1000, height=110):
    im = Image.new("RGB", (width, height + 30), SURFACE)
    d, f, x = ImageDraw.Draw(im), font(13), 0
    for c in colors:
        w = max(3, round(c["share"] * width))
        d.rectangle([x, 0, x + w - 3, height], fill=c["hex"])  # 2 px d'espace entre les aplats
        if w > 90:
            d.text((x + 2, height + 8), f'{c["hex"]}  {c["share"] * 100:.0f} %', fill=INK_2, font=f)
        x += w
    im.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="fichier vidéo ou URL (TikTok, YouTube, Instagram…)")
    ap.add_argument("-o", "--out", type=Path, help="dossier de sortie (défaut : refs/<nom>/analyse)")
    ap.add_argument("--range", nargs=2, type=float, metavar=("DEBUT", "FIN"),
                    help="exporte aussi toutes les images entre DEBUT et FIN (secondes)")
    args = ap.parse_args()

    if re.match(r"https?://", args.source):
        slug = re.sub(r"\W+", "_", args.source.split("?")[0].rstrip("/").split("/")[-1]) or "video"
        base = Path("refs") / slug
        video = download(args.source, base)
    else:
        video = Path(args.source)
        if not video.exists():
            sys.exit(f"Fichier introuvable : {video}")
        base = video.parent / video.stem
    out = args.out or base / "analyse"
    out.mkdir(parents=True, exist_ok=True)
    info_json = next(video.parent.glob(f"{video.stem}.info.json"), None)
    meta = json.loads(info_json.read_text()) if info_json else {}

    print(f"Analyse de {video}…")
    m = measure(video)
    fps, n, w, h = m["fps"], m["n"], m["width"], m["height"]
    duration = n / fps
    cuts = detect_cuts(m["motion"], m["hist"], fps)
    bounds = [0] + cuts + [n]
    shots = [(bounds[k], bounds[k + 1] - 1) for k in range(len(bounds) - 1)]
    holds = find_holds(m["active"], fps)
    peaks, smooth, in_shot = motion_peaks(m["active"], cuts, fps)

    y = load_audio(video)
    audio = analyse_audio(y) if y is not None else None
    sync = None
    if audio and cuts and len(audio["onsets"]):
        tol = max(0.06, 1.5 / fps)
        dist = np.abs(np.array(cuts)[:, None] / fps - audio["onsets"][None, :]).min(axis=1)
        sync = {"on_beat": int((dist <= tol).sum()), "total": len(cuts), "tolerance_s": round(tol, 3)}

    all_px = np.concatenate([px for _, px in m["samples"]])
    global_palette = palette(all_px, 6)
    shot_palettes = []
    for a, b in shots:
        px = [p for i, p in m["samples"] if a <= i <= b]
        if not px:  # plan trop court pour avoir été échantillonné
            px = [min(m["samples"], key=lambda s: abs(s[0] - (a + b) / 2))[1]]
        shot_palettes.append(palette(np.concatenate(px), 4))

    # Vignettes : planche régulière, début/milieu/fin de chaque plan, passage demandé image par image.
    portrait = h > w * 1.1
    landscape = w > h * 1.1
    cols = 6 if portrait else 4 if landscape else 5
    tw = 200 if portrait else 320 if landscape else 240
    step = min(1.0, max(0.2, duration / 48))
    regular = sorted({min(n - 1, round(t * fps)) for t in np.arange(0, duration, step)})
    shot_frames = [(k, label, i) for k, (a, b) in enumerate(shots, 1)
                   for label, i in (("début", a), ("milieu", (a + b) // 2), ("fin", b))]
    ranged = []
    if args.range:
        r0, r1 = sorted(args.range)
        ranged = list(range(max(0, round(r0 * fps)), min(n, round(r1 * fps) + 1)))
    wanted = {}
    for i in regular + [i for *_, i in shot_frames] + ranged:
        wanted[i] = tw
    for a, b in shots:
        wanted[(a + b) // 2] = 720
    frames = grab_frames(video, wanted)

    def cut_between(i0, i1):
        return any(i0 < c <= i1 for c in cuts)

    produced = []
    items = [(fit(frames[i], tw), f"{i / fps:.2f} s · #{i}", cut_between(prev, i))
             for prev, i in zip([-1] + regular[:-1], regular) if i in frames]
    produced += sheets(items, cols, out, "planche", f"{video.name} — une image toutes les {step:.2f} s "
                       "(cadre rouge = coupe depuis la vignette précédente)")
    items = [(fit(frames[i], tw), f"P{k} {label} {i / fps:.2f} s", False)
             for k, label, i in shot_frames if i in frames]
    produced += sheets(items, cols, out, "plans", "Début / milieu / fin de chaque plan")
    if ranged:
        items = [(fit(frames[i], tw), f"{i / fps:.3f} s · {m['active'][i] * 100:.1f} %", i in cuts)
                 for i in ranged if i in frames]
        produced += sheets(items, cols, out, f"passage_{r0:.2f}-{r1:.2f}",
                           f"Toutes les images de {r0:.2f} à {r1:.2f} s (% = part de l'image qui a bougé)")
    shots_dir = out / "plans_hd"
    shots_dir.mkdir(exist_ok=True)
    for k, (a, b) in enumerate(shots, 1):
        mid = (a + b) // 2
        if mid in frames:
            p = shots_dir / f"P{k:02d}_{mid / fps:06.2f}s.jpg"
            frames[mid].save(p, quality=92)
    plot_timeline(fps, smooth, in_shot, cuts, holds, audio, duration, out / "timeline.png")
    draw_palette(global_palette, out / "palette.png")
    produced += [out / "timeline.png", out / "palette.png", shots_dir]

    # Rapport
    ratio = next((r for r, v in {"9:16": 9 / 16, "16:9": 16 / 9, "1:1": 1, "4:5": 4 / 5, "4:3": 4 / 3}.items()
                  if abs(w / h - v) < 0.02), f"{w / h:.3f}")
    asl = duration / len(shots)
    lines = [f"# Analyse de référence — {video.name}", ""]
    if meta:
        lines += [f"- **Compte** : {meta.get('uploader') or meta.get('channel') or '?'}",
                  f"- **Légende** : {(meta.get('description') or meta.get('title') or '').strip()}",
                  f"- **Son** : {meta.get('track') or '?'} — {meta.get('artist') or '?'}",
                  f"- **URL** : {meta.get('webpage_url', '')}", ""]
    lines += ["| Mesure | Valeur |", "|---|---|",
              f"| Durée | {duration:.2f} s ({n} images) |",
              f"| Format | {w}×{h} ({ratio}), {fps:.2f} ips |",
              f"| Plans | {len(shots)} — durée moyenne {asl:.2f} s, {len(cuts) / duration:.2f} coupe(s)/s |",
              f"| Part moyenne de l'image en mouvement (hors coupes) | {float(in_shot.mean()) * 100:.1f} % "
              f"(pic {float(in_shot.max()) * 100:.1f} %) |"]
    if audio:
        bpm = f"≈ {audio['bpm']:.0f} BPM" if audio["bpm"] else "non déterminé"
        lines.append(f"| Son | tempo {bpm}, {len(audio['onsets'])} attaques détectées |")
        if sync:
            lines.append(f"| Coupes calées sur une attaque (±{sync['tolerance_s'] * 1000:.0f} ms) | "
                         f"{sync['on_beat']}/{sync['total']} ({100 * sync['on_beat'] / sync['total']:.0f} %) |")
    else:
        lines.append("| Son | aucune piste audio exploitable |")
    lines += ["", "## Plans", "", "| # | Début | Fin | Durée | Palette du plan |", "|---|---|---|---|---|"]
    for k, ((a, b), pal) in enumerate(zip(shots, shot_palettes), 1):
        lines.append(f"| P{k} | {a / fps:.2f} s | {(b + 1) / fps:.2f} s | {(b - a + 1) / fps:.2f} s | "
                     + " ".join(f"`{c['hex']}`" for c in pal) + " |")
    lines += ["", "## Moments d'animation les plus intenses (hors coupes)", ""]
    lines += [f"- {i / fps:.2f} s — {smooth[i] * 100:.1f} % de l'image bouge" for i in peaks] or ["- aucun"]
    lines += ["", "## Images figées (≥ 0,25 s)", ""]
    lines += [f"- {a / fps:.2f} → {b / fps:.2f} s ({(b - a) / fps:.2f} s)" for a, b in holds] or ["- aucune"]
    lines += ["", "## Palette globale", ""]
    lines += [f"- `{c['hex']}` — {c['share'] * 100:.0f} %" for c in global_palette]
    lines += ["", "## Fichiers produits", ""] + [f"- `{p.relative_to(out)}`" for p in produced]
    (out / "rapport.md").write_text("\n".join(lines) + "\n")

    data = {"video": str(video), "fps": fps, "frames": n, "width": w, "height": h, "duration": duration,
            "cuts_frames": cuts, "cuts_s": [c / fps for c in cuts],
            "shots": [{"start_s": a / fps, "end_s": (b + 1) / fps, "palette": p}
                      for (a, b), p in zip(shots, shot_palettes)],
            "holds_s": [(a / fps, b / fps) for a, b in holds], "motion_peaks_s": [i / fps for i in peaks],
            "motion_per_frame": [round(float(v), 5) for v in m["motion"]],
            "active_per_frame": [round(float(v), 5) for v in m["active"]], "palette": global_palette,
            "audio": None if not audio else {"bpm": audio["bpm"], "onsets_s": audio["onsets"].round(3).tolist()},
            "cut_sync": sync}
    (out / "data.json").write_text(json.dumps(data, indent=1, ensure_ascii=False))
    print("\n".join(lines[:12]))
    print(f"\nRapport complet : {out / 'rapport.md'}")


if __name__ == "__main__":
    main()
