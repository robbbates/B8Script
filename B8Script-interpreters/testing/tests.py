"""The test suite: (name, program, input). Expected output comes from ref.py."""

R = b'\r'
SUITE = [
    ('hello', b'"Hello, world!/M/J"$', b''),
    ('oneten', b'1i! 1( i@# " "$ i@1+:i! 11<)', b''),
    ('fact', b'[F :1>( :1-F* 0)] 7F#', b''),
    ('fib', b'0a!1b!1(a@#" "$b@20000>\\b@:a@+b!a!1)b@#', b''),
    ('sierp', b'0y!1(0x!1(x@y@&0=("*"$0)x@y@&(" "$0)x@1+:x!32<)"/M/J"$y@1+:y!32<)', b''),
    ('collatz', b'[M/%;]27n!1(n@#" "$n@2M:{(n@3*1+n!0)}0=(n@2/;n!0)n@1=0=)n@#', b''),
    ('times', b'1r!1(1c!1(r@c@*:10<(" "$0):100<(" "$0)#" "$c@1+:c!11<)"/M/J"$r@1+:r!11<)', b''),
    ('primes', b'[M/%;]2n!1(1p!2d!1(d@:*n@>\\n@d@M0=(0p!0)d@1+d!1)p@(n@#" "$0)n@1+:n!1000<)', b''),
    ('fizz', b'[M/%;]1i!1(0f!i@3M0=("Fizz"$1f!0)i@5M0=("Buzz"$1f!0)f@0=(i@#0)" "$i@1+:i!101<)', b''),
    ('escapes', b'"/@/A/[/`/a/~/b>///""$ "x/"y"$ "a>b<c"$ "/o/O"$', b''),
    ('escskip', b'0( "a/"b)" 1#) 2# 0( "c//" 3#) 4# 1("//"$0) [A"/"]"$] A', b''),
    ('codestr', b'[X{] "9 2/;#]"X " "$ "7 2/%;#]"X', b''),
    ('divs', b'[P%#" "$#" "$] -7 2/P 7 2/P 7 -2/P -7 -2/P 100 7/P -32768 -1/P -100 7/P 32767 -3/P 1 2/P -1 2/P 0 5/P 0 -5/P 5 1/P -5 1/P 5 -1/P 9 9/P 3 9/P -3 9/P 30000 -30000/P -32768 2/P 32767 32767/P 12345 100/P -12345 100/P', b''),
    ('div2', b'[P%#" "$#" "$] 0 2/P 1 2/P 2 2/P 3 2/P 32767 2/P -32768 2/P -32767 2/P 9 -2/P -9 -2/P -32768 -2/P 32767 -2/P 10 2/;# 11 2/%;#', b''),
    ('divmod', b'17 5/;# " "$ 17 5/%;# " "$ -17 5/;# " "$ -17 5/%;#', b''),
    ('mul', b'7 6*# " "$ -7 6*# " "$ 300 300*# " "$ -1 -1*#', b''),
    ('cmp', b'[P#" "$] 1 2<P 2 1<P -1 1<P 1 -1<P -32768 32767<P 5 5=P 5 6=P 2 1>P -5 3>P 3 3>P', b''),
    ('logic', b'[P#" "$] 12 10&P 12 10|P 12 10^P 0~P 5~P', b''),
    ('nums', b'40000# " "$ -5# " "$ 5-3+# " "$ 8 5- # " "$ 65535# " "$ 0#', b''),
    ('stack', b'1 2 3 %#" "$#" "$#" "$ 4:+# " "$ 7 8;# " "$ 9{1}+#', b''),
    ('bytes', b'4_x! 258x@! x@,# " "$ x@1+,# " "$ 65x@. x@@#', b''),
    ('emit', b"72'105'13'10'", b''),
    ('skip', b'0( "(]" 1#)" "$ 1("x)"$0) 0(1( ] ( 0)2#) 3#', b''),
    ('break', b'[W 1(:#" "$ 1-:0=\\ 1) ;"done"$] 5W " "$ [G :0<\\ "pos"$] 3G -3G " "$ 1\\ "never"$', b''),
    ('words', b'[X{] [f 42#] f@X " "$ [ 7#]X " "$ [ 9#]:X X " "$ [A 1#] [A 2#] A', b''),
    ('vecjump', b'[T "t"$ x@{] [x "x"$] T "end"$', b''),
    ('heap', b'10_ 0_ %- # " "$ 0_m! 7_; m@0_-_; 0_ m@=#', b''),
    ('heapsigned', b'0_m! 100_; -30_ m@- # " "$ 0_ m@- # " "$ -70_; 0_ m@=# " "$ 0_ 0_=#', b''),
    ('hexload', b'4_:x! `$414243 ; x@,# " "$ x@2+,# " "$ x@3+,#  4_:y! `$4 ; y@,#', b''),
    ('hexmixed', b'6_:x! `$aBcDeF ; x@,# " "$ x@1+,# " "$ x@2+,# " "$ x@3+,# " "$ 5_:y! `$ ; y@,# " "$ 5_:z! `$12`$3456`$; z@,#" "$z@1+,#" "$z@2+,#" "$z@3+,#', b''),
    ('key0', b'0?#" "$ 0?#', b'AB'),
    ('keyt', b'5?#" "$ 3?#" "$ 2?#', b'Z'),
    ('line', b'-20?a!1(a@,:#" "$13=~a@1+a!)', b'hi\x01x\x08y\r'),
    ('line1', b'-1?a! a@,# " "$ a@1+,#', b'q\r'),
    ('linecap', b'-3?a! 1(a@,:#" "$13=~a@1+a!)', b'abcdef\r'),
    ('linebs', b'-5?a! 1(a@,:#" "$13=~a@1+a!)', b'\x08\x08ab\x08\x08\x08cdefgh\x08\x08ij\r'),
    ('line127', b'-127?a! 0n! 1(a@n@+,13=~:(n@1+n!0)) n@#', b'x' * 140 + b'\r'),
    ('lineclamp', b'-128?a! 0n! 1(a@n@+,13=~:(n@1+n!0)) n@#', b'x' * 140 + b'\r'),
    ('lineclamp2', b'-256?a! 0n! 1(a@n@+,13=~:(n@1+n!0)) n@#', b'x' * 140 + b'\r'),
    ('lineclamp3', b'-1000?a! 0n! 1(a@n@+,13=~:(n@1+n!0)) n@#', b'x' * 140 + b'\r'),
    ('lineclamp4', b'-32768?a! 0n! 1(a@n@+,13=~:(n@1+n!0)) n@#', b'x' * 140 + b'\r'),
    ('line126', b'-126?a! 0n! 1(a@n@+,13=~:(n@1+n!0)) n@#', b'x' * 140 + b'\r'),
    ('evalline', b'[X{] -72?:{1(:,13=\\1+1)93%.}X', b'1 2+#\r'),
    ('ignored', b'1\x01\x7f 2+#\x7f', b''),
    ('highstr', b'"caf\xe9 \x80\xfe"$ 0( \xc1 "\x90" ) 1#', b''),
    ('deepstk', b'0i! 1( i@ i@1+:i! 100<) 0 1( + i@1-:i! 0>) #', b''),
    ('deeprs', b'[R :( 1- R 0)] 50 R #', b''),
]

