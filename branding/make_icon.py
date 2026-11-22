from PIL import Image
from pathlib import Path

src = Path(r"C:\Users\Administrator\.cursor\projects\d-Documents-Desktop-APP\assets\logo-8d5fefaa-792f-4882-ad51-7c5085d95f7a.png")
brand_dir = Path(r"d:\Documents\Desktop\APP\JiheDrive_iOS\branding")
icon_path = Path(r"d:\Documents\Desktop\APP\JiheDrive_iOS\JiheDrive\Assets.xcassets\AppIcon.appiconset\icon-1024.png")
brand_dir.mkdir(parents=True, exist_ok=True)

img = Image.open(src).convert("RGBA")
img.save(brand_dir / "mascot-full.png")

size = 1024
pad = 72
canvas = Image.new("RGBA", (size, size), (255, 255, 255, 255))
max_w = size - pad * 2
max_h = size - pad * 2
scale = min(max_w / img.width, max_h / img.height)
nw, nh = int(img.width * scale), int(img.height * scale)
resized = img.resize((nw, nh), Image.Resampling.LANCZOS)
x = (size - nw) // 2
y = (size - nh) // 2 + 8
canvas.paste(resized, (x, y), resized)

rgb = Image.new("RGB", (size, size), (255, 255, 255))
rgb.paste(canvas, mask=canvas.split()[-1])
rgb.save(icon_path, format="PNG", optimize=True)
rgb.save(brand_dir / "jihedrive-logo.png", format="PNG", optimize=True)
print(f"saved {icon_path} ({nw}x{nh} mascot)")
