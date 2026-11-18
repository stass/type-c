# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
#
# own_rules: prints the rules of the dependency file on stdin, one line
# each, without the files named by an absolute path. A test names its
# own files by relative paths; a backend may also name files of the
# host, which a test does not pin, as Apple clang 21 on macOS 27 names
# the SDKSettings.json of its SDK even under -MMD and -nostdinc.
own_rules() {
  sed -e ':join' -e '/\\$/{' -e 'N' -e 's/\\\n//' -e 'b join' -e '}' |
    sed -e 's| /[^ ]*||g' -e '/^\//d' -e 's/ *$//' | tr -s ' '
}
