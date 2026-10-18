"""Ikona Opentify v3 (OP-VI, 18. 10. 2026): tři skleněná kolečka + ▶ nad gradientem appky.
Zdroje jsou hotové rendery v tool/icon/v3/ (návrh a skripty: Obsidian claude/design/opentify-identita/):
  opentify-vychozi-1024.png  modrá, hlavní ikona
  opentify-tmava-1024.png    tmavý režim iOS
  opentify-svetla-1024.png   světlá (web / další použití)
  vychozi-pozadi.png         samotné pozadí modré (pro maskable ikony webu)
Tenhle skript z nich jen vyrobí velikosti pro iOS, web, Android a Windows:
  python tool/icon/make_icon_v3.py   (spouštět ze složky client/)"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter, ImageOps

TADY = os.path.join('tool', 'icon', 'v3')


def nacti(jmeno):
    return Image.open(os.path.join(TADY, jmeno)).convert('RGB')


vychozi = nacti('opentify-vychozi-1024.png')
tmava = nacti('opentify-tmava-1024.png')
pozadi = nacti('vychozi-pozadi.png')


def zmensi(im, px):
    return im.resize((px, px), Image.LANCZOS)


# iOS: výchozí + tmavá + tónovaná (iOS 18+; starší iOS bere jen výchozí). Tónovaná = šedotónová verze tmavé,
# barvu dodá systém. Tinted a Clear z vrstev by uměl až .icon z Icon Composeru (potřebuje Mac).
ios = os.path.join('ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
vychozi.save(os.path.join(ios, 'AppIcon-1024.png'))
tmava.save(os.path.join(ios, 'AppIcon-1024-dark.png'))
ImageOps.autocontrast(ImageOps.grayscale(tmava), cutoff=0.5).save(os.path.join(ios, 'AppIcon-1024-tinted.png'))
with open(os.path.join(ios, 'Contents.json'), 'w', encoding='utf-8') as f:
    json.dump({
        'images': [
            {'filename': 'AppIcon-1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
            {'appearances': [{'appearance': 'luminosity', 'value': 'dark'}],
             'filename': 'AppIcon-1024-dark.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
            {'appearances': [{'appearance': 'luminosity', 'value': 'tinted'}],
             'filename': 'AppIcon-1024-tinted.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
        ],
        'info': {'author': 'xcode', 'version': 1},
    }, f, indent=2)
    f.write('\n')

# web: ikony, favicon, apple-touch; maskable = obsah zmenšený do bezpečné zóny (80 %) na celém pozadí
zmensi(vychozi, 64).save(os.path.join('web', 'favicon.png'))
zmensi(vychozi, 180).save(os.path.join('web', 'icons', 'apple-touch-icon.png'))
for px in (192, 512):
    zmensi(vychozi, px).save(os.path.join('web', 'icons', f'Icon-{px}.png'))
    m = pozadi.copy()
    vnitrek = zmensi(vychozi, int(1024 * 0.8))
    # jen kolečka (s okrajem na stín), ať na pozadí není vidět šev čtverce
    maska = Image.new('L', (vnitrek.width * 4, vnitrek.height * 4), 0)
    r = int(vnitrek.width * 4 * 0.47)
    ImageDraw.Draw(maska).ellipse((maska.width // 2 - r, maska.height // 2 - r, maska.width // 2 + r, maska.height // 2 + r), fill=255)
    maska = maska.resize(vnitrek.size, Image.LANCZOS).filter(ImageFilter.GaussianBlur(6))
    m.paste(vnitrek, ((1024 - vnitrek.width) // 2, (1024 - vnitrek.height) // 2), maska)
    zmensi(m, px).save(os.path.join('web', 'icons', f'Icon-maskable-{px}.png'))

# Android (starší čtvercové ikony) a Windows
for slozka, px in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
    zmensi(vychozi, px).save(os.path.join('android', 'app', 'src', 'main', 'res', f'mipmap-{slozka}', 'ic_launcher.png'))
vychozi.save(os.path.join('windows', 'runner', 'resources', 'app_icon.ico'),
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print('ikona v3: iOS (výchozí, tmavá, tónovaná), web, Android, Windows hotovo')
