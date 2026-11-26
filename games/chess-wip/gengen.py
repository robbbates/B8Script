"""Emit the generator words H J A B for a configuration:
   border: border squares (8) instead of off-board tests (s&136)
   side:   per-side tests (8> / 8<) instead of c@^8>"""
def gens(border=True, side=True):
    OB = '' if border else ':h@&\\'
    def tests(white):
        if side:
            return ('8>', '8>') if white else ('8<', '8^8>')
        return ('c@^8>', 'c@^8>')
    out = []
    for white in (True, False):
        rc, sc = tests(white)       # ray-end test (v nonzero), step test (v may be 0)
        base = 0 if white else 64
        sgn = '+' if white else '-'
        neg = '-' if white else '+'
        st = 'S' if white else 'T'
        def L(off, body):
            return f'\n l@{base+off}+:@:(1(:2+@k!@\n   {body}\n 2+:@:)0);;'.replace('l@0+', 'l@')
        def fray(o, last):   # full ray
            c = '' if last else ':'
            if border:
                return f'{c}1({o}:k@+,:\;:2_!1){rc}(C 0);'
            return f'{c}1({o}:h@&\\:k@+,:({rc}(C 0)1 0)\\:2_!1);'
        def cray(o, last):   # captures-only ray
            c = '' if last else ':'
            if border:
                return f'{c}1({o}:k@+,:\;1){rc}(C 0);'
            return f'{c}1({o}:h@&\\:k@+,:({rc}(C 0)1 0)\\1);'
        Q = ['15+', '17+', '15-', '17-', '1+', '1-', '16+', '16-']
        R = ['1+', '1-', '16+', '16-']; Bd = ['15+', '17+', '15-', '17-']
        ray = lambda f, ds: ' '.join(f(o, i == len(ds)-1) for i, o in enumerate(ds))
        KD = ['1+', '2-', '17+', '32-', '31+', '30-', '32+', '34-']
        ND = ['33+', '2-', '13-', '4-', '28-', '4-', '13-', '2-']
        if white:
            castle = 'r@3&( r@1&( b@5+,b@6+,|0=( 1030 2_! 0) 0) r@2&( b@1+,b@2+,|b@3+,|0=( 1026 2_! 0) 0) 0)'
        else:
            castle = 'r@12&( r@4&( b@117+,b@118+,|0=( 29814 2_! 0) 0) r@8&( b@113+,b@114+,|b@115+,|0=( 29810 2_! 0) 0) 0)'
        fk = ' '.join(f'{d}{st}' for d in KD) + '; ' + castle + ';'
        fn = ' '.join(f'{d}{st}' for d in ND) + ';'
        dbl = '32' if white else '80'
        if border:
            pc = f':15{sgn}:k@+,{sc}(C 0); 17{sgn}:k@+,{sc}(C 0);'
        else:
            pc = f':15{sgn}:h@&0=(:k@+,{sc}(C 0)0); 17{sgn}:h@&0=(:k@+,{sc}(C 0)0);'
        fp = f':16{sgn}:k@+,0=(:2_!:112&{dbl}=(16{sgn}:k@+,0=(:2_!0)0)0); ' + pc
        H = (f'[{"H" if white else "J"} l@{base}+:@:2+@k!@ {fk}'.replace('l@0+', 'l@')
             + L(2, ray(fray, Q)) + L(22, ray(fray, R)) + L(28, ray(fray, Bd)) + L(34, fn) + L(40, fp) + ']\n')
        if border:
            cs = lambda d: f'{d}:k@+,{sc}(C 0)'
        else:
            cs = lambda d: f'{d}:h@&0=(:k@+,{sc}(C 0)0)'
        ck = ''.join(cs(d) for d in KD) + ';;'
        cn = ''.join(cs(d) for d in ND) + ';'
        A = (f'[{"A" if white else "B"} l@{base}+:@:2+@k!@ {ck}'.replace('l@0+', 'l@')
             + L(2, ray(cray, Q)) + L(22, ray(cray, R)) + L(28, ray(cray, Bd)) + L(34, cn) + L(40, pc) + ']\n')
        out += [H, A]
    S = f'[S {OB}:k@+,:({tests(True)[0]}(C 0)1 0)\\:2_!]\n[T {OB}:k@+,:({tests(False)[0]}(C 0)1 0)\\:2_!]\n'
    return S, ''.join(out)

def build(src, border=True, side=True):
    import re
    S, G = gens(border, side)
    s = src
    s = re.sub(r'\[S [^\n]*\]\n\[T [^\n]*\]\n', lambda m: S, s)
    # replace H J A B definitions
    for w in 'HJAB':
        i = s.index('[' + w + ' l@')
        depth = 0; j = i
        while True:
            c = s[j]
            if c == '"':
                j = s.index('"', j + 1)
            elif c in '([': depth += 1
            elif c in ')]':
                depth -= 1
                if depth == 0: break
            j += 1
        s = s[:i] + ('{%s}' % w) + s[j+1:]
    parts = {}
    for blk in G.strip().split('\n['):
        blk = blk if blk.startswith('[') else '[' + blk
        parts[blk[1]] = blk.strip()
    for w in 'HJAB':
        s = s.replace('{%s}' % w, parts[w])
    if not border:
        s = s.replace('256_f!', '256_f! 136h!')
        # E: ep squares need off-board tests
        s = s.replace('p@15+:b@+,9=(', 'p@15+:h@&0=(:b@+,9=(').replace('p@17+:b@+,9=(', 'p@17+:h@&0=(:b@+,9=(')
        s = s.replace('p@15-:b@+,1=(', 'p@15-:h@&0=(:b@+,1=(').replace('p@17-:b@+,1=(', 'p@17-:h@&0=(:b@+,1=(')
        s = s.replace('q@@2_!q@!q@2+q! 0);', 'q@@2_!q@!q@2+q! 0)0);')
    return s

if __name__ == '__main__':
    import sys
    src = open(sys.argv[1]).read()
    for b in (True, False):
        for sd in (True, False):
            n = f'var_{"border" if b else "test"}_{"side" if sd else "shared"}.txt'
            open(n, 'w').write(build(src, b, sd))
            print(n)
