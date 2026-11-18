#!/usr/bin/env python3
"""Erzeugt das App-Icon aus dem Traumschreiber-Zeichen (zwei Balken untereinander).

Die Balken stammen aus dem Schriftzug: Hellblau #ABD5FF (unter "Traum") und Orange
#FF9151 (unter "schreiber"), Längenverhältnis 334,7 : 491,5. Im Zeichen stehen sie
linksbündig untereinander auf Dunkelblau #112233. Nach demselben Muster bekommt jede
sd20-Einheit ihr Zeichen: die Balken ihres Schriftzugs in ihren Längen, untereinander.

Aufruf aus dem App-Ordner:  python3 tool/make_icons.py
Schreibt Android-Mipmaps (normal, adaptiv, monochrom), iOS-Icons, store/icon_512.png
und store/traumschreiber_zeichen.svg.
"""
import json
from pathlib import Path
from PIL import Image, ImageDraw

BLAU, ORANGE, NAVY = (0xAB, 0xD5, 0xFF), (0xFF, 0x91, 0x51), (0x11, 0x22, 0x33)
VERH = 491.5 / 334.7  # Orange : Blau


def geometrie(n, anteil):
    """Balken (x, y, w, h) für ein Quadrat der Kantenlänge n; anteil = Länge des Orange-Balkens."""
    lo = n * anteil                       # Orange, der längere Balken
    lb = lo / VERH                        # Blau, kürzer im Verhältnis des Schriftzugs
    h = lo * 0.217                        # Balkendicke
    g = h * 0.45                          # Abstand zwischen den Balken
    x0 = (n - lo) / 2
    y0 = (n - 2 * h - g) / 2
    return [(x0, y0, lb, h, BLAU), (x0, y0 + h + g, lo, h, ORANGE)]


def bild(n, anteil, hintergrund=NAVY, farbe=None, ss=1):
    N = n * ss
    im = Image.new('RGBA', (N, N), (0, 0, 0, 0) if hintergrund is None else hintergrund + (255,))
    dr = ImageDraw.Draw(im)
    # Kanten auf ganze Pixel der Zielgröße legen, damit beide Balken exakt gleich dick sind
    for x, y, w, h, c in geometrie(n, anteil):
        x0, y0, x1, y1 = (round(v) * ss for v in (x, y, x + w, y + h))
        dr.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(farbe or c) + (255,))
    im = im.resize((n, n), Image.LANCZOS)
    return im if hintergrund is None else im.convert('RGB')


def svg(pfad, n=1024, anteil=0.60):
    teile = ''.join(
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="#{c[0]:02X}{c[1]:02X}{c[2]:02X}"/>'
        for x, y, w, h, c in geometrie(n, anteil))
    pfad.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n} {n}">'
                    f'<title>Traumschreiber</title><rect width="{n}" height="{n}" fill="#112233"/>{teile}</svg>\n')


def main():
    res = Path('android/app/src/main/res')
    for ordner, faktor in {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}.items():
        d = res / f'mipmap-{ordner}'
        bild(round(48 * faktor), 0.60).save(d / 'ic_launcher.png')
        # adaptiv: 108 dp, sichtbar sicher sind die mittleren 66 dp -> Zeichen 48 % der Kachel, Diagonale bleibt in den 66 dp
        bild(round(108 * faktor), 0.48, hintergrund=None).save(d / 'ic_launcher_foreground.png')
        bild(round(108 * faktor), 0.48, hintergrund=None, farbe=(255, 255, 255)).save(d / 'ic_launcher_monochrome.png')
    (res / 'values/ic_launcher_background.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#112233</color>\n</resources>\n')
    ios = Path('ios/Runner/Assets.xcassets/AppIcon.appiconset')
    for e in json.loads((ios / 'Contents.json').read_text())['images']:
        if 'filename' in e:
            n = round(float(e['size'].split('x')[0]) * int(e['scale'][0]))
            bild(n, 0.60).save(ios / e['filename'])
    bild(512, 0.60).save('store/icon_512.png')
    svg(Path('store/traumschreiber_zeichen.svg'))


if __name__ == '__main__':
    main()