# The grave's codes (the hex loader is above; `! is with the machine-code tests)
SUITE += [
    ('g_incdec', b'[P#" "$] 5x! x`+P x`+P x@P x`-P x`-P x`-P x`-P x`-P x`-P x@P', b''),
    ('g_incwrap', b'[P#" "$] 255x! x`+P x@P 32767x! x`+P -1x! x`+P x`+P 0x! x`-P x`-P -32768x! x`-P 256x! x`-P x`+P', b''),
    ('g_incmem', b'[P#" "$] 4_:a! 0%! a@`+P a@`+P a@@P a@,P a@1+,P 10_:b! 1+ 300%! b@1+`-P b@1+@P [V x`+;] 7x! V V V x@P', b''),
    ('g_minmax', b'[P#" "$] 3 7`<P 3 7`>P 7 3`<P 7 3`>P 5 5`<P 5 5`>P -3 7`<P -3 7`>P 7 -3`<P 7 -3`>P -3 -7`<P -3 -7`>P 0 -1`<P 0 -1`>P', b''),
    ('g_minmax2', b'[P#" "$] 32767 -32768`<P 32767 -32768`>P -32768 32767`<P -32768 32767`>P 30000 -30000`<P 30000 -30000`>P -30000 30000`<P -30000 30000`>P 1 2 3`<`<P 1 2 3`>`>P 9 4`<8`>P -1 1`<P 256 255`<P 256 255`>P 255 256`<P -256 -255`>P', b''),
    ('g_nl', b"\"a\"$`'\"b\"$`'`'\"c\"$ 1 2`'+#", b''),
    ('g_seed', b'[P#" "$] `.`.=P 1234`.! `.@P `.,P 0`.! `.@P', b''),
    ('g_rnd', b'[P#" "$] 0`.! 20 1(10`,P 1-:); `.@P', b''),
    ('g_rnd2', b'[P#" "$] 1`.! 10 1(1000`,P 1-:); 10 1(32767`,P 1-:); 10 1(1`,P 1-:); 10 1(2`,P 1-:); 10 1(3`,P 1-:);', b''),
    ('g_rnd3', b'[P#" "$] 5 6 7 -1`.! 100`,P 256`,P 257`,P 1024`,P 4096`,P 20000`,P PPP', b''),
    ('g_rndreplay', b'[P#" "$] 777`.! `.@s! 5 1(52`,P 1-:); s@`.! 5 1(52`,P 1-:);', b''),
    # every value of a small range turns up, and a big range gives more than 256 different ones
    ('g_rndall', b'16_a! 0i!1(0a@i@+.i`+16<) 0`.! 400 1(1 16`,a@+. 1-:); 0s! 0i!1(a@i@+,s@+s! i`+16<) s@# " "$'
                 b' 1024_b! 0i!1(0b@i@+.i`+1024<) 0`.! 600 1(1 1024`,b@+. 1-:); 0s! 0i!1(b@i@+,s@+s! i`+1024<) s@#', b''),
    # a timed wait that runs out stirs the seed by its count; a key that is there at once does not
    ('g_stir', b'[P#" "$] 0`.! 0?P 0?P `.@P 5?P `.@P 7?P 1?P `.@P 100?P `.@P 10`,P', b'AB'),
    ('g_stir2', b'[P#" "$] 100`.! -5?,P `.@P 2?P `.@P 0?P `.@P 50`,P 9?P `.@P', b'xy\rZW'),
    ('g_at', b'0 0`@ 4 9`@ 23 79`@ 1 2 3 4`@ # # 9 99`@ 255 255`@ 0 255`@ 255 0`@', b''),
    ('g_cls', b'"a"$ `^ "b"$ `_ "c"$ 5`^# 6`_#', b''),
    ('g_cur', b'0`? 1`? -1`? 256`? 7 0`? # 8 2`? #', b''),
    ('g_skip', b'0( `^ `_ 1`? 2 3`@ x`+ x`- `. `, `\' 1 2`< `> "a"$ `$41 `! ) "ok"$ [A 5x! x`+# `\' ] A 1( 1\\ `^ ) "z"$', b''),
    ('g_inword', b'[N`\'] [C`^] [Y`@] [R`,] "a"$N"b"$ C 3 4Y 0`.! 9R# 9R# [I`+] [D`-] 5x! xI# xD# xD#', b''),
]

