import sys, glob, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_z80 import load_hex
for f in sorted(glob.glob(sys.argv[1]+'/*.hex')):
    lo, img = load_hex(f)
    print(f'{os.path.basename(f)[:-4]:24} {len(img):5} bytes  (from {lo:04X}h)')
