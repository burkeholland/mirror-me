"""Generate app branding from the website's SVG, or verify it with --check.

Install build-only dependencies with:
    python -m pip install -r scripts\\icon-requirements.txt
"""
import argparse
from io import BytesIO
from pathlib import Path

from PIL import Image
from resvg_py import svg_to_bytes

ROOT = Path(__file__).resolve().parents[1]
SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)


def generated_assets():
    source = (ROOT / "site" / "assets" / "mark.svg").read_text(encoding="utf-8")
    png = svg_to_bytes(
        svg_string=source, width=1024, height=1024, skip_system_fonts=True
    )
    with Image.open(BytesIO(png)) as image:
        ico = BytesIO()
        image.save(ico, format="ICO", sizes=[(size, size) for size in SIZES])
    return {
        Path("frontend/src/assets/mark.svg"): source.encode("utf-8"),
        Path("build/appicon.png"): png,
        Path("build/windows/icon.ico"): ico.getvalue(),
        Path("receiver/resources/mirrorme.ico"): ico.getvalue(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if generated branding is stale")
    args = parser.parse_args()
    assets = generated_assets()
    if args.check:
        stale = [
            str(path) for path, content in assets.items()
            if not (ROOT / path).is_file() or (ROOT / path).read_bytes() != content
        ]
        if stale:
            parser.exit(1, "Run python scripts\\generate-icon.py to update: " + ", ".join(stale) + "\n")
        with Image.open(ROOT / "build" / "windows" / "icon.ico") as icon:
            if icon.ico.sizes() != {(size, size) for size in SIZES}:
                parser.exit(1, "The Windows icon is missing required display sizes.\n")
        print("All app icons match site\\assets\\mark.svg.")
    else:
        for path, content in assets.items():
            destination = ROOT / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
        print("Generated app, tray and video-window icons from site\\assets\\mark.svg.")


if __name__ == "__main__":
    main()
