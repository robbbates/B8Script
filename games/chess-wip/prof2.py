"""prof2.py PROG.b8s TAIL [N]: executed chars per word (stripped program), and hot spots."""
import sys, collections
import os; sys.path.insert(0,os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','B8Script-interpreters','testing'))
from ref import Ref
src=open(sys.argv[1],'rb').read()
prog=src+sys.argv[2].encode()
C=collections.Counter()
class P(Ref):
    def step(self):
        C[self.ip]+=1; super().step()
r=P(prog); r.run(2_000_000_000)
base=r.prog_at
# map offsets to word
owner=['top']*len(src); i=0; stack=[]
while i<len(src):
    c=src[i]
    if c==34:
        j=i+1
        while src[j]!=34: j+=2 if src[j]==47 else 1
        for k in range(i,j+1): owner[k]=stack[-1] if stack else 'top'
        i=j+1; continue
    if c==91:
        nm=chr(src[i+1]) if 65<=src[i+1]<=90 else ('anon' if src[i+1]==32 else chr(src[i+1]))
        stack.append(nm)
    if c in (40,): stack.append(stack[-1] if stack else 'top')
    owner[i]=stack[-1] if stack else 'top'
    if c in (41,93) and stack: stack.pop()
    i+=1
per=collections.Counter()
for a,n in C.items():
    o=a-base
    per[owner[o] if 0<=o<len(src) else 'tail']+=n
tot=sum(C.values()); N=int(sys.argv[3]) if len(sys.argv)>3 else 1
print('total', tot, 'per run', tot//N)
for k,n in per.most_common(): print(f'  {k:5} {n//N:7} {100*n/tot:5.1f}%')
if len(sys.argv)>4:
    w=sys.argv[4]; s=[o for o in range(len(src)) if owner[o]==w]
    print(''.join(f'{chr(src[o])}' for o in s))
    print(' '.join(f'{chr(src[o])}{C[base+o]//N}' for o in s if C[base+o]))
