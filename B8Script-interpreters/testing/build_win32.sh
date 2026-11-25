#!/bin/bash
# build_win32.sh [SRC] [OUTDIR]: assembles the Windows builds of
# ../win32/b8s-win32.asm (NASM 2.16, flat binary: the source lays out the PE
# header itself) into OUTDIR (default out/win32), each tier's four:
#   B8S.EXE    the runner, checked     (SPEED=1 CHECKED=1 EDITOR=0)
#   B8SU.EXE   the runner, unchecked   (SPEED=1 CHECKED=0 EDITOR=0)
#   B8SE.EXE   the line editor, checked (SPEED=1 CHECKED=1 EDITOR=1)
#   B8SEU.EXE  the editor, unchecked   (SPEED=1 CHECKED=0 EDITOR=1)
# and the same with SPEED=0, the small builds (B8SS, B8SSU, B8SSE, B8SSEU),
# and SPEED=2, the fast builds (B8SF, B8SFU, B8SFE, B8SFEU).
# Each also gets a NASM listing (.lst) and a map file (.map) with every
# symbol's value, which harness_win32.py reads. Then chkpe.py checks them.
cd "$(dirname "$0")"
src=$(realpath ${1:-../win32/b8s-win32.asm}); out=${2:-out/win32}; mkdir -p $out
fail=0
for v in "B8S 1 0 1" "B8SU 0 0 1" "B8SE 1 1 1" "B8SEU 0 1 1" \
         "B8SS 1 0 0" "B8SSU 0 0 0" "B8SSE 1 1 0" "B8SSEU 0 1 0" \
         "B8SF 1 0 2" "B8SFU 0 0 2" "B8SFE 1 1 2" "B8SFEU 0 1 2"; do
  set -- $v
  printf '%%define CHECKED %s\n%%define EDITOR %s\n%%define SPEED %s\n[map all %s.map]\n%%include "%s"\n' \
    $2 $3 $4 $1 "$src" > $out/$1.asm
  (cd $out && nasm -f bin -w-pp-macro-redef-multi -l $1.lst -o $1.EXE $1.asm > $1.log 2>&1) \
    || { echo "FAIL $1"; cat $out/$1.log; fail=1; }
done
python3 chkpe.py $out/*.EXE || fail=1
exit $fail
