#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
#
# Usage: misuse.sh OCAMLC FILE...
#
# Each FILE declares its test in one line, "(* misuse: LIBRARY TEXT *)":
# it is type-checked with LIBRARY opened and passes only when ocamlc
# rejects it (exit code 2) with output that contains TEXT, so a file that
# compiles passes no test, and TEXT is what tells the intended error from
# any other. TEXT is matched with runs of blanks and newlines read as one
# space, because ocamlc wraps its messages. Every FILE runs; the exit
# status says whether all passed.
# MISUSE_CMIS lists the interface files of every library; their
# directories are the include path.

set -efu
: "${MISUSE_CMIS:?}"

ocamlc=$1
shift

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

# Dune's expansion is relative paths without spaces; -f stops globbing.
includes=
for cmi in $MISUSE_CMIS; do
  case "$includes " in
  *" -I ${cmi%/*} "*) ;;
  *) includes="$includes -I ${cmi%/*}" ;;
  esac
done

# Prints a reason and returns 1 when FILE's test fails.
check() {
  file=$1
  spec=
  if [ "$(grep -c '^(\* misuse: ' "$file")" -eq 1 ]; then
    spec=$(sed -n 's/^(\* misuse: \([^ ]*\) \([^ ].*\) \*)$/\1 \2/p' \
      "$file")
  fi
  if [ -z "$spec" ]; then
    echo "$file: needs one '(* misuse: LIBRARY TEXT *)' line" >&2
    return 1
  fi
  library=${spec%% *}
  text=${spec#* }

  status=0
  # -o keeps the .cmi of a file that wrongly compiles out of the build
  # directory. $includes is a list of options, split on purpose.
  # shellcheck disable=SC2086
  "$ocamlc" -stop-after typing $includes -open "$library" \
    -o "$work/unit" -c "$file" >"$work/errors" 2>&1 || status=$?

  if [ "$status" -ne 2 ]; then
    echo "$file: ocamlc exited $status, expected 2" >&2
  elif ! tr -s ' \n' '  ' <"$work/errors" | grep -qF -- "$text"; then
    echo "$file: error does not contain '$text'" >&2
  else
    return 0
  fi
  cat "$work/errors" >&2
  return 1
}

failed=0
for file in "$@"; do
  check "$file" || failed=1
done
exit "$failed"
