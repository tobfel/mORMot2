#!/usr/bin/env python3
"""Generate the static SVG charts of the FastCGI proxy benchmark report.

Each chart is written twice (light and dark) so that GitHub can switch with
<picture> and prefers-color-scheme. Pure Python, no dependency.
"""
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else 'charts'
os.makedirs(OUT, exist_ok=True)

THEMES = {
    'light': dict(surface='#fcfcfb', ink='#0b0b0b', ink2='#52514e', muted='#898781',
                  grid='#e1e0d9', axis='#c3c2b7',
                  s=['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4']),
    'dark': dict(surface='#1a1a19', ink='#f0efec', ink2='#c3c2b7', muted='#898781',
                 grid='#2c2c2a', axis='#383835',
                 s=['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181']),
}
# entity -> categorical slot, identical in every chart
SLOT = {'nginx': 0, 'mORMot': 1, 'mORMot + fix': 2, 'mORMot master + #810': 2,
        'mORMot before rework': 1, 'mORMot master': 2,
        'FrankenPHP classic': 3, 'FrankenPHP worker': 4}
FONT = 'system-ui, -apple-system, Segoe UI, sans-serif'


def esc(t):
    return str(t).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


class Svg:
    def __init__(self, w, h, th):
        self.w, self.h, self.t = w, h, th
        self.parts = [f'<rect width="{w}" height="{h}" rx="8" fill="{th["surface"]}"/>']

    def text(self, x, y, t, size=12, color=None, anchor='start', weight=400):
        self.parts.append(
            f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}" '
            f'font-weight="{weight}" fill="{color or self.t["ink2"]}" text-anchor="{anchor}">{esc(t)}</text>')

    def line(self, x1, y1, x2, y2, color, w=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ''
        self.parts.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
                          f'stroke="{color}" stroke-width="{w}"{d}/>')

    def vbar(self, x, base, top, w, color):
        # column growing up from base: 4px rounded data-end, square at the baseline
        h = base - top
        if h <= 0:
            return
        r = min(4, h, w / 2)
        self.parts.append(
            f'<path d="M{x:.1f},{base:.1f} V{top + r:.1f} Q{x:.1f},{top:.1f} {x + r:.1f},{top:.1f} '
            f'H{x + w - r:.1f} Q{x + w:.1f},{top:.1f} {x + w:.1f},{top + r:.1f} V{base:.1f} Z" fill="{color}"/>')

    def hbar(self, base, y, right, h, color):
        # bar growing right from base: rounded data-end, square at the baseline
        w = right - base
        if w <= 0:
            return
        r = min(4, w, h / 2)
        self.parts.append(
            f'<path d="M{base:.1f},{y:.1f} H{right - r:.1f} Q{right:.1f},{y:.1f} {right:.1f},{y + r:.1f} '
            f'V{y + h - r:.1f} Q{right:.1f},{y + h:.1f} {right - r:.1f},{y + h:.1f} H{base:.1f} Z" fill="{color}"/>')

    def legend(self, x, y, names):
        for n in names:
            self.parts.append(f'<rect x="{x}" y="{y - 9}" width="10" height="10" rx="2" '
                              f'fill="{self.t["s"][SLOT[n]]}"/>')
            self.text(x + 15, y, n, 12, self.t['ink2'])
            x += 15 + 7.2 * len(n) + 18

    def save(self, name, title, desc):
        body = '\n'.join(self.parts)
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
               f'viewBox="0 0 {self.w} {self.h}" role="img" aria-labelledby="t d">'
               f'<title id="t">{esc(title)}</title><desc id="d">{esc(desc)}</desc>\n{body}\n</svg>\n')
        with open(os.path.join(OUT, name), 'w') as f:
            f.write(svg)


def ticks(vmax, step):
    v, out = 0, []
    while v <= vmax + 1e-9:
        out.append(v)
        v += step
    return out


