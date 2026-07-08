#!/usr/bin/env python3
"""Render assignment topology diagrams to PNG."""

from __future__ import annotations

import math
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
W, H = 2400, 1350

# Refined palette — soft fills, saturated borders
BG_TOP = (241, 245, 252)
BG_BOT = (226, 232, 240)
TEXT = (15, 23, 42)
MUTED = (71, 85, 105)
SHADOW = (100, 116, 139, 60)

PALETTE = {
    "k8s": (224, 236, 255),
    "k8s_border": (37, 99, 235),
    "k8s_dark": (30, 64, 175),
    "ovs": (209, 250, 229),
    "ovs_border": (5, 150, 105),
    "ovs_dark": (4, 120, 87),
    "vm": (254, 243, 199),
    "vm_border": (217, 119, 6),
    "vm_dark": (180, 83, 9),
    "pod": (237, 233, 254),
    "pod_border": (124, 58, 237),
    "pod_dark": (109, 40, 217),
    "dpu": (254, 226, 226),
    "dpu_border": (220, 38, 38),
    "dpu_dark": (185, 28, 28),
    "hw": (255, 241, 242),
    "hw_border": (225, 29, 72),
    "hw_dark": (190, 18, 60),
    "arrow": (51, 65, 85),
    "accent": (37, 99, 235),
    "white": (255, 255, 255),
}

# Font sizes (scaled up ~35–40%)
FS_TITLE = 48
FS_SUBTITLE = 26
FS_REGION = 28
FS_LABEL = 30
FS_DETAIL = 22
FS_ARROW = 20
FS_CALLOUT = 24
FS_FOOTER = 22


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def _gradient_bg() -> Image.Image:
    img = Image.new("RGB", (W, H), BG_TOP)
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / max(H - 1, 1)
        r = int(BG_TOP[0] * (1 - t) + BG_BOT[0] * t)
        g = int(BG_TOP[1] * (1 - t) + BG_BOT[1] * t)
        b = int(BG_TOP[2] * (1 - t) + BG_BOT[2] * t)
        draw.line([(0, y), (W, y)], fill=(r, g, b))
    return img


def new_canvas() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = _gradient_bg()
    return img, ImageDraw.Draw(img)


def _text_size(draw: ImageDraw.ImageDraw, text: str, font) -> tuple[int, int]:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[2] - bbox[0], bbox[3] - bbox[1]


