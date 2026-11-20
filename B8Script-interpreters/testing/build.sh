#!/bin/bash
# build.sh CPU SRC OUTDIR: assembles every variant of one interpreter source.
#   CPU is an asm80 machine name: Z80, I8080, C6502 or M6809.
#   Variants are "CPM CHECKED" pairs; for 6502/6809 use
#   VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502.asm out/6502
# Set ASM80 to the path of asm80.js if it isn't in the global npm folder.
A=${ASM80:-$(npm root -g)/asm80/asm80.js}
cpu=$1; src=$(realpath $2); out=$3; mkdir -p $out
variants=${VARIANTS:-"0 0
0 1
1 0
1 1"}
echo "$variants" | while read cpm chk; do
  n=$(basename $src .asm)-$([ $cpm = 1 ] && echo cpm || echo gen)$([ $chk = 1 ] && echo -chk)
  sed -e "s/^CPM     EQU     0 /CPM     EQU     $cpm /" -e "s/^CHECKED EQU     0 /CHECKED EQU     $chk /" $src > $out/$n.asm
  : > $out/$n.hex
  (cd $out && node $A -m $cpu -t hex -o $n.hex $n.asm > $n.log 2>&1) || { echo "FAIL $n"; tail -5 $out/$n.log; }
done
