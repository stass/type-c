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
  >   grep -v '^unit_bytes=\|^output_bytes=\|^output_limit=' fields |
  >     grep -v '^slice_\|^selection_'
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

The slice tests that lowering writes are counted by form: an index, a
`slice_sub` and a conversion that C evaluates, and so tested; those
that C does not evaluate, wherever they stand; and, among the indexes
and `slice_sub`s that are tested, those that hold a call or a statement
expression in an operand after the first (design section 8 rule 10).
Each instance of a generic function counts its own tests, and the
slice itself is the first operand, so a call that makes it counts for
no test.

  $ cat > slices.tc <<'EOF'
  > #include <stddef.h>
  > extern slice(int) global;
  > int sized[sizeof(global[0])];
  > size_t next(void);
  > slice(int) make(void);
  > generic(T) T
  > at(slice(T) s, size_t i)
  > {
  >   return (s[i]);
  > }
  > int
  > use(slice(int) s, slice(long) l, size_t i)
  > {
  >   slice(const int) c = s;
  >   slice(int) part = slice_sub(s, i, i + 1);
  >   long width = sizeof(s[3]) + sizeof(slice_sub(s, 1, 2));
  >   return (make()[i] + s[next()] + at(s, i) + at(l, i)
  >       + part[__extension__ ({ i; })] + c[i]
  >       + slice_sub(s, next(), 3).len + slice_sub(s, 0, next()).len);
  > }
  > EOF
  $ typec --cc=$clang --stats -c slices.tc 2> stats || cat stats
  $ tr ' ' '\n' < stats | grep '^slice_'
  slice_indexes=6
  slice_subs=3
  slice_conversions=1
  slice_untested=3
  slice_late_calls=4

The selection of a match or a test is counted by what building its tree
took (design 4.7 rule 10, P32): the steps of selection, the nodes of the
tree and the nodes on its deepest path, each the most over the matches
and tests of the unit and of each instance it uses, and zero where it
has none. A match on the tags of a variant, with two labels, takes eight
steps and is one node. A match with a label that follows a pointer takes
ten steps to a tree of two nodes, one under the other, and an instance
of a generic function counts its own.

  $ cat > flat.tc <<'EOF'
  > type list = | Nil | Cons(int head, const list *tail);
  > int flat(const list *l)
  > {
  >   match (*l) {
  >   case Nil:
  >     return 0;
  >   case Cons(h, t):
  >     return h;
  >   }
  > }
  > EOF
  $ cat > deep.tc <<'EOF'
  > type list = | Nil | Cons(int head, const list *tail);
  > int deep(const list *l)
  > {
  >   match (*l) {
  >   case Cons(_, *Nil):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ cat > bare.tc <<'EOF'
  > int none(void)
  > {
  >   return 0;
  > }
  > EOF
  $ cat > inst.tc <<'EOF'
  > type list = | Nil | Cons(int head, const list *tail);
  > generic(T) int
  > deep(T x, const list *l)
  > {
  >   match (*l) {
  >   case Cons(_, *Nil):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > int use(const list *l)
  > {
  >   return deep(1, l);
  > }
  > EOF
  $ for unit in flat deep bare inst; do
  >   typec --cc=$clang --stats -c $unit.tc 2> stats || cat stats
  >   tr ' ' '\n' < stats | grep '^selection_' | tr '\n' ' '
  >   echo
  > done
  selection_steps=8 selection_nodes=1 selection_depth=1 
  selection_steps=10 selection_nodes=2 selection_depth=2 
  selection_steps=0 selection_nodes=0 selection_depth=0 
  selection_steps=10 selection_nodes=2 selection_depth=2 
