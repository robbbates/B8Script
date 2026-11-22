#!/bin/bash
# build_win32.sh [SRC] [OUTDIR]: assembles the four Windows builds of
# ../win32/b8s-win32.asm (NASM 2.16, flat binary: the source lays out the PE
# header itself) into OUTDIR (default out/win32):
#   B8SWIN.EXE    the runner             (CHECKED=0 EDITOR=0)
#   B8SWINC.EXE   the runner, checked    (CHECKED=1 EDITOR=0)
#   B8SWINE.EXE   the line editor        (CHECKED=0 EDITOR=1)
#   B8SWINEC.EXE  the editor, checked    (CHECKED=1 EDITOR=1)
# Each also gets a NASM listing (.lst) and a map file (.map) with every
# symbol's value, which harness_win32.py reads. Then chkpe.py checks them.
cd "$(dirname "$0")"
src=$(realpath ${1:-../win32/b8s-win32.asm}); out=${2:-out/win32}; mkdir -p $out
fail=0
for v in "B8SWIN 0 0" "B8SWINC 1 0" "B8SWINE 0 1" "B8SWINEC 1 1"; do
  set -- $v
  printf '%%define CHECKED %s\n%%define EDITOR %s\n[map all %s.map]\n%%include "%s"\n' $2 $3 $1 "$src" > $out/$1.asm
  (cd $out && nasm -f bin -w-pp-macro-redef-multi -l $1.lst -o $1.EXE $1.asm > $1.log 2>&1) \
    || { echo "FAIL $1"; cat $out/$1.log; fail=1; }
done
python3 chkpe.py $out/*.EXE || fail=1
exit $fail
