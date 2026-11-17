# 1 "patterns.tc"
type eval_error = | DivByZero | Overflow;
type res = | Ok(int value) | Err(eval_error error);
type expr = | Num(int value) | Add(const expr *l, const expr *r);
type list = | Nil | Cons(int head, const list *tail);
int evaluate(const expr *e) {
  match (*e) {
  case Add(*Num(a), *Num(b)):
    return a + b;
  case Add(l, r):
    return evaluate(l) + evaluate(r);
  case Num(value):
    return value;
  }
}
int report(res r, const list *l) {
  match (r) {
  case Ok(value):
    return value;
  case Err(DivByZero):
    return -1;
  case Err(eval_error other):
    match (other) { case Overflow: return -2; default: break; }
    break;
  }
  if (case Cons(head, *Nil) = *l)
    return head;
  while (case Cons(_, tail) = *l)
    l = tail;
  return 0;
}
