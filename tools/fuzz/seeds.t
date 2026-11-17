A seed directory is named for the first target that reads its kind of
input, and each target reads the seeds of its own kind and of every
kind before it: the lowering target reads the declarations of every
parser seed, the parser reads every reader seed.

  $ for directory in seeds/*/; do
  >   target=$(basename "$directory")
  >   echo "$target:" $(./fuzz.exe -s "$target")
  > done
  lowering: reader parser lowering
  parser: reader parser
  reader: reader

Every seed directory names a target, which fuzz.exe refuses otherwise,
and every seed passes each target that reads it: the harness exits 0 and
prints nothing.

  $ for directory in seeds/*/; do
  >   target=$(basename "$directory")
  >   for kind in $(./fuzz.exe -s "$target"); do
  >     for seed in seeds/$kind/*; do
  >       ./fuzz.exe "$target" "$seed" || echo "failed: $target $seed"
  >     done
  >   done
  > done

The input can also come from standard input.

  $ printf 'int x;\n' | ./fuzz.exe reader

A target is chosen by name.

  $ ./fuzz.exe lexer seeds/reader/markers.i
  usage: fuzz [-t | -s] TARGET [FILE]; targets: reader, parser, lowering
  [2]

Only the parser runs on the small stack: the checks and the stages after
it walk a tree as deep as the input, which overflows it. The input is
just under Parser.max_depth deep, so the parser accepts it.

  $ for target in parser lowering; do
  >   { echo '# 1 "deep.c"'; printf 'int a[';
  >     head -c 9000 /dev/zero | tr '\0' '!'; echo '1];'; } |
  >     ./fuzz.exe "$target"
  > done

The parser target runs the reader and the parser alone, whose work is
linear in the input. The declaration reader's is bounded by the
instance budget instead, so it runs in the lowering target, whose
bounds are those of the budgets. A source that nearly fills the budget
passes both.

  $ ./budget_probe.exe > probe.i
  $ ./fuzz.exe parser probe.i
  $ ./fuzz.exe lowering probe.i

A target states its time limit in milliseconds.

  $ ./fuzz.exe -t parser
  300
  $ ./fuzz.exe -t lowering
  5000
