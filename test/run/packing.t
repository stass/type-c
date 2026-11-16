SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A unit that holds a packing bracket ends with the probe of design 10.3,
which checks that the backend reads '#pragma pack()' as a reset to the
packing of the command line, as the bracket assumes. pack_probe emits a
preprocessed unit with a bracketed structure inserted before its first
token, as an instance of a generic would be. The backends are those
that backends.sh names, and its compile_emitted compiles the output as
typec's compile step does.

  $ . ./backends.sh
  $ printf '# 1 "unit.c"\nint x;\n' > unit.i
  $ ./pack_probe.exe unit.i > probe.i

Both backends pass it by default and under -fpack-struct=1 and =2, in
C11 and C17.

  $ for cc in $clang $gcc; do
  >   for packing in "" -fpack-struct=1 -fpack-struct=2; do
  >     for std in c11 c17; do
  >       compile_emitted $cc probe.i -std=$std $packing ||
  >         echo "$cc $packing $std"
  >     done
  >   done
  > done

Inside a region of '#pragma pack(1)', the instance has the packing of
the command line, and the region is in force again after it and after
the probe.

  $ printf '# 1 "region.c"\n#pragma pack(1)\nint x;\n' > region.i
  $ ./pack_probe.exe region.i > region-probe.i
  $ cat region-probe.i - > region-checked.i <<'EOF'
  > struct after { char c; int i; };
  > _Static_assert(_Alignof(struct after) == 1, "the region is kept");
  > _Static_assert(_Alignof(struct instance) == _Alignof(int),
  >                "the instance is not packed");
  > EOF
  $ for cc in $clang $gcc; do
  >   compile_emitted $cc region-checked.i -std=c11 || echo "$cc"
  > done

Under Clang's -fapple-pragma-pack, '#pragma pack()' pops the stack, and
the probe fails with a message that names the options known to give
that reading.

  $ for packing in "" -fpack-struct=2; do
  >   $clang -fapple-pragma-pack $packing -fsyntax-only -x cpp-output \
  >     probe.i 2>&1 | grep error: | grep -o 'typec assumes [^"]*'
  > done
  typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)
  typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)

GCC under -fpack-struct without a value ignores each '#pragma pack',
with a warning for each of the three lines of the instance's bracket
(the probe stands under typec's marker with flag 3, which silences it),
which is why typec refuses that option (13.2).

  $ $gcc -fpack-struct -fsyntax-only -x cpp-output probe.i 2>&1 |
  >   grep -c "'#pragma pack' has no effect with '-fpack-struct'"
  3