def grouped_columns(th, mode, name, title, subtitle, groups, series, values, vmax, step,
                    fmt, ref=None, ranges=None, desc=''):
    W, H = 760, 380
    L, R, T, B = 64, 20, 92, 52
    s = Svg(W, H, th)
    s.text(20, 30, title, 16, th['ink'], weight=600)
    s.text(20, 50, subtitle, 12, th['ink2'])
    s.legend(20, 74, series)
    pw, ph = W - L - R, H - T - B
    y = lambda v: T + ph - v / vmax * ph
    for v in ticks(vmax, step):
        s.line(L, y(v), W - R, y(v), th['grid'] if v else th['axis'])
        s.text(L - 8, y(v) + 4, fmt(v), 11, th['muted'], 'end')
    band = pw / len(groups)
    bw = min(24, (band * 0.7) / len(series))
    for gi, g in enumerate(groups):
        gx = L + gi * band + (band - len(series) * bw - (len(series) - 1) * 2) / 2
        for si, sn in enumerate(series):
            v = values[sn][gi]
            x = gx + si * (bw + 2)
            s.vbar(x, y(0), y(min(v, vmax)), bw, th['s'][SLOT[sn]])
            if ranges:
                lo, hi = ranges[sn][gi]
                cx = x + bw / 2
                s.line(cx, y(lo), cx, y(hi), th['ink2'], 1)
                s.line(cx - 3, y(hi), cx + 3, y(hi), th['ink2'], 1)
                s.line(cx - 3, y(lo), cx + 3, y(lo), th['ink2'], 1)
        s.text(L + gi * band + band / 2, H - B + 20, g, 12, th['ink2'], 'middle')
    if ref is not None:
        rv, rl, rc = ref
        s.line(L, y(rv), W - R, y(rv), th['s'][SLOT[rc]], 2, '6 4')
        s.text(W - R, y(rv) - 6, rl, 11, th['ink2'], 'end')
    s.save(f'{name}-{mode}.svg', title, desc or subtitle)


def hbars(th, mode, name, title, subtitle, groups, series, values, vmax, step, unit, desc='',
          vfmt=lambda v: f'{v:,} MB',
          entities=None):
    W = 760
    L, R, T = 190, 70, 92
    bh, gap, gpad = 14, 2, 18
    gh = len(series) * (bh + gap) - gap
    H = T + len(groups) * (gh + gpad) + 56
    s = Svg(W, H, th)
    s.text(20, 30, title, 16, th['ink'], weight=600)
    s.text(20, 50, subtitle, 12, th['ink2'])
    if not entities:
        s.legend(20, 74, series)
    pw = W - L - R
    x = lambda v: L + v / vmax * pw
    bottom = T + len(groups) * (gh + gpad) - gpad + 6
    for v in ticks(vmax, step):
        s.line(x(v), T - 6, x(v), bottom, th['grid'] if v else th['axis'])
        s.text(x(v), bottom + 16, f'{v:,}', 11, th['muted'], 'middle')
    s.text(L + pw, bottom + 34, unit, 11, th['muted'], 'end')
    for gi, g in enumerate(groups):
        gy = T + gi * (gh + gpad)
        s.text(L - 10, gy + gh / 2 + 4, g, 12, th['ink2'], 'end')
        for si, sn in enumerate(series):
            v = values[sn][gi]
            yy = gy + si * (bh + gap)
            ent = entities[gi] if entities else sn
            s.hbar(x(0), yy, x(v), bh, th['s'][SLOT[ent]])
            s.text(x(v) + 6, yy + bh - 3, vfmt(v), 11, th['ink'])
    s.save(f'{name}-{mode}.svg', title, desc or subtitle)


def lines(th, mode, name, title, subtitle, xs, series, values, vmax, step, xlabel, mark=None):
    W, H = 760, 340
    L, R, T, B = 64, 120, 92, 48
    s = Svg(W, H, th)
    s.text(20, 30, title, 16, th['ink'], weight=600)
    s.text(20, 50, subtitle, 12, th['ink2'])
    s.legend(20, 74, series)
    pw, ph = W - L - R, H - T - B
    xmax = xs[-1]
    X = lambda v: L + v / xmax * pw
    Y = lambda v: T + ph - v / vmax * ph
    for v in ticks(vmax, step):
        s.line(L, Y(v), L + pw, Y(v), th['grid'] if v else th['axis'])
        s.text(L - 8, Y(v) + 4, f'{v:,}', 11, th['muted'], 'end')
    for v in range(0, xmax + 1, 30):
        s.text(X(v), H - B + 18, f'{v} s', 11, th['muted'], 'middle')
    s.text(L + pw, H - 8, xlabel, 11, th['muted'], 'end')
    if mark:
        mx, ml = mark
        s.line(X(mx), T - 4, X(mx), T + ph, th['axis'], 1)
        s.text(X(mx) + 6, T + ph - 30, ml, 11, th['ink2'])
    for sn in series:
        pts = ' '.join(f'{X(a):.1f},{Y(b):.1f}' for a, b in zip(xs, values[sn]))
        s.parts.append(f'<polyline points="{pts}" fill="none" stroke="{th["s"][SLOT[sn]]}" '
                       f'stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>')
        peak = max(values[sn])
        i = values[sn].index(peak)
        s.parts.append(f'<circle cx="{X(xs[i]):.1f}" cy="{Y(peak):.1f}" r="4" '
                       f'fill="{th["s"][SLOT[sn]]}" stroke="{th["surface"]}" stroke-width="2"/>')
        s.text(X(90), Y(peak) - 10 if peak > vmax / 2 else Y(peak) - 10, f'{sn}: peak {peak:,} MB', 11, th['ink'], 'middle')
    s.save(f'{name}-{mode}.svg', title, subtitle)


