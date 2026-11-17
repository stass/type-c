/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The measured forms: run_X(v, n) calls form X of forms.tc for each of
 * the n values of v and returns a checksum of the values and the errors.
 */

#ifndef FORMS_H
#define	FORMS_H

long	run_a(const int *v, long n);
long	run_b(const int *v, long n);
long	run_c(const int *v, long n);
long	run_d(const int *v, long n);
long	run_e(const int *v, long n);
long	run_f(const int *v, long n);
long	run_g(const int *v, long n);
long	run_h(const int *v, long n);
long	run_i(const int *v, long n);

#endif /* !FORMS_H */
