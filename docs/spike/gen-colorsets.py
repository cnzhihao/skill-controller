#!/usr/bin/env python3
# gen-colorsets.py — Phase 0-3：从 extract tokens 生成 Asset Catalog colorset
# 源：spark-output/extract/skill-controller-proto/skill-controller-proto-variables.css
# 裁决（design-language §17.1）：dark sidebar-primary 蓝色残留 → 统一灰阶(0.205)
# 输出：App/SkillController/Resources/Assets.xcassets/<name>.colorset/Contents.json (Any/Dark)

import math, os, json, re, sys

# oklch → linear sRGB → sRGB (标准 Björn Ottosson oklab 变换)
def oklch_to_srgb(l, c, h):
    hr = math.radians(h)
    a, b = c * math.cos(hr), c * math.sin(hr)
    l_ = l + 0.3963377774 * a + 0.2158037573 * b
    m_ = l - 0.1055613458 * a - 0.0638541728 * b
    s_ = l - 0.0894841775 * a - 1.2914855480 * b
    l_, m_, s_ = l_**3, m_**3, s_**3
    r = +4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
    g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
    bl = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
    def gam(x):
        x = max(0.0, min(1.0, x))
        return 12.92 * x if x <= 0.0031308 else 1.055 * (x ** (1 / 2.4)) - 0.055
    return gam(r), gam(g), gam(bl)

def parse_oklch(s):
    m = re.match(r"oklch\(([\d.]+) ([\d.]+) ([\d.]+)\)", s)
    if m:
        return oklch_to_srgb(*map(float, m.groups())), 1.0
    m = re.match(r"oklch\(([\d.]+) 0 0 / (\d+)%\)", s)
    if m:  # 本 tokens 中 alpha 只出现在纯白灰上
        rgb = oklch_to_srgb(float(m.group(1)), 0, 0)
        return rgb, int(m.group(2)) / 100
    raise ValueError(s)

LIGHT = {
    "background": "oklch(1 0 0)", "foreground": "oklch(0.145 0 0)",
    "card": "oklch(1 0 0)", "cardForeground": "oklch(0.145 0 0)",
    "popover": "oklch(1 0 0)", "popoverForeground": "oklch(0.145 0 0)",
    "primary": "oklch(0.205 0 0)", "primaryForeground": "oklch(0.985 0 0)",
    "secondary": "oklch(0.97 0 0)", "secondaryForeground": "oklch(0.205 0 0)",
    "muted": "oklch(0.97 0 0)", "mutedForeground": "oklch(0.556 0 0)",
    "accent": "oklch(0.97 0 0)", "accentForeground": "oklch(0.205 0 0)",
    "destructive": "oklch(0.577 0.245 27.325)",
    "border": "oklch(0.922 0 0)", "input": "oklch(0.922 0 0)", "ring": "oklch(0.708 0 0)",
    "chart1": "oklch(0.87 0 0)", "chart2": "oklch(0.556 0 0)", "chart3": "oklch(0.439 0 0)",
    "chart4": "oklch(0.371 0 0)", "chart5": "oklch(0.269 0 0)",
    "sidebar": "oklch(0.985 0 0)", "sidebarForeground": "oklch(0.145 0 0)",
    "sidebarPrimary": "oklch(0.205 0 0)", "sidebarPrimaryForeground": "oklch(0.985 0 0)",
    "sidebarAccent": "oklch(0.97 0 0)", "sidebarAccentForeground": "oklch(0.205 0 0)",
    "sidebarBorder": "oklch(0.922 0 0)", "sidebarRing": "oklch(0.708 0 0)",
}
DARK = {
    "background": "oklch(0.145 0 0)", "foreground": "oklch(0.985 0 0)",
    "card": "oklch(0.205 0 0)", "cardForeground": "oklch(0.985 0 0)",
    "popover": "oklch(0.205 0 0)", "popoverForeground": "oklch(0.985 0 0)",
    "primary": "oklch(0.922 0 0)", "primaryForeground": "oklch(0.205 0 0)",
    "secondary": "oklch(0.269 0 0)", "secondaryForeground": "oklch(0.985 0 0)",
    "muted": "oklch(0.269 0 0)", "mutedForeground": "oklch(0.708 0 0)",
    "accent": "oklch(0.269 0 0)", "accentForeground": "oklch(0.985 0 0)",
    "destructive": "oklch(0.704 0.191 22.216)",
    "border": "oklch(1 0 0 / 10%)", "input": "oklch(1 0 0 / 15%)", "ring": "oklch(0.556 0 0)",
    "chart1": "oklch(0.87 0 0)", "chart2": "oklch(0.556 0 0)", "chart3": "oklch(0.439 0 0)",
    "chart4": "oklch(0.371 0 0)", "chart5": "oklch(0.269 0 0)",
    "sidebar": "oklch(0.205 0 0)", "sidebarForeground": "oklch(0.985 0 0)",
    # §17.1 裁决：shadcn 蓝残留 → 灰阶
    "sidebarPrimary": "oklch(0.205 0 0)", "sidebarPrimaryForeground": "oklch(0.985 0 0)",
    "sidebarAccent": "oklch(0.269 0 0)", "sidebarAccentForeground": "oklch(0.985 0 0)",
    "sidebarBorder": "oklch(1 0 0 / 10%)", "sidebarRing": "oklch(0.556 0 0)",
}

def comp(rgb, alpha):
    def comp_of(x):
        return {"color-space": "srgb", "components": {
            "red": f"0x{round(x[0]*255):02X}", "green": f"0x{round(x[1]*255):02X}",
            "blue": f"0x{round(x[2]*255):02X}", "alpha": f"{alpha:.3f}"}} if False else None
    return rgb, alpha

def appearance(rgb, alpha, mode):
    return {
        "idiom": "universal",
        "appearances": [{"appearance": "luminosity", "value": mode}] if mode != "any" else [],
        "color": {
            "color-space": "srgb",
            "components": {
                "red": f"0x{round(rgb[0]*255):02X}",
                "green": f"0x{round(rgb[1]*255):02X}",
                "blue": f"0x{round(rgb[2]*255):02X}",
                "alpha": f"{alpha:g}",
            },
        },
    }

def main(root):
    assert set(LIGHT) == set(DARK), "light/dark 键不一致"
    xcassets = os.path.join(root, "App", "Assets.xcassets")
    os.makedirs(xcassets, exist_ok=True)
    with open(os.path.join(xcassets, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    for name in LIGHT:
        lrgb, la = parse_oklch(LIGHT[name])
        drgb, da = parse_oklch(DARK[name])
        d = os.path.join(xcassets, f"{name}.colorset")
        os.makedirs(d, exist_ok=True)
        data = {"colors": [appearance(lrgb, la, "any"), appearance(drgb, da, "dark")],
                "info": {"author": "xcode", "version": 1}}
        with open(os.path.join(d, "Contents.json"), "w") as f:
            json.dump(data, f, indent=2)
    print(f"OK: {len(LIGHT)} colorsets → {xcassets}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