# Builds with ANSI = 1 only: a row or column past 255. (With ANSI = 0 the
# machine's own routine gets them, and on the 6502 it is handed one byte of
# each.)
ANSI_ONLY = [
    ('g_atbig', b'999 12345`@ 256 300`@ -1 -1`@ 1#', b''),
]

# Machine-code tests, per CPU (expected output given directly)
MC = {
    'z80': [('mcdouble', b'8_:d! `$D1E129E5D5 ; 21 d@`! #', b'', b'42')],
    '8080': [('mcdouble', b'8_:d! `$D1E129E5D5 ; 21 d@`! #', b'', b'42')],
}

# Unchecked builds only. brack: anything but a letter after [ is taken as the
# space, so each of these pushes an address. ignored: reserved bytes outside
# strings are ignored. div0: dividing by zero leaves two cells of no meaning,
# and the stack stays balanced. (A checked build stops on all three.)
LOOSE = [
    ('brack', b'1 [@ 0#] ; # 2 [[ 0#] ; # 3 [{ 0#] ; # 4 [~ 0#] ; # 5 [^ 0#] ; # 6 [` 0#] ; # 7 [1 0#] ; # 8 [_ 0#] ; # 9 [\x7f 0#] ; # 1 [\xc1 0#] ; #', b''),
    ('ignored8', b'1\x01\x7f\xc0 2\x80+\xff#', b''),
    ('div0', b'7 0/;; -7 0/;; 0 0/;; 5#', b''),
]

