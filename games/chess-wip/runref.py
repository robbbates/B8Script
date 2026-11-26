import sys
import os; sys.path.insert(0,os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','B8Script-interpreters','testing'))
from ref import Ref
def runref(prog, inp=b'', steps=200_000_000, checked=True):
    r=Ref(prog, inp, checked=checked)
    try:
        r.run(steps)
    except Exception as ex:
        return r.out + b'\n<<'+repr(ex).encode()+b'>>', r
    return r.out, r
if __name__=='__main__':
    p=open(sys.argv[1],'rb').read()
    if len(sys.argv)>2: p+=sys.argv[2].encode()
    o,r=runref(p)
    print(o.decode('latin1'))
    print('steps?', getattr(r,'steps',None), 'ds', r.ds[-8:])
