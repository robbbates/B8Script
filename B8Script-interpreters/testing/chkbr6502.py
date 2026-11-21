import re,sys
lst=open(sys.argv[1]).read().splitlines()
sym={}
for l in lst:
    m=re.match(r'^([A-Z_0-9.]+):\s+([0-9A-F]{4}) DEFINED',l)
    if m: sym[m.group(1)]=int(m.group(2),16)
bad=0
for l in lst:
    m=re.match(r'^([0-9A-F]{4})\s+([0-9A-F]{2}) ([0-9A-F]{2})\s+(?:\w+:)?\s*(B[CE][QSC]|BNE|BPL|BMI|BVS|BVC|BEQ|BCS|BCC)\s+(\w+)',l)
    if m:
        a=int(m.group(1),16); d=int(m.group(3),16); d-=256 if d>127 else 0
        t=sym.get(m.group(5).upper())
        if t is not None and a+2+d!=t:
            print('BAD',l); bad+=1
print('bad',bad)
