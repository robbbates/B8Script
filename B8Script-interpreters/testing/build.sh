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
#   A fourth field of 0 builds with ANSI = 0 (the console codes call the
#   machine's own routines instead of sending ANSI sequences):
#   VARIANTS=$'0 0 0 0\n0 1 0 0' ./build.sh Z80 ../z80/b8s-z80.asm out/z80
#   Each build is named SOURCE-gen or -cpm, or with the editor -ed or
#   -cpm-ed, plus -chk if checked, plus -noansi if ANSI = 0.
# Set ASM80 to the path of asm80.js if it isn't in the global npm folder.
A=${ASM80:-$(npm root -g)/asm80/asm80.js}
cpu=$1; src=$(realpath $2); out=$3; mkdir -p $out
variants=${VARIANTS:-"0 0
0 1
1 0
1 1"}
echo "$variants" | while read cpm chk ed ansi; do
  kind=gen; [ "$cpm" = 1 ] && kind=cpm
  [ "$ed" = 1 ] && { [ "$cpm" = 1 ] && kind=cpm-ed || kind=ed; }
  n=$(basename $src .asm)-$kind$([ $chk = 1 ] && echo -chk)$([ "$ansi" = 0 ] && echo -noansi)
  sed -e "s/^CPM     EQU     0 /CPM     EQU     $cpm /" -e "s/^CHECKED EQU     0 /CHECKED EQU     $chk /" \
      -e "s/^EDITOR  EQU     0 /EDITOR  EQU     ${ed:-0} /" -e "s/^ANSI    EQU     1 /ANSI    EQU     ${ansi:-1} /" $src > $out/$n.asm
  : > $out/$n.hex
  (cd $out && node $A -m $cpu -t hex -o $n.hex $n.asm > $n.log 2>&1) || { echo "FAIL $n"; tail -5 $out/$n.log; }
done
