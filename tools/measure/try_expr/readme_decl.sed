# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# For sed -E. The units of the README's examples that hold a try, each
# try moved to a declaration of its own (try_expr.sh checks that none is
# left in any other place): the three tries inside an expression of
# eval.tc, and the four assignments of copy.tc and pair.tc.

s/^(	*)return \(fit\(\(long long\)try eval\(l\) \+ try eval\(r\)\)\);$/\1{ int left = try eval(l); int right = try eval(r); return (fit((long long)left + right)); }/
s/^(	*)return \(fit\(\(long long\)try eval\(l\) \* try eval\(r\)\)\);$/\1{ int left = try eval(l); int right = try eval(r); return (fit((long long)left * right)); }/
s/^(	*)return \(fit\(\(long long\)try eval\(l\) \/ d\)\);$/\1{ int left = try eval(l); return (fit((long long)left \/ d)); }/
s/^(	*)d = try eval\(r\);$/\1{ int value = try eval(r); d = value; }/
s/^(	*)(in|out) = try open_file\((.*)\);$/\1{ FILE *file = try open_file(\3); \2 = file; }/
s/^(	*)(a|b) = try acquire\((.*)\);$/\1{ int handle = try acquire(\3); \2 = handle; }/
