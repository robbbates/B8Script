"""Builds b8script.html, the web player: template.html with b8s.js and every program
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
    ('Tiny games: 140 characters', 'games/tweet140', ('games/README.md', '### `tweet140/`')),
    ('Tiny games: 280 characters', 'games/tweet280', ('games/README.md', '### `tweet280/`')),
]
# where the README says more than a line can
HOW = {'programs/MON.B8S': 'XXXX shows 16 bytes, Return the next 16, XXXX.YYYY a range, XXXX: hh hh '
                           'stores bytes, ? is the help, Q quits. XXXXR (machine code) can\'t run here.'}

# Each program's own keys, for the on-screen pad: (left side, right side), each a list of
# rows; a key is a character, or Spc, Ret, Bs or ^B, and . is a gap. Rows follow the
# program's layout (w a s d as a cross, TICTAC's 1-9 as its board). Programs that need
# typing use the phone's keyboard as well.
DIGITS = ['7 8 9', '4 5 6', '1 2 3', 'Bs 0 Ret']
KEYS = {
    'programs/MON.B8S': ([], ['Ret']),
    'programs/PI.B8S': ([], DIGITS),
    'programs/SIEVE.B8S': ([], DIGITS),
    'programs/TINYBAS.B8S': ([], ['^B', 'Ret']),
    'games/BATTLE.B8S': (['. w .', 'a s d'], ['t r', 'Spc q']),
    'games/BREAKOUT.B8S': (['a d'], ['Spc', 'q']),
    'games/CONNECT4.B8S': (['1 2', '3 4'], ['5 6', '7 y']),
    'games/DUNGEON.B8S': (['. w .', 'a s d'], ['p', 'q']),
    'games/FIFTEEN.B8S': (['. w .', 'a s d'], ['q']),
    'games/G2048.B8S': (['. w .', 'a s d'], ['q']),
    'games/GREED.B8S': (['q w e', 'a . d', 'z x c'], ['h', 'Q']),
    'games/HANGMAN.B8S': ([], ['y n']),
    'games/IDOL.B8S': (['c m y', 'k l f', 'r t v'], ['w ?', 's q', 'b x', 'Ret']),
    'games/KLONDIKE.B8S': (['1 2', '3 4', '5 6', '7 .'], ['d w', 'f q']),
    'games/LIFE.B8S': ([], ['Spc']),
    'games/LIGHTS.B8S': (['. w .', 'a s d'], ['Spc', 'n q']),
    'games/MASTER.B8S': (['y', 'n'], ['1 2 3', '4 5 6', 'Bs . Ret']),
    'games/MINES.B8S': (['. w .', 'a s d'], ['Spc f', 'q']),
    'games/QUBIC.B8S': ([], ['1 2', '3 4', 'Bs Ret']),
    'games/REVERSI.B8S': (['. w .', 'a s d'], ['Spc m', 'q']),
    'games/ROBOTS.B8S': (['q w e', 'a s d', 'z x c'], ['Spc t', 'Q']),
    'games/SUPERTRK.B8S': (['m j l', 'g p t', 'z h q'], DIGITS),
    'games/TETRIS.B8S': (['. w .', 'a s d'], ['Spc', 'q']),
    'games/TRADER.B8S': (['b s', 'f t', 'q .'], DIGITS),
    'games/WUMPUS.B8S': (['m', 's'], DIGITS),
}
d = 'games/tweet140'
KEYS.update({
    d + '/HILO.B8S': ([], DIGITS),
    d + '/LANDER.B8S': ([], ['7 8 9', '4 5 6', '1 2 3', '. 0 .']),
    d + '/LIGHTS14.B8S': (['a b c d e', 'f g h i j', 'k l m n o', 'p q r s t', 'u v w x y'], []),
    d + '/NIM.B8S': ([], ['1 2 3']),
    d + '/PIG.B8S': (['Spc'], ['h']),
    d + '/REFLEX.B8S': ([], ['Spc']),
    d + '/RPS.B8S': ([], ['1 2 3']),
    d + '/SIMON.B8S': ([], ['1 2 3 4', '5 6 7 8']),
    d + '/SKI.B8S': (['j'], ['l']),
    d + '/TRON.B8S': ([','], ['.']),
})
KEYS.update({
    'games/tweet280/BLACKJCK.B8S': (['h'], ['Spc']),
    'games/tweet280/BRKOUT28.B8S': (['j'], ['l']),
    'games/tweet280/COPTER.B8S': ([], ['Spc']),
    'games/tweet280/DUEL.B8S': ([','], ['.']),
    'games/tweet280/KINGDOM.B8S': ([], DIGITS),
    'games/tweet280/MASTER28.B8S': ([], ['1 2 3', '4 5 6', 'Bs . Ret']),
    'games/tweet280/MAZE.B8S': (['. i .', 'j k l'], []),
    'games/tweet280/NIM357.B8S': ([], ['1 2 3', '4 5 6', '7 . .']),
    'games/tweet280/SNAKE.B8S': ([','], ['.']),
    'games/tweet280/TICTAC.B8S': ([], ['1 2 3', '4 5 6', '7 8 9']),
})


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
            items.append(dict(id=pid, name=f + (' — ' + title if title else ''), info=info, src=src,
                              keys=KEYS.get(pid, ([], []))))
        groups.append(dict(group=name, items=items))
    page = open(os.path.join(HERE, 'template.html'), encoding='utf-8').read()
    core = open(os.path.join(HERE, 'b8s.js'), encoding='utf-8').read()
    progs = json.dumps(groups, ensure_ascii=True, separators=(',', ':')).replace('</', '<\\/')
    assert '</script' not in core.lower()
    missing = set(KEYS) - {it['id'] for g in groups for it in g['items']}
    assert not missing, missing
    return page.replace('/*PROGRAMS*/', progs, 1).replace('/*CORE*/', core, 1)


if __name__ == '__main__':
    text = build()
    if '--check' in sys.argv:
        ok = os.path.exists(OUT) and open(OUT, encoding='utf-8').read() == text
        print('b8script.html is', 'up to date' if ok else 'out of date: run web/build.py')
        sys.exit(0 if ok else 1)
    open(OUT, 'w', encoding='utf-8', newline='\n').write(text)
    print(f'wrote {OUT}: {len(text.encode()):,} bytes')
