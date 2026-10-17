from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
PLAYWRIGHT = ROOT / ".playwright-cli"


def font(size: int):
    return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)


def refresh_editor(filename: str, content: str) -> None:
    old = Image.open(DOCS / filename).convert("RGB")
    web = Image.open(PLAYWRIGHT / content).convert("RGB")
    if old.size != (1860, 1248) or web.size != (1860, 1200):
        raise ValueError(f"unexpected editor screenshot sizes: {old.size=} {web.size=}")

    # Keep the native-looking title bar while replacing the page below it with the current UI.
    old.paste(web, (0, 48))
    draw = ImageDraw.Draw(old)
    draw.rectangle((116, 7, 500, 42), fill=(11, 18, 30))
    draw.text((125, 13), "Apartment Control — Edit Home", font=font(20), fill=(159, 167, 184))
    old.save(DOCS / filename, "PNG", optimize=True)


def refresh_ai() -> None:
    image = Image.open(PLAYWRIGHT / "ai-live-full.png").convert("RGB")
    image = image.resize((968, 3526), Image.Resampling.LANCZOS)
    image.save(DOCS / "ai-access.png", "PNG", optimize=True)


def refresh_iphone() -> None:
    image = Image.open(DOCS / "iphone.png").convert("RGB")
    draw = ImageDraw.Draw(image)
    # Refresh the one old product-name string in the settings panel while preserving the
    # existing four-screen composition and the current native UI imagery.
    draw.rectangle((2055, 620, 2670, 690), fill=(10, 14, 26))
    muted = (112, 118, 133)
    draw.text((2075, 625), "Your own home is drawn in Apartment Control on the Mac and", font=font(23), fill=muted)
    draw.text((2075, 654), "arrives here when you pair the two.", font=font(23), fill=muted)
    image.save(DOCS / "iphone.png", "PNG", optimize=True)


refresh_editor("editor.png", "editor-content.png")
refresh_editor("connections.png", "connections-content.png")
refresh_ai()
refresh_iphone()
