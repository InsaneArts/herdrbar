#!/usr/bin/env python3
"""Builds Herdrbar's icons from herdr's logo (github.com/herdrdev/herdr, assets/logo.svg).

The logo is one potrace path drawn with transform="translate(0 512) scale(.1 -.1)" on a 512x512 canvas.

  make_icons.py menubar logo.svg Sources/Herdrbar/Resources/MenuBarIcon.pdf
      The ram's head, cropped, as a vector template glyph `--height` points tall.
  make_icons.py app logo.svg Icon.icns
      The whole logo in a macOS icon shape (an 824 px rounded square on a 1024 px canvas), at every size.
"""
import argparse
import re


def parse_path(d):
    """Yields absolute (op, points) from an SVG path, in the path's own coordinates."""
    tokens = re.findall(r"[MmLlCcSsHhVvZz]|-?\d*\.?\d+(?:e-?\d+)?", d)
    i, x, y, start, command, last_control = 0, 0.0, 0.0, (0.0, 0.0), None, None
    out = []

    def number():
        nonlocal i
        value = float(tokens[i])
        i += 1
        return value

    while i < len(tokens):
        if re.fullmatch(r"[A-Za-z]", tokens[i]):
            command = tokens[i]
            i += 1
            if command in "Zz":
                out.append(("h", []))
                x, y = start
                last_control = None
                continue
        relative = command.islower()
        op = command.upper()
        if op == "M":
            dx, dy = number(), number()
            x, y = (x + dx, y + dy) if relative else (dx, dy)
            start = (x, y)
            out.append(("m", [(x, y)]))
            command = "l" if relative else "L"  # extra pairs after a moveto are linetos
            last_control = None
        elif op == "L":
            dx, dy = number(), number()
            x, y = (x + dx, y + dy) if relative else (dx, dy)
            out.append(("l", [(x, y)]))
            last_control = None
        elif op == "H":
            v = number()
            x = x + v if relative else v
            out.append(("l", [(x, y)]))
            last_control = None
        elif op == "V":
            v = number()
            y = y + v if relative else v
            out.append(("l", [(x, y)]))
            last_control = None
        elif op in "CS":
            if op == "C":
                c1 = (number(), number())
                if relative:
                    c1 = (x + c1[0], y + c1[1])
            else:
                c1 = (2 * x - last_control[0], 2 * y - last_control[1]) if last_control else (x, y)
            c2, end = (number(), number()), (number(), number())
            if relative:
                c2, end = (x + c2[0], y + c2[1]), (x + end[0], y + end[1])
            out.append(("c", [c1, c2, end]))
            last_control, (x, y) = c2, end
    return out


def pdf_document(width, height, content):
    objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width:.3f} {height:.3f}] /Contents 4 0 R /Resources << >> >>",
        f"<< /Length {len(content.encode())} >>\nstream\n{content}endstream",
    ]
    body, offsets = "%PDF-1.4\n", []
    for number, obj in enumerate(objects, start=1):
        offsets.append(len(body.encode()))
        body += f"{number} 0 obj\n{obj}\nendobj\n"
    xref = len(body.encode())
    body += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n"
    body += "".join(f"{offset:010d} 00000 n \n" for offset in offsets)
    body += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
    return body


def logo_ops(d, to_pdf):
    ops = []
    for op, points in parse_path(d):
        coordinates = " ".join(f"{px:.3f} {py:.3f}" for px, py in map(to_pdf, points))
        ops.append(f"{coordinates} {op}".strip())
    return "\n".join(ops)


def rounded_rect(x, y, size, radius):
    k = 0.5523 * radius  # cubic approximation of a quarter circle
    r, x1, y1 = radius, x + size, y + size
    return (f"{x + r:.2f} {y:.2f} m {x1 - r:.2f} {y:.2f} l "
            f"{x1 - r + k:.2f} {y:.2f} {x1:.2f} {y + r - k:.2f} {x1:.2f} {y + r:.2f} c {x1:.2f} {y1 - r:.2f} l "
            f"{x1:.2f} {y1 - r + k:.2f} {x1 - r + k:.2f} {y1:.2f} {x1 - r:.2f} {y1:.2f} c {x + r:.2f} {y1:.2f} l "
            f"{x + r - k:.2f} {y1:.2f} {x:.2f} {y1 - r + k:.2f} {x:.2f} {y1 - r:.2f} c {x:.2f} {y + r:.2f} l "
            f"{x:.2f} {y + r - k:.2f} {x + r - k:.2f} {y:.2f} {x + r:.2f} {y:.2f} c h")


def menubar(d, out, crop, height):
    cx, cy, cw, ch = crop
    scale = height / ch

    def to_pdf(point):
        # potrace space -> canvas (y down) -> crop box -> PDF (y up), scaled to the target height.
        canvas_x, canvas_y = 0.1 * point[0], 512 - 0.1 * point[1]
        return ((canvas_x - cx) * scale, (cy + ch - canvas_y) * scale)

    width, height = cw * scale, ch * scale
    # Clip to the crop box, then fill with the nonzero rule, as the SVG does.
    content = f"0 0 {width:.3f} {height:.3f} re W n\n{logo_ops(d, to_pdf)}\nf\n"
    open(out, "w").write(pdf_document(width, height, content))


def app_icon(d, out):
    import os, subprocess, tempfile
    canvas, body, radius = 1024.0, 824.0, 185.0  # Apple's macOS icon grid
    inset, scale = (canvas - body) / 2, body / 512

    def to_pdf(point):
        return (inset + 0.1 * point[0] * scale, inset + 0.1 * point[1] * scale)

    shape = rounded_rect(inset, inset, body, radius)
    content = (f"q {shape} W n\n0.851 0.855 0.847 rg {inset} {inset} {body} {body} re f\n"  # #d9dad8
               f"0.188 0.204 0.220 rg\n{logo_ops(d, to_pdf)}\nf\nQ\n")                     # #303438
    with tempfile.TemporaryDirectory() as work:
        pdf = os.path.join(work, "icon.pdf")
        open(pdf, "w").write(pdf_document(canvas, canvas, content))
        iconset = os.path.join(work, "Icon.iconset")
        os.mkdir(iconset)
        for points in (16, 32, 128, 256, 512):
            for factor, suffix in ((1, ""), (2, "@2x")):
                png = os.path.join(iconset, f"icon_{points}x{points}{suffix}.png")
                pixels = str(points * factor)
                subprocess.run(["sips", "-s", "format", "png", "-z", pixels, pixels, pdf, "--out", png],
                               check=True, capture_output=True)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=["menubar", "app"])
    parser.add_argument("svg")
    parser.add_argument("out")
    parser.add_argument("--crop", nargs=4, type=float, default=[96, 118, 300, 262], metavar=("X", "Y", "W", "H"),
                        help="menubar: crop box in the logo's 512x512 canvas (y down)")
    parser.add_argument("--height", type=float, default=16, help="menubar: glyph height in points")
    args = parser.parse_args()
    svg = open(args.svg).read()
    d = re.search(r'<path[^>]* d="([^"]+)"', svg, re.S).group(1)
    if args.kind == "menubar":
        menubar(d, args.out, args.crop, args.height)
    else:
        app_icon(d, args.out)


if __name__ == "__main__":
    main()
