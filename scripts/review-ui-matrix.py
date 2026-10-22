#!/usr/bin/env python3
"""Read-only checks for the synthetic ImageRenderer review export. Requires Pillow."""
import argparse
import json
from collections import Counter
from pathlib import Path
from PIL import Image


def luminance(rgb):
    values = [v / 255 for v in rgb]
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in values]
    return sum(v * weight for v, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


def contrast(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    manifest = json.loads((args.directory / 'matrix.json').read_text())
    assert len(manifest) == 48
    report = {'images': len(manifest), 'checks': [], 'limits': [
        'Measures primary text and secondary-text palette tokens on exported layouts, not every native control pixel.',
        'Native list, table and button chrome requires compositor inspection.',
        'macOS 15 runtime and live audio acceptance remain needs_evidence.']}
    for entry in manifest:
        with Image.open(args.directory / entry['file']) as image:
            image.load()
            assert image.format == 'PNG' and image.size == (int(entry['width']), int(entry['height'])), entry
            assert image.width == (1424 if entry['state'].startswith('cleanup-') else int(entry['popoverWidth']) + 64), entry
            assert 300 <= image.height <= 1500, entry
            if not entry['state'].startswith('call-'):
                continue
            image = image.convert('RGB')
            panel_width = int(entry['popoverWidth'])
            x = (image.width - panel_width) // 2
            background = image.getpixel((x + 5, image.height // 2))
            crop = image.crop((x + 32, 120, x + panel_width - 32, image.height - 120))
            counts = Counter(crop.get_flattened_data() if hasattr(crop, 'get_flattened_data') else crop.getdata())
            dark = 'dark' in entry['appearance']
            candidates = [(rgb, count) for rgb, count in counts.items() if max(rgb) - min(rgb) <= 1 and (180 < rgb[0] <= 255 if dark else rgb[0] < 70)]
            foreground, pixels = max(candidates, key=lambda value: value[1])
            ratio = contrast(foreground, background)
            assert ratio >= 4.5, (entry, foreground, background, ratio)
            report['checks'].append({'file': entry['file'], 'foreground': foreground, 'background': background, 'text_pixels': pixels, 'contrast': round(ratio, 2)})
    report['palette_checks'] = []
    for appearance in ['light', 'dark', 'reduced-light', 'reduced-dark']:
        with Image.open(args.directory / ('palette-' + appearance + '.png')) as palette:
            palette = palette.convert('RGB')
            background, secondary, primary, accent = [palette.getpixel((x, 20)) for x in [20, 60, 100, 140]]
            ratio = contrast(secondary, background)
            assert ratio >= 4.5, (appearance, secondary, background, ratio)
            report['palette_checks'].append({'appearance': appearance, 'background': background,
                'secondary': secondary, 'secondary_contrast': round(ratio, 2),
                'primary_contrast': round(contrast(primary, background), 2),
                'system_accent_flat_white_contrast': round(contrast((255, 255, 255), accent), 2)})
    report['limits'].append('System accent swatches are not native button bezels. Their flat white contrast does not prove native control contrast; the selected system accent is preserved.')
    output = args.directory / 'contrast-report.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
