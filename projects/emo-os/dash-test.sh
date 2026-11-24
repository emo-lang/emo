# dash on EmoOS (T4.1): the shell's own acceptance. Variables, a
# for-loop, a test, printf, a redirect both ways, and read — the
# features a POSIX shell must carry, over the T1 gate's fd surface.
echo dash ok
x=one
for i in 1 2 3; do x=$x$i; done
echo "x=$x"
if [ "$x" = one123 ]; then echo if ok; fi
printf 'printf %s\n' ok
echo file > out.txt
if [ -f out.txt ]; then echo file ok; fi
read line < out.txt
echo "read $line"
echo dash done
