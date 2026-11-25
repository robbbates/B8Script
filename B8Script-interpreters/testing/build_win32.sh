#!/bin/bash
# build_win32.sh [SRC] [OUTDIR]: assembles the Windows builds of
# ../win32/b8s-win32.asm (NASM 2.16, flat binary: the source lays out the PE
# header itself) into OUTDIR (default out/win32):
#   B8SWIN.EXE    the runner             (CHECKED=0 EDITOR=0)
#   B8SWINC.EXE   the runner, checked    (CHECKED=1 EDITOR=0)
#   B8SWINE.EXE   the line editor        (CHECKED=0 EDITOR=1)
#   B8SWINEC.EXE  the editor, checked    (CHECKED=1 EDITOR=1)
# and the same four with QUICK=1 (B8SWINQ, B8SWINQC, B8SWINQE, B8SWINQEC)
# and with FAST=1, the speed builds (B8SWINF, B8SWINFC, B8SWINFE, B8SWINFEC).
# Each also gets a NASM listing (.lst) and a map file (.map) with every
# symbol's value, which harness_win32.py reads. Then chkpe.py checks them.
cd "$(dirname "$0")"
src=$(realpath ${1:-../win32/b8s-win32.asm}); out=${2:-out/win32}; mkdir -p $out
fail=0
for v in "B8SWIN 0 0" "B8SWINC 1 0" "B8SWINE 0 1" "B8SWINEC 1 1" \
         "B8SWINQ 0 0 1" "B8SWINQC 1 0 1" "B8SWINQE 0 1 1" "B8SWINQEC 1 1 1" \
         "B8SWINF 0 0 0 1" "B8SWINFC 1 0 0 1" "B8SWINFE 0 1 0 1" "B8SWINFEC 1 1 0 1"; do
  set -- $v
  printf '%%define CHECKED %s\n%%define EDITOR %s\n%%define QUICK %s\n%%define FAST %s\n[map all %s.map]\n%%include "%s"\n' \
    $2 $3 ${4:-0} ${5:-0} $1 "$src" > $out/$1.asm
  (cd $out && nasm -f bin -w-pp-macro-redef-multi -l $1.lst -o $1.EXE $1.asm > $1.log 2>&1) \
    || { echo "FAIL $1"; cat $out/$1.log; fail=1; }
done
python3 chkpe.py $out/*.EXE || fail=1
exit $fail
