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
    ('divmod', b'17 5/;# " "$ 17 5/%;# " "$ -17 5/;# " "$ -17 5/%;#', b''),
    ('div0', b'7 0/;; -7 0/;; 0 0/;; 5#', b''),
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
    ('heap', b'10_ 0_ %- # " "$ z10+@m! 7_; m@z10+! 0_ m@=#', b''),
    ('hexload', b'4_:x! `414243 ; x@,# " "$ x@2+,# " "$ x@3+,#  4_:y! `4 ; y@,#', b''),
    ('key0', b'0?#" "$ 0?#', b'AB'),
    ('keyt', b'5?#" "$ 3?#" "$ 2?#', b'Z'),
    ('line', b'-20?a!1(a@,:#" "$13=~a@1+a!)', b'hi\x01x\x08y\r'),
    ('line1', b'-1?a! a@,# " "$ a@1+,#', b'q\r'),
    ('linecap', b'-3?a! 1(a@,:#" "$13=~a@1+a!)', b'abcdef\r'),
    ('linebs', b'-5?a! 1(a@,:#" "$13=~a@1+a!)', b'\x08\x08ab\x08\x08\x08cdefgh\x08\x08ij\r'),
    ('line127', b'-127?a! 0n! 1(a@n@+,13=~:(n@1+n!0)) n@#', b'x' * 140 + b'\r'),
    ('evalline', b'[X{] -72?:{1(:,13=\\1+1)93%.}X', b'1 2+#\r'),
    ('ignored', b'1\x01\x7f\xc0 2+#', b''),
    ('deepstk', b'0i! 1( i@ i@1+:i! 100<) 0 1( + i@1-:i! 0>) #', b''),
    ('deeprs', b'[R :( 1- R 0)] 50 R #', b''),
]

# Machine-code tests, per CPU (expected output given directly)
MC = {
    'z80': [('mcdouble', b'8_:d! `D1E129E5D5 ; 21 d@` #', b'', b'42')],
    '8080': [('mcdouble', b'8_:d! `D1E129E5D5 ; 21 d@` #', b'', b'42')],
}

# Checked builds only: each should stop with "<letter> @ <offset>", where the
# offset is the place in the program of the character just read. The stack
# checks run once per character, so their offset can be a character late and
# is not compared (None).
ERRS = [
    ('e_under', b'1 2+ ;;; "no"$', b'S', None),
    ('e_over', b'1( 1 1)', b'S', None),
    ('e_rund', b'] "no"$', b'R', None),
    ('e_rover', b'[R R] R', b'R', None),
    ('e_brack', b'[5 1] "no"$', b'D', 1),
    ('e_store', b'1 0! "no"$', b'W', 3),
    ('e_store2', b'"ok"$ 7 0. "no"$', b'W', 9),
    ('e_heap', b'-1_ "no"$', b'H', 2),
]