for mode, th in THEMES.items():
    # 1. synthetic throughput relative to nginx (1 core each, x64mm)
    grouped_columns(
        th, mode, 'synthetic-throughput',
        'Throughput relative to nginx, by response size',
        '1 core each, php-fpm 8.5.12, FPC_X64MM; nginx = 100 % (dashed line)',
        ['11 B', '10 KB', '100 KB', '1 MB'], ['mORMot', 'mORMot + fix'],
        {'mORMot': [99, 97, 56, 22], 'mORMot + fix': [110, 98, 64, 22]},
        120, 20, lambda v: f'{v} %', ref=(100, 'nginx = 100 %', 'nginx'))
    # 2. peak memory of the front server
    hbars(
        th, mode, 'memory-peak',
        'Peak memory (RSS) of the front server',
        'nginx vs mORMot FastCGI proxy, with and without the fix (FPC_X64MM)',
        ['100 KB, 1 core', '1 MB, 1 core', '100 KB, 4 cores', 'Laravel, 4 cores'],
        ['nginx', 'mORMot', 'mORMot + fix'],
        {'nginx': [15, 15, 25, 27], 'mORMot': [806, 871, 1269, 104],
         'mORMot + fix': [12, 36, 15, 8]},
        1400, 200, 'MB')
    # 3. soak test RSS over time
    orig = [9, 848, 1151, 1284, 1370, 1398, 1404, 1427, 1432, 1435, 1436, 1437, 1437,
            1441, 1443, 1444, 1445, 1446, 1446, 14, 14, 14, 14]
    fix = [8, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 28, 28, 28,
           14, 14, 14, 14]
    lines(th, mode, 'soak-rss', 'Memory during a 3 minute mixed load',
          'c=200, 50 % hello, 25 % json, 10 % 100 KB, 10 % POST 64 KB, 5 % sleep; 0 errors',
          list(range(0, 230, 10)), ['mORMot', 'mORMot + fix'],
          {'mORMot': orig, 'mORMot + fix': fix}, 1600, 400, 'RSS in MB over time',
          mark=(180, 'load stops'))
    # 4. Laravel throughput, median of 3 runs with min-max range
    stacks = ['nginx', 'mORMot', 'mORMot + fix', 'FrankenPHP classic', 'FrankenPHP worker']
    runs = {
        'nginx': [(630.51, 648.34, 723.35), (518.52, 522.18, 576.79), (690.16, 778.95, 791.06)],
        'mORMot': [(669.70, 695.29, 734.43), (499.73, 535.20, 539.94), (699.67, 760.01, 800.07)],
        'mORMot + fix': [(680.74, 721.91, 731.52), (538.53, 551.09, 607.30), (712.74, 716.25, 794.08)],
        'FrankenPHP classic': [(549.60, 634.26, 682.56), (480.94, 506.30, 507.61), (616.47, 678.34, 726.15)],
        'FrankenPHP worker': [(940.82, 963.23, 1126.82), (757.91, 814.36, 842.70), (1178.68, 1287.52, 1314.26)],
    }
    grouped_columns(
        th, mode, 'laravel-throughput', 'Laravel 12 without database: requests per second',
        '3 cores per stack, 12 PHP workers, c=32; bar = median of 3 runs, whisker = min-max',
        ['JSON API (13.7 KB)', 'Blade page (14.5 KB)', 'Welcome page (80 KB)'], stacks,
        {k: [r[1] for r in v] for k, v in runs.items()}, 1400, 200, lambda v: f'{v:,}',
        ranges={k: [(r[0], r[2]) for r in v] for k, v in runs.items()})
    # 5. Laravel memory under load: whole stack PSS
    hbars(
        th, mode, 'laravel-memory',
        'Laravel: memory of the whole stack under load (PSS)',
        'front server + PHP workers, welcome page at c=256; PSS shares opcache memory fairly',
        ['nginx + php-fpm', 'mORMot + php-fpm', 'mORMot + fix + php-fpm',
         'FrankenPHP classic', 'FrankenPHP worker'],
        ['nginx'],
        {'nginx': [74, 157, 64, 118, 136]}, 200, 50, 'MB',
        entities=['nginx', 'mORMot', 'mORMot + fix', 'FrankenPHP classic', 'FrankenPHP worker'])

