Every seed passes the target its directory names: the harness exits 0
and prints nothing.

  $ for directory in seeds/*/; do
  >   target=$(basename "$directory")
  >   for seed in "$directory"*; do
  >     ./fuzz.exe "$target" "$seed" || echo "failed: $seed"
  >   done
  > done

The input can also come from standard input.

  $ printf 'int x;\n' | ./fuzz.exe reader

A target is chosen by name.

  $ ./fuzz.exe lexer seeds/reader/markers.i
  usage: fuzz TARGET [FILE]; targets: reader
  [2]