# Checked builds only: programs that end normally. A checked build zeros the
# variables at startup.
CHK = [
    ('zerovars', b'a@# m@# z@# 5a! a@#', b''),
    # \ with no closer ends the program quietly even when the text it skips
    # holds openers and a string with no closing quote (in an unchecked
    # build an unclosed string is unsafe)
    ('breakend2', b'"b"$ 1\\ "no"$ ( [ "x', b''),
]

# Checked builds only: programs that stop with an error. The whole output, the
# report included, must be what ref.py gives, run with the build's own
# addresses. Where a pattern is given instead (the last field), the output
# must match that: a stack overrun is found once per character, so its place
# can be a character late, and the sizes of the stacks differ from build to
# build. No test may reach the "no" (it would be in the output twice).
PLACE = rb'\r\nErr %c @ \d+,\d+\r\n[^\r\n\0]{0,16}\r\n'
ERRS = [
    # data stack: s underflow (the stack then counts as empty), S overflow
    ('e_under', b'1 2+ ;; "no"$', b'', PLACE % b's' + rb'Stk 0:\r\nRtn 0\r\n'),
    ('e_under2', b'1( + "no"$ 0)', b'', PLACE % b's' + rb'Stk 0:\r\nRtn 1\r\n'),
    ('e_over', b'1( 7 1)', b'', PLACE % b'S' + rb'Stk \d{3}: \.\.\.( [71]){8}\r\nRtn 1\r\n'),
    # return stack: r underflow (it then counts as empty), R overflow
    ('e_rund', b'1 2 ] "no"$', b'', PLACE % b'r' + rb'Stk 2: 1 2\r\nRtn 0\r\n'),
    ('e_rund2', b'3 } "no"$', b'', PLACE % b'r' + rb'Stk \d: .*\r\nRtn 0\r\n'),
    ('e_rover', b'[R R] 5 R', b'', PLACE % b'R' + rb'Stk 1: 5\r\nRtn \d{2,3}\r\n'),
    # W: [ not followed by a letter or a space. The place is that character
    ('e_brack', b'[5 1] "no"$', b'', None),
    ('e_brack2', b'1 2 [[ 1] "no"$', b'', None),
    ('e_brack3', b'"ok"$\r\n[{ 1] "no"$', b'', None),
    ('e_brack4', b'[@ 1] "no"$', b'', None),
    ('e_brack5', b'1 [', b'', None),
    # O: a store outside the program's space
    ('e_store', b'1 0! "no"$', b'', None),
    ('e_store2', b'"ok"$ 7 0. "no"$', b'', None),
    ('e_store3', b'1 2 3 -1! "no"$', b'', None),
    ('e_store4', b'5x! [A 9 -1.] 1( A "no"$ 0)', b'', None),
    # H: the heap past its limit, or released below the program's end
    ('e_heap', b'-1_ "no"$', b'', None),
    ('e_heap2', b'10_; 4 -11_ "no"$', b'', None),
    ('e_heap3', b'32767_; 32767_; 32767_; "no"$', b'', None),
    ('e_heap4', b'32767_; 9_; 32767_; "no"$', b'', None),      # wraps to just above the program
    ('e_heap5', b'100_; -32768_; "no"$', b'', None),
    ('e_heap6', b'-32768_; -32768_; "no"$', b'', None),
    # U: a word that was never defined. The place is the call
    ('e_undef', b'1 2 Q "no"$', b'', None),
    ('e_undef2', b'[A 5 B "no"$]\r\n"ok"$ 1 A "no"$', b'', None),
    ('e_undef3', b'[Z 1] [y 2] Y', b'', None),
    # Q: no closing quote: a string that runs into the end, or $ that does
    ('e_quote', b'1 "abc', b'', None),
    ('e_quote2', b'7 "abc//" "de/"', b'', None),
    ('e_quote3', b'3_:x! 65x@. 66x@1+. 0x@2+. 4 x@$ "no"$', b'', None),
    ('e_quote4', b'"x/', b'', None),
    # X: a reserved byte outside a string
    ('e_resv', b'1 2\xc0 "no"$', b'', None),
    ('e_resv2', b'"\x80 is fine in a string"$ 1(\x80 "no"$ 0)', b'', None),
    ('e_resv3', b'\x80', b'', None),
    # Z: dividing by zero
    ('e_zero', b'7 0/ "no"$', b'', None),
    ('e_zero2', b'1 2 3 4 5 6 7 8 9 -10 0/ "no"$', b'', None),
    ('e_zero3', b'[D/] 1( 5 0 D "no"$ 0)', b'', None),
    # N: a skip from ( or [ that runs into the end, or finds the wrong closer
    ('e_nest', b'0( 1 2', b'', None),
    ('e_nest2', b'5 0( 1 ] 2) "no"$', b'', None),
    ('e_nest3', b'[A 1 ) 2] "no"$', b'', None),
    ('e_nest4', b'7 [ 1 2', b'', None),
    ('e_nest5', b'5 0( "abc', b'', None),
    ('e_nest6', b'1(\r\n  2 [x 1 ( 2 ) ) "no"$ ]\r\n0)', b'', None),
    ('e_nest7', b'[a 1( [ ( ) ] 0) ) "no"$', b'', None),
    # the place: a line and a column from 1, in a program of several lines
    ('e_place', b'1 2\r\n3 4\r\n 5 0/ "no"$\r\n6', b'', None),
    ('e_place2', b'1\n2\n\n3 [5', b'', None),
    ('e_place3', b'\r\n' * 300 + b'  9 0/', b'', None),
    ('e_place4', b'"' + b'x' * 300 + b'"; 9 0/ ' + b'y' * 40, b'', None),
    # a line read by -n? and then run is line 0
    ('e_line0', b'[X{] -72?X "no"$', b'7 0/ 1\r', None),
    # more than 8 cells on the stack: "..." and the top 8, negative ones too
    ('e_stk9', b'1 2 3 4 5 6 7 8 9 0/', b'', None),
    ('e_stk8', b'-1 -2 -3 -4 -5 -6 -32768 0/', b'', None),
    # the grave: W for a character with no meaning after it (the place is that
    # character), O for `+ and `- outside the program's space, Z for `, of
    # less than 1. The place of O and Z is the character after the grave
    ('e_grave', b'1 2 `x "no"$', b'', None),
    ('e_grave2', b'"ok"$ 5 `A "no"$', b'', None),
    ('e_grave3', b'1 ` 2 "no"$', b'', None),
    ('e_grave4', b'7 `', b'', None),
    ('e_grave5', b'[W 1 2 `# "no"$]\r\n 9 W', b'', None),
    ('e_grave6', b'3 `0 "no"$', b'', None),
    ('e_grave7', b'3 `` "no"$', b'', None),
    ('e_grave8', b'3 `~ "no"$', b'', None),
    ('e_grave9', b'3 `; "no"$', b'', None),
    ('e_grave10', b'3 `= "no"$', b'', None),
    ('e_grave11', b'3 `\x7f "no"$', b'', None),
    ('e_grave12', b'3 `% "no"$', b'', None),
    ('e_grave13', b'3 `* "no"$', b'', None),
    ('e_grave14', b'3 `/ "no"$', b'', None),
    ('e_grave15', b'3 `: "no"$', b'', None),
    ('e_grave16', b'3 `{ "no"$', b'', None),
    ('e_ginc', b'1 2 0`+ "no"$', b'', None),
    ('e_gdec', b'"ok"$ 7 -1`- "no"$', b'', None),
    ('e_ginc2', b'[A 5 0`+] 1( A "no"$ 0)', b'', None),
    ('e_grnd', b'1 2 0`, "no"$', b'', None),
    ('e_grnd2', b'9 -1`, "no"$', b'', None),
    ('e_grnd3', b'9 -32767`, "no"$', b'', None),
    ('e_grnd4', b'1`,# 32767`,;\r\n 8 0`, "no"$', b'', None),
    # the report starts on a new line, whatever was printed before it
    ('e_out', b'"abc"$ 1 0/', b'', None),
]

# Unchecked and checked builds: \ with no closer ends the program quietly,
# even from inside a block (it is not an N).
SUITE += [
    ('breakend', b'"a"$ 1( 1\\ "no"$', b''),
]
