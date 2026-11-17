# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Prints a text of `words` words drawn from a vocabulary of `vocab`, the
# same text on every awk: a word's number is the cube of a uniform draw,
# so that a few words are frequent and most are rare, as in prose.  Some
# words are capitalized and some end in punctuation, which wordfreq
# folds and drops.
#
# Usage: awk -v words=N -v vocab=M -f corpus.awk

BEGIN {
	letters = "abcdefghijklmnopqrstuvwxyz"
	# Park and Miller's generator: each product is below 2^46, which a
	# double holds exactly, so awk computes it without rounding.
	seed = 42
	line = ""
	for (n = 1; n <= words; n++) {
		r = next_random() / 2147483647
		word = spell(int(vocab * r * r * r))
		if (next_random() % 7 == 0)
			word = toupper(substr(word, 1, 1)) substr(word, 2)
		if (next_random() % 11 == 0)
			word = word ","
		line = line word
		if (n % 12 == 0) {
			print line "."
			line = ""
		} else {
			line = line " "
		}
	}
	if (line != "")
		print line
}

function next_random() {
	seed = (seed * 16807) % 2147483647
	return seed
}

# The word of number i, its digits in base 26 as letters.
function spell(i,    word) {
	word = ""
	do {
		word = word substr(letters, i % 26 + 1, 1)
		i = int(i / 26)
	} while (i > 0)
	return word
}
