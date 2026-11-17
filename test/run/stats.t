SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

With --stats, typec reports on stderr what each .tc input counts
against the translation limits of design 3.5 rule 7, for the
measurements of P30: the bytes of the preprocessed unit, those that the
readings for instances charge the instance budget, those that the front
end's copies of deferred statements and lowering charge the output
limit, the limit itself, the most bytes of the code of one instance
that the bound on encodings holds, and the longest name of a type
declaration or a generic function. The option never reaches the
backend, and the emitted C on stdout is unchanged.

  $ . ./backends.sh
  $ cat > counted.tc <<'EOF'
  > type pair(A, B) = struct { A first; B second; };
  > type a_rather_long_type_name = int;
  > struct widget { int size; };
  > generic(T) T
  > first_of(pair(T, T) p)
  > {
  >   return (p.first);
  > }
  > int
  > use(int n)
  > {
  >   pair(int, double) mixed;
  >   pair(struct widget *, int) holder;
  >   pair(a_rather_long_type_name, a_rather_long_type_name) same;
  >   defer n++;
  >   mixed.first = n;
  >   mixed.second = 0;
  >   same.first = mixed.first;
  >   same.second = n;
  >   holder.first = 0;
  >   holder.second = same.second;
  >   return (first_of(same));
  > }
  > EOF

The counts that depend only on the source are the same on each
backend; the size of the preprocessed unit, and the charge of lowering
with it, depend on the backend's line markers. The limit is 33554432
bytes and 256 for each byte of the unit.

  $ for cc in $clang $gcc; do
  >   typec --cc=$cc --stats -c counted.tc 2> stats || cat stats
  >   sed 's/^typec: stats: counted.tc: //' stats | tr ' ' '\n' > fields
  >   grep -v '^unit_bytes=\|^output_bytes=\|^output_limit=' fields
  >   eval "$(grep '^unit_bytes=\|^output_bytes=\|^output_limit=' fields)"
  >   [ "$output_limit" -eq $((33554432 + 256 * unit_bytes)) ] &&
  >     [ "$output_bytes" -ge "$unit_bytes" ] &&
  >     [ "$output_bytes" -le "$output_limit" ] || echo "limit: $cc"
  > done
  instance_bytes=3215
  copy_bytes=160
  longest_instance_code=16
  longest_name=23
  instance_bytes=3215
  copy_bytes=160
  longest_instance_code=16
  longest_name=23

Without the option typec reports nothing, and the C that --emit-c
writes is the same with it.

  $ typec --cc=$clang -c counted.tc 2> stats && cat stats
  $ typec --cc=$clang --emit-c counted.tc > plain.c &&
  >   typec --cc=$clang --stats --emit-c counted.tc > counted.c 2> stats &&
  >   cmp plain.c counted.c && grep -c '^typec: stats: counted.tc: ' stats
  1
