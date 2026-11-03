#!/usr/bin/env python3
"""Generate the architectural line-art icon. Requires Pillow only to regenerate."""
from pathlib import Path
from PIL import Image, ImageDraw
import json
root = Path(__file__).resolve().parents[1] / 'ArhitektOffice/Resources/Assets.xcassets/AppIcon.appiconset'
scale = 3
image = Image.new('RGB', (1024 * scale, 1024 * scale), '#12343D')
draw = ImageDraw.Draw(image)
def line(points, fill, width):
    draw.line([(int(x*scale), int(y*scale)) for x, y in points], fill=fill, width=width*scale, joint='curve')
# Elevation, central entrance and drafting baseline; no text or font dependency.
line([(208, 744), (208, 434), (512, 236), (816, 434), (816, 744)], '#F2EBDD', 28)
line([(208, 434), (816, 434)], '#F2EBDD', 20)
line([(428, 744), (428, 554), (596, 554), (596, 744)], '#68C4B8', 24)
line([(154, 768), (870, 768)], '#68C4B8', 18)
line([(310, 510), (310, 644)], '#F2EBDD', 18)
line([(714, 510), (714, 644)], '#F2EBDD', 18)
image.resize((1024, 1024), Image.Resampling.LANCZOS).save(root / 'AppIcon.png')
(root / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