# update 2026-11-19: upstream master 9d39b36 + PR #810 (FastCgiIndex front controller)
STACKS810 = ['nginx', 'mORMot master + #810', 'FrankenPHP classic', 'FrankenPHP worker']
RUNS810 = {
    'nginx': [(821.56, 826.11, 843.28), (641.38, 658.39, 699.21), (871.74, 877.86, 889.35)],
    'mORMot master + #810': [(787.88, 832.26, 862.00), (653.84, 667.68, 687.43), (860.66, 876.57, 905.53)],
    'FrankenPHP classic': [(684.99, 708.91, 748.70), (573.89, 574.58, 585.24), (794.78, 811.74, 816.92)],
    'FrankenPHP worker': [(1098.86, 1137.07, 1218.24), (878.79, 879.16, 926.98), (1429.78, 1469.75, 1488.38)],
}
for mode, th in THEMES.items():
    grouped_columns(
        th, mode, 'laravel-810-throughput',
        'Laravel 12 with the front controller (PR #810): requests per second',
        'pretty URLs on every stack; 3 cores, 12 PHP workers, c=32; median of 3 runs, whisker = min-max',
        ['JSON API (13.7 KB)', 'Blade page (14.5 KB)', 'Welcome page (80 KB)'], STACKS810,
        {k: [r[1] for r in v] for k, v in RUNS810.items()}, 1600, 200, lambda v: f'{v:,}',
        ranges={k: [(r[0], r[2]) for r in v] for k, v in RUNS810.items()})
    hbars(
        th, mode, 'laravel-810-static', 'Static files from public/ (robots.txt, 24 B)',
        'served by the front server itself, c=64, single wrk thread; nginx default config (no open_file_cache)',
        ['nginx', 'mORMot master + #810', 'FrankenPHP classic', 'FrankenPHP worker'], ['nginx'],
        {'nginx': [111630, 158810, 39449, 41211]}, 180000, 30000, 'req/s',
        vfmt=lambda v: f'{v:,} req/s', entities=STACKS810)
    hbars(
        th, mode, 'laravel-810-memory', 'Laravel: memory of the whole stack under load (PSS)',
        'front server + PHP workers, welcome page at c=256; PSS shares opcache memory fairly',
        ['nginx + php-fpm', 'mORMot + php-fpm', 'FrankenPHP classic', 'FrankenPHP worker'], ['nginx'],
        {'nginx': [75, 65, 120, 131]}, 150, 25, 'MB', entities=STACKS810)

# update 2026-11-21: PHP 8.6.0, Laravel 13.43, FrankenPHP v1.14.0, mORMot master 883701d
STACKS86 = ['nginx', 'mORMot master', 'FrankenPHP classic', 'FrankenPHP worker']
RUNS86 = {  # (min, median, max); nginx and mORMot: 8 runs, FrankenPHP: 3 runs
    'nginx': [(539.44, 658.1, 755.39), (453.58, 484.3, 557.77), (624.62, 718.9, 789.28)],
    'mORMot master': [(585.58, 610.1, 729.48), (409.02, 467.9, 560.98), (600.44, 704.6, 789.65)],
    'FrankenPHP classic': [(532.30, 537.45, 602.22), (439.50, 470.75, 476.41), (569.40, 635.75, 667.55)],
    'FrankenPHP worker': [(853.03, 934.49, 939.12), (654.48, 691.71, 729.18), (1114.57, 1117.40, 1232.33)],
}
for mode, th in THEMES.items():
    grouped_columns(
        th, mode, 'php86-laravel-throughput',
        'PHP 8.6.0 + Laravel 13: requests per second',
        '3 cores, 12 PHP workers, c=32, pretty URLs; median, whisker = min-max (nginx/mORMot 8 runs, FrankenPHP 3)',
        ['JSON API (13.7 KB)', 'Blade page (14.5 KB)', 'Welcome page (70 KB)'], STACKS86,
        {k: [r[1] for r in v] for k, v in RUNS86.items()}, 1400, 200, lambda v: f'{v:,.0f}',
        ranges={k: [(r[0], r[2]) for r in v] for k, v in RUNS86.items()})
    grouped_columns(
        th, mode, 'php86-synthetic-throughput',
        'Throughput relative to nginx, before and after the rework of master',
        'PHP 8.6.0, 1 core each, FPC_X64MM, median of 3 runs; nginx = 100 % (dashed line)',
        ['11 B', '10 KB', '100 KB', '1 MB'], ['mORMot before rework', 'mORMot master'],
        {'mORMot before rework': [110, 91, 63, 23], 'mORMot master': [114, 105, 102, 28]},
        120, 20, lambda v: f'{v} %', ref=(100, 'nginx = 100 %', 'nginx'))
    hbars(
        th, mode, 'php86-front-cpu', 'Laravel: CPU of the front server per request',
        'PHP 8.6.0 + Laravel 13, JSON API at c=32, median of 4 runs (one CPU tick = 10 ms, so about +-10 us)',
        ['nginx', 'mORMot before rework', 'mORMot master'], ['nginx'],
        {'nginx': [234, 225, 318]}, 400, 100, 'us per request',
        vfmt=lambda v: f'{v} us', entities=['nginx', 'mORMot before rework', 'mORMot master'])

print('charts written to', OUT)
