SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

`private` restricts creating values of a type to its owner: constructor
expressions of a private variant and casts to a private distinct type
(design 9.2 rule 1). The owner is the text of the file that declares the
type and, for an interface `M.tci`, the text of the primary source file
`M.tc` (rule 2), whose names compare without their directories. The
word itself lowers to nothing.

  $ cat > ir.tci <<'EOF'
  > # 1 "include/ir.tci" 1
  > type instruction = private
  >     | Move(int dst, int src)
  >     | Halt;
  > type symbol = private distinct unsigned;
  > static inline instruction halt(void) { return Halt; }
  > EOF
  $ (echo '# 1 "src/ir.tc"'; cat ir.tci; cat <<'EOF'
  > # 2 "src/ir.tc" 2
  > instruction make_move(int d, int s) { return instruction.Move(d, s); }
  > symbol intern(unsigned n) { return (symbol)n; }
  > EOF
  > ) > owner.i
  $ ./golden.exe owner.i | grep -v '^# ' | tr -s ' \n' ' ' | sed 's/ $//'; echo
   struct instruction; typedef struct instruction instruction; enum instruction_tag { instruction_Move, instruction_Halt, __tc_tag_max__instruction_tag = 2147483647 }; struct instruction { enum instruction_tag tag; union { struct { int dst ; int src ; } Move; } u; }; typedef unsigned symbol ; static inline instruction halt(void) { return ((struct instruction){ .tag = instruction_Halt }) ; } instruction make_move(int d, int s) { return ((struct instruction){ .tag = instruction_Move, .u.Move = { d, s } }) ; } symbol intern(unsigned n) { return (symbol)n; }

A client matches a private variant, reads its fields through the
bindings, casts a private distinct value to its representation and
makes the zero value; it builds neither.

  $ client() {
  >   (echo '# 1 "client.tc"'; cat ir.tci; echo '# 2 "client.tc" 2'; cat) \
  >     > client.i
  >   ./golden.exe client.i > lowered.c || cat lowered.c
  > }
  $ client <<'EOF'
  > int dst(instruction i) {
  >   match (i) { case Move(d, _): return d; case Halt: return -1; }
  > }
  > unsigned raw(symbol s) { return (unsigned)s; }
  > instruction zero(void) { instruction i = {0}; return i; }
  > symbol none(void) { symbol s = {0}; return s; }
  > symbol empty(void) { return (symbol){0}; }
  > symbol blank(void) { return (symbol){}; }
  > instruction cleared(void) { return (instruction){0}; }
  > EOF

A compound literal is not a cast, so `(T){0}` writes the zero value in
any expression (rule 4); any other value still needs the owner's cast.

  $ client <<'EOF'
  > symbol forged(void) { return (symbol){7}; }
  > EOF
  client.tc:2: error: a value of type 'int' does not convert to 'symbol' without a cast [distinct-conversion]
  $ client <<'EOF'
  > instruction forged(void) { return Move(1, 2); }
  > EOF
  client.tc:2: error: the variant 'instruction' is private to 'include/ir.tci', so only the text of its owner creates its values [private-creation]
  $ client <<'EOF'
  > instruction forged(void) { return instruction.Halt; }
  > EOF
  client.tc:2: error: the variant 'instruction' is private to 'include/ir.tci', so only the text of its owner creates its values [private-creation]
  $ client <<'EOF'
  > typedef symbol name;
  > name forged(void) { return (const name)7; }
  > EOF
  client.tc:3: error: the distinct type 'symbol' is private to 'include/ir.tci', so only the text of its owner creates its values [private-creation]

A `#line` that names the owner changes the presumed location only, so
the text after it is still the client's. (A GNU line marker with the
enter flag in the source can claim any file: `private` is no security
boundary, rule 4.)

  $ client <<'EOF'
  > # 1 "src/ir.tc"
  > instruction forged(void) { return Halt; }
  > EOF
  src/ir.tc:1: error: the variant 'instruction' is private to 'include/ir.tci', so only the text of its owner creates its values [private-creation]

A source file of another name, or `M.tc` included rather than compiled,
is no owner; a private type that a `.tc` file declares belongs to it.

  $ (echo '# 1 "src/main.tc"'; echo '# 1 "src/ir.tc" 1'; cat ir.tci;
  >  echo '# 2 "src/ir.tc" 2'; echo 'symbol s(void) { return (symbol)1; }') \
  >   > included.i
  $ ./golden.exe included.i | tail -n 1
  src/ir.tc:2: error: the distinct type 'symbol' is private to 'include/ir.tci', so only the text of its owner creates its values [private-creation]
  $ printf '# 1 "a.tc"\ntype t = private | A;\nt f(void) { return A; }\n' \
  >   > local.i
  $ ./golden.exe local.i | grep -c 'tag = t_A'
  1
