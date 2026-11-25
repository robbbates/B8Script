#!/bin/bash
# build.sh CPU SRC OUTDIR: assembles every variant of one interpreter source.
#   CPU is an asm80 machine name: Z80, I8080, C6502 or M6809.
#   Variants are "CPM CHECKED" pairs. The default (all four) suits the Z80
#   and 8080; the others have no CP/M build:
#   VARIANTS=$'0 0\n0 1' ./build.sh M6809 ../6809/b8s-6809.asm out/6809
#   VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502.asm out/6502
#   VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502-zp.asm out/6502
#   A third field of 1 builds the Z80 with its line editor (EDITOR = 1):
#   VARIANTS=$'0 0 1\n0 1 1\n1 0 1\n1 1 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80
#   Each build is named SOURCE-gen or -cpm, or with the editor -ed or
#   -cpm-ed, plus -chk if checked.
#   QUICK=1 builds the Z80 with its speed-ups: SOURCE-quick-gen and so on.
#   FAST=1 builds the Z80's speed build (no editor): SOURCE-fast-gen and so on.
# Set ASM80 to the path of asm80.js if it isn't in the global npm folder.
A=${ASM80:-$(npm root -g)/asm80/asm80.js}
cpu=$1; src=$(realpath $2); out=$3; mkdir -p $out
variants=${VARIANTS:-"0 0
0 1
1 0
1 1"}
echo "$variants" | while read cpm chk ed; do
  kind=gen; [ "$cpm" = 1 ] && kind=cpm
  [ "$ed" = 1 ] && { [ "$cpm" = 1 ] && kind=cpm-ed || kind=ed; }
  n=$(basename $src .asm)$([ "${FAST:-0}" = 1 ] && echo -fast)$([ "${QUICK:-0}" = 1 ] && echo -quick)-$kind$([ $chk = 1 ] && echo -chk)
  sed -e "s/^CPM     EQU     0 /CPM     EQU     $cpm /" -e "s/^CHECKED EQU     0 /CHECKED EQU     $chk /" \
      -e "s/^EDITOR  EQU     0 /EDITOR  EQU     ${ed:-0} /" -e "s/^ANSI    EQU     0 /ANSI    EQU     ${ANSI:-0} /" -e "s/^FAST    EQU     0 /FAST    EQU     ${FAST:-0} /" -e "s/^QUICK   EQU     0 /QUICK   EQU     ${QUICK:-0} /" $src > $out/$n.asm
  : > $out/$n.hex
  (cd $out && node $A -m $cpu -t hex -o $n.hex $n.asm > $n.log 2>&1) || { echo "FAIL $n"; tail -5 $out/$n.log; }
done
