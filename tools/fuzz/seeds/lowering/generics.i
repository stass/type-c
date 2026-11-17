# 1 "generics.tc"
type list(T) = | Nil | Cons(T head, list(T) *tail);
type pair(A, B) = struct { A first; B second; };
type handle(T) = distinct T *;
generic(T) void swap(T *a, T *b) { T t = *a; *a = *b; *b = t; }
generic(T) int is_even(const T *p, int n);
generic(T) int is_odd(const T *p, int n) { return n ? is_even(p, n - 1) : 0; }
generic(T) int is_even(const T *p, int n) { return n ? is_odd(p, n - 1) : 1; }
pair(list(int) *, handle(long)) p;
int sum(list(int) l) {
  list(int) rest = Nil, first = list(int).Cons(1, &rest);
  swap(&rest, &first);
  match (l) {
  case Nil: return is_odd(&p.second, 3);
  case Cons(head, tail): return head + (tail ? sum(*tail) : 0);
  }
}