def _shadow_layer(xy: tuple[int, int, int, int], radius: int = 20, offset: int = 6) -> Image.Image:
    x1, y1, x2, y2 = xy
    pad = offset + 12
    layer = Image.new("RGBA", (x2 - x1 + pad * 2, y2 - y1 + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle(
        (pad, pad + offset, x2 - x1 + pad, y2 - y1 + pad + offset),
        radius=radius,
        fill=SHADOW,
    )
    return layer.filter(ImageFilter.GaussianBlur(radius=8))


def _paste_shadow(img: Image.Image, xy: tuple[int, int, int, int], radius: int = 20) -> None:
    x1, y1, x2, y2 = xy
    shadow = _shadow_layer(xy, radius=radius)
    img.paste(shadow, (x1 - 12, y1 - 6), shadow)


def header_bar(draw: ImageDraw.ImageDraw, title: str, subtitle: str = "") -> None:
    draw.rounded_rectangle((48, 36, W - 48, 168), radius=24, fill=PALETTE["white"], outline=(203, 213, 225), width=2)
    accent_h = 8
    draw.rounded_rectangle((48, 36, W - 48, 36 + accent_h), radius=24, fill=PALETTE["accent"])
    draw.rectangle((48, 36 + accent_h // 2, W - 48, 36 + accent_h), fill=PALETTE["accent"])

    f_title = load_font(FS_TITLE, bold=True)
    f_sub = load_font(FS_SUBTITLE)
    draw.text((80, 58), title, fill=TEXT, font=f_title)
    if subtitle:
        draw.text((80, 118), subtitle, fill=MUTED, font=f_sub)


def box(
    img: Image.Image,
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int, int, int],
    label: str,
    fill_key: str,
    detail: str | None = None,
    radius: int = 20,
) -> None:
    _paste_shadow(img, xy, radius=radius)
    x1, y1, x2, y2 = xy
    fill = PALETTE[fill_key]
    border = PALETTE.get(f"{fill_key}_border", (148, 163, 184))
    dark = PALETTE.get(f"{fill_key}_dark", border)

    draw.rounded_rectangle(xy, radius=radius, fill=fill, outline=border, width=3)

    # Top accent stripe
    stripe_h = 10
    draw.rounded_rectangle((x1 + 2, y1 + 2, x2 - 2, y1 + stripe_h + 2), radius=18, fill=dark)
    draw.rectangle((x1 + 2, y1 + stripe_h - 4, x2 - 2, y1 + stripe_h + 2), fill=dark)

    f_label = load_font(FS_LABEL, bold=True)
    f_detail = load_font(FS_DETAIL)
    tw, th = _text_size(draw, label, f_label)
    cx = (x1 + x2) // 2
    line_h = FS_DETAIL + 10

    if detail:
        lines = detail.split("\n")
        block_h = th + 14 + len(lines) * line_h
        ty = (y1 + y2 - block_h) // 2 + 6
        draw.text((cx - tw // 2, ty), label, fill=TEXT, font=f_label)
        for i, line in enumerate(lines):
            lw, _ = _text_size(draw, line, f_detail)
            draw.text((cx - lw // 2, ty + th + 14 + i * line_h), line, fill=MUTED, font=f_detail)
    else:
        draw.text((cx - tw // 2, (y1 + y2 - th) // 2 + 4), label, fill=TEXT, font=f_label)


def region(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int, int, int],
    label: str,
    color: tuple[int, int, int],
    fill: tuple[int, int, int, int] | None = None,
) -> None:
    x1, y1, x2, y2 = xy
    if fill:
        overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        od = ImageDraw.Draw(overlay)
        od.rounded_rectangle(xy, radius=24, fill=fill)
        # caller must paste — we'll draw semi-transparent via lighter fill trick
    draw.rounded_rectangle(xy, radius=24, outline=color, width=3)
    # Label pill
    f = load_font(FS_REGION, bold=True)
    tw, th = _text_size(draw, label, f)
    pill_x1, pill_y = x1 + 24, y1 + 16
    pill_x2 = pill_x1 + tw + 36
    draw.rounded_rectangle((pill_x1, pill_y, pill_x2, pill_y + th + 20), radius=14, fill=color)
    draw.text((pill_x1 + 18, pill_y + 8), label, fill=PALETTE["white"], font=f)


def arrow(
    draw: ImageDraw.ImageDraw,
    start: tuple[int, int],
    end: tuple[int, int],
    label: str | None = None,
    dashed: bool = False,
    width: int = 4,
) -> None:
    color = PALETTE["arrow"]
    if dashed:
        _dashed_line(draw, start, end, color, width=width)
    else:
        draw.line([start, end], fill=color, width=width)
    _arrowhead(draw, start, end, color, size=16)
    if label:
        f = load_font(FS_ARROW, bold=True)
        mx = (start[0] + end[0]) // 2
        my = (start[1] + end[1]) // 2 - 24
        lw, lh = _text_size(draw, label, f)
        pad = 8
        draw.rounded_rectangle(
            (mx - lw // 2 - pad, my - pad, mx + lw // 2 + pad, my + lh + pad),
            radius=10,
            fill=PALETTE["white"],
            outline=(203, 213, 225),
            width=2,
        )
        draw.text((mx - lw // 2, my), label, fill=MUTED, font=f)


def _arrowhead(
    draw: ImageDraw.ImageDraw,
    start: tuple[int, int],
    end: tuple[int, int],
    color: tuple[int, int, int],
    size: int = 16,
) -> None:
    angle = math.atan2(end[1] - start[1], end[0] - start[0])
    x, y = end
    p1 = (x - size * math.cos(angle - 0.35), y - size * math.sin(angle - 0.35))
    p2 = (x - size * math.cos(angle + 0.35), y - size * math.sin(angle + 0.35))
    draw.polygon([end, p1, p2], fill=color)


def _dashed_line(
    draw: ImageDraw.ImageDraw,
    start: tuple[int, int],
    end: tuple[int, int],
    color: tuple[int, int, int],
    width: int = 3,
) -> None:
    x1, y1 = start
    x2, y2 = end
    length = math.hypot(x2 - x1, y2 - y1)
    if length == 0:
        return
    dash, gap = 14, 10
    dx, dy = (x2 - x1) / length, (y2 - y1) / length
    pos = 0.0
    while pos < length:
        seg = min(dash, length - pos)
        sx, sy = x1 + dx * pos, y1 + dy * pos
        ex, ey = x1 + dx * (pos + seg), y1 + dy * (pos + seg)
        draw.line([(sx, sy), (ex, ey)], fill=color, width=width)
        pos += dash + gap


def callout_box(draw: ImageDraw.ImageDraw, xy: tuple[int, int, int, int], lines: list[str]) -> None:
    x1, y1, x2, y2 = xy
    draw.rounded_rectangle(xy, radius=20, fill=(239, 246, 255), outline=PALETTE["accent"], width=3)
    f = load_font(FS_CALLOUT)
    for i, line in enumerate(lines):
        draw.text((x1 + 28, y1 + 24 + i * (FS_CALLOUT + 14)), line, fill=TEXT, font=f)


def diagram_topology() -> Image.Image:
    img, draw = new_canvas()
    header_bar(
        draw,
        "Figure 1 — Implemented software datapath topology",
        "KinD · Multus NAD · OVS-CNI · br1 (VLAN 100) · 2 CirrOS VMs + verification pod",
    )
    region(draw, (48, 200, W - 48, H - 48), "Kubernetes node (KinD control-plane)", PALETTE["k8s_border"])
    region(draw, (88, 320, W - 88, H - 100), "Open vSwitch bridge br1 — VLAN 100 access ports", PALETTE["ovs_border"])

    box(img, draw, (120, 420, 480, 600), "vm-a", "vm", "CirrOS KubeVirt\n10.10.0.10\n02:a0:00:00:00:0a\neth1 → OVS-CNI")
    box(img, draw, (900, 420, 1260, 600), "vm-b", "vm", "CirrOS KubeVirt\n10.10.0.11\n02:a0:00:00:00:0b\neth1 → OVS-CNI")
    box(img, draw, (1680, 420, 2040, 600), "ovs-ping-pod", "pod", "Alpine verification\n10.10.0.20\n02:a0:00:00:00:14\nnet1 → OVS-CNI")

    box(img, draw, (120, 720, 480, 880), "virt-launcher", "k8s", "tap + in-pod bridge\nveth → br1 port 1")
    box(img, draw, (900, 720, 1260, 880), "virt-launcher", "k8s", "tap + in-pod bridge\nveth → br1 port 2")
    box(img, draw, (1680, 720, 2040, 880), "pod netns", "k8s", "Multus secondary\nveth → br1 port 3")

    arrow(draw, (300, 600), (300, 720), width=5)
    arrow(draw, (1080, 600), (1080, 720), width=5)
    arrow(draw, (1860, 600), (1860, 720), width=5)

    box(img, draw, (780, 980, 1380, 1120), "br1 megaflow cache + FDB", "ovs", "5 OpenFlow rules · 20 kernel megaflows\npush_vlan(100) / pop_vlan on access ports")
    arrow(draw, (300, 880), (900, 1030), width=5)
    arrow(draw, (1080, 880), (1080, 980), width=5)
    arrow(draw, (1860, 880), (1380, 1030), width=5)

    box(img, draw, (1480, 220, 2140, 340), "Default CNI: kindnet (eth0)", "k8s", "Cluster IP / DNS — separate from br1 L2 domain")
    return img


def diagram_packet_walk() -> Image.Image:
    img, draw = new_canvas()
    header_bar(
        draw,
        "Figure 2 — Software packet walk (vm-a → ovs-ping-pod)",
        "Every hop except the guest app runs on the host CPU until the frame hits br1 megaflows",
    )
    callout_box(
        draw,
        (80, 200, W - 80, 340),
        [
            "Evidence: ping_results.txt (0% loss) · verification_flows.json datapath_flows[]",
            "in_port(2), eth(src=02:a0:00:00:00:0a, dst=02:a0:00:00:00:14) → push_vlan(100) → output:4",
        ],
    )

    y1, y2 = 500, 680
    nodes = [
        (80, y1, 280, y2, "Guest app\n(ping)", "vm"),
        (320, y1, 520, y2, "virtio-net\n(CirrOS)", "vm"),
        (560, y1, 760, y2, "QEMU\nvhost-net", "k8s"),
        (800, y1, 1000, y2, "tap0\nvirt-launcher", "k8s"),
        (1040, y1, 1240, y2, "in-pod\nbridge", "k8s"),
        (1280, y1, 1480, y2, "veth\n(OVS-CNI)", "ovs"),
        (1520, 460, 1820, 720, "OVS br1\nOpenFlow +\nmegaflow cache\nVLAN 100", "ovs"),
        (1860, y1, 2060, y2, "veth\npeer", "ovs"),
    ]
    for x1, ny1, x2, ny2, label, kind in nodes:
        box(img, draw, (x1, ny1, x2, ny2), label.split("\n")[0], kind, "\n".join(label.split("\n")[1:]) or None)

    cy = (y1 + y2) // 2
    for i in range(len(nodes) - 1):
        x2 = nodes[i][2]
        x1n = nodes[i + 1][0]
        arrow(draw, (x2 + 6, cy), (x1n - 6, cy), width=5)

    box(img, draw, (1520, 820, 1820, 980), "ovs-ping-pod net1", "pod", "10.10.0.20 receives\nICMP echo (ttl=64)")
    arrow(draw, (1670, 720), (1670, 820), "L2 forward", width=5)
    return img


def diagram_bf3_arch() -> Image.Image:
    img, draw = new_canvas()
    header_bar(
        draw,
        "Figure 3 — BlueField-3 offload architecture",
        "Same Kubernetes intent; veth ports become VF representors on the eSwitch",
    )
    region(draw, (48, 200, W - 48, H - 48), "BlueField-3 DPU (switchdev + OVS-DOCA)", PALETTE["dpu_border"])
    box(img, draw, (100, 300, 440, 460), "Host / KinD", "k8s", "KubeVirt · Multus\nunchanged CRDs")
    box(img, draw, (100, 540, 440, 740), "ovs-vswitchd", "dpu", "Arm cores\nhw-offload=true\nfirst-packet only")

    region(draw, (520, 260, W - 80, H - 80), "ConnectX-7 eSwitch ASIC (TCAM pipeline)", PALETTE["hw_border"])
    box(img, draw, (580, 360, 880, 520), "pf0vf0 repr.", "ovs", "control mirror\nvm-a port")
    box(img, draw, (980, 360, 1280, 520), "pf0vf1 repr.", "ovs", "control mirror\nvm-b port")
    box(img, draw, (1380, 360, 1680, 520), "pf0vf2 repr.", "ovs", "control mirror\npod port")
    box(img, draw, (900, 620, 1360, 840), "eSwitch hardware\nflow tables", "hw", "VLAN 100 tag/pop\noffloaded:yes, dp:doca\nsame OpenFlow shape")

    box(img, draw, (580, 980, 880, 1120), "VF → vm-a", "vm", "SR-IOV assign")
    box(img, draw, (980, 980, 1280, 1120), "VF → vm-b", "vm", "SR-IOV assign")
    box(img, draw, (1380, 980, 1680, 1120), "VF → pod", "pod", "vDPA attach")

    arrow(draw, (270, 460), (580, 420), "install flow", dashed=True, width=4)
    arrow(draw, (270, 640), (730, 680), "OpenFlow via repr.", dashed=True, width=4)
    arrow(draw, (730, 520), (1050, 620), dashed=True, width=3)
    arrow(draw, (1130, 520), (1050, 620), dashed=True, width=3)
    arrow(draw, (1530, 520), (1050, 620), dashed=True, width=3)
    arrow(draw, (730, 840), (730, 980), width=5)
    arrow(draw, (1130, 840), (1130, 980), width=5)
    arrow(draw, (1530, 840), (1530, 980), width=5)
    return img


def diagram_vdpa_walk() -> Image.Image:
    img, draw = new_canvas()
    header_bar(
        draw,
        "Figure 4 — BlueField-3 vDPA packet walk (vm-a → ovs-ping-pod)",
        "Guest keeps virtio-net; data plane bypasses host kernel after flow install",
    )
    box(img, draw, (80, 480, 360, 680), "vm-a guest", "vm", "ping app\nvirtio-net driver")
    box(img, draw, (420, 480, 680, 680), "vDPA / VF", "dpu", "doorbell + DMA\nguest RAM")
    region(draw, (740, 340, 1680, 860), "BlueField-3 silicon", PALETTE["hw_border"])
    box(img, draw, (800, 420, 1620, 580), "eSwitch match", "hw", "eth(src=0a, dst=14) · VLAN 100 in HW · offloaded flow")
    box(img, draw, (800, 640, 1620, 780), "ConnectX virtio engine", "hw", "zero host copies post-install")
    box(img, draw, (1740, 480, 2040, 680), "VF / vDPA", "dpu", "pod endpoint")
    box(img, draw, (2080, 480, 2320, 680), "ovs-ping-pod", "pod", "net1\n10.10.0.20")

    cy = 580
    arrow(draw, (360, cy), (420, cy), "virtqueue", width=5)
    arrow(draw, (680, cy), (800, 500), "DMA", width=5)
    arrow(draw, (1620, 500), (1740, cy), "forward", width=5)
    arrow(draw, (2040, cy), (2080, cy), width=5)

    box(img, draw, (80, 920, 900, 1080), "Control plane (once at boot)", "k8s", "KubeVirt + Multus + vDPA CNI → /dev/vhost-vdpa-N")
    arrow(draw, (490, 920), (1200, 860), "configures", dashed=True, width=4)

    f = load_font(FS_FOOTER)
    footer = "Same CirrOS image · same MAC pinning · verification adds offloaded:yes marker in dpctl/dump-flows"
    draw.text((80, 1180), footer, fill=MUTED, font=f)
    return img


def main() -> None:
    outputs = {
        "implemented_software_datapath_topology.png": diagram_topology(),
        "software_packet_walk.png": diagram_packet_walk(),
        "bluefield3_offload_architecture.png": diagram_bf3_arch(),
        "bluefield3_vdpa_packet_walk.png": diagram_vdpa_walk(),
    }
    for name, image in outputs.items():
        path = ROOT / name
        image.save(path, "PNG", optimize=True)
        print(f"wrote {path} ({image.size[0]}x{image.size[1]})")


if __name__ == "__main__":
    main()
