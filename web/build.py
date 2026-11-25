"""Builds b8script.html, the web player: player.html with b8s.js and every program
in games/ and programs/ put inside it, so that the one file works on its own,
opened from disk or from any web server.

usage: build.py            write b8script.html
       build.py --check    only check that b8script.html is up to date

Each program's line of help comes from the tables in games/README.md and
programs/README.md: the bold name, what it is, and how to play."""
import os, re, sys, json, html

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, 'b8script.html')

# (group in the menu, folder, README section that describes it, or None)
GROUPS = [
    ('Programs', 'programs', ('programs/README.md', None)),
    ('Games', 'games', ('games/README.md', '## Full-size games')),
    ('Tiny games: 160 characters', 'games/b8sms', ('games/README.md', '### `b8sms/`')),
    ('Tiny games: 140 characters', 'games/tweet140', ('games/README.md', '### `b8sms/`')),
    ('Tiny games: 280 characters', 'games/tweet280', ('games/README.md', '### `tweet280/`')),
    ('Tiny games: longer', 'games/longer', ('games/README.md', '### `longer/`')),
]
# where the README says more than a line can
HOW = {'programs/MON.B8S': 'XXXX shows 16 bytes, Return the next 16, XXXX.YYYY a range, XXXX: hh hh '
                           'stores bytes, ? is the help, Q quits. XXXXR (machine code) can\'t run here.'}


def md(s):
    s = html.escape(s, quote=False)
    s = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', s)
    s = re.sub(r'`(.+?)`', r'<code>\1</code>', s)
    return re.sub(r'\[(.+?)\]\(.+?\)', r'\1', s)


def table(readme, heading):
    """{NAME.B8S: (title, what it is, how to play)} from the table under heading."""
    lines = open(os.path.join(ROOT, readme), encoding='utf-8').read().split('\n')
    if heading:
        lines = lines[next(i for i, l in enumerate(lines) if l.startswith(heading)) + 1:]
    rows = {}
    for l in lines:
        if heading and l.startswith('#'):
            break
        m = re.match(r'\| `([A-Z0-9]+\.B8S)` \| (.*) \| (.*) \|$', l)
        if m:
            what = m.group(2)
            t = re.match(r'\*\*(.+?)\*\*', what)
            rows[m.group(1)] = (t.group(1) if t else '', what, m.group(3))
    return rows


def build():
    groups = []
    for name, folder, (readme, heading) in GROUPS:
        rows = table(readme, heading)
        files = sorted(f for f in os.listdir(os.path.join(ROOT, folder)) if f.endswith('.B8S'))
        order = [f for f in rows if f in files] + [f for f in files if f not in rows]
        items = []
        for f in order:
            pid = f'{folder}/{f}'
            title, what, how = rows.get(f, ('', '', ''))
            how = HOW.get(pid, how)
            info = (md(what) + (' <i>' + md(how) + '</i>' if how else '')) if what else ''
            src = open(os.path.join(ROOT, folder, f), 'rb').read().decode('latin-1')
            items.append(dict(id=pid, name=f + (' — ' + title if title else ''), info=info, src=src))
        groups.append(dict(group=name, items=items))
    page = open(os.path.join(HERE, 'player.html'), encoding='utf-8').read()
    core = open(os.path.join(HERE, 'b8s.js'), encoding='utf-8').read()
    progs = json.dumps(groups, ensure_ascii=True, separators=(',', ':')).replace('</', '<\\/')
    assert '</script' not in core.lower()
    return page.replace('/*PROGRAMS*/', progs, 1).replace('/*CORE*/', core, 1)


if __name__ == '__main__':
    text = build()
    if '--check' in sys.argv:
        ok = os.path.exists(OUT) and open(OUT, encoding='utf-8').read() == text
        print('b8script.html is', 'up to date' if ok else 'out of date: run web/build.py')
        sys.exit(0 if ok else 1)
    open(OUT, 'w', encoding='utf-8', newline='\n').write(text)
    print(f'wrote {OUT}: {len(text.encode()):,} bytes')
