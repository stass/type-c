# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# For sed -E. toml.tc of Pilot B with each try that is the right operand
# of an assignment moved to a declaration of its own, in a block of its
# own since two of the assignments are the substatement of an if
# (try_expr.sh checks that no try is left in any other place). The type of
# each declaration is that of the function's result.

s/^( *)([^ ]+) = try (expand_ptrarr|xcalloc)\((.*)\);$/\1{ void *moved = try \3(\4); \2 = moved; }/
s/^( *)([^ ]+) = try (xstrndup|xstrdup)\((.*)\);$/\1{ char *moved = try \3(\4); \2 = moved; }/
s/^( *)([^ ]+) = try (append_table|create_keytable_in_table)\((.*)\);$/\1{ toml_table_t *moved = try \3(\4); \2 = moved; }/
s/^( *)([^ ]+) = try (create_keyarray_in_table)\((.*)\);$/\1{ toml_array_t *moved = try \3(\4); \2 = moved; }/
