/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The interface between the firmware core, firmware.tc or
 * original/firmware.c, and the board that it runs on, which driver.c
 * plays on a hosted system.
 */

#ifndef FIRMWARE_H
#define FIRMWARE_H

/* The firmware's side. */
void	fw_init(void);			/* once, before the others */
void	fw_rx(unsigned char byte);	/* from the UART receive interrupt */
void	fw_poll(void);			/* from the main loop */
int	fw_tx(void);			/* the next byte to send, or -1 */

/* The board's side, which the firmware calls. */
void	board_led(int on);
int	board_temp(void);		/* in degrees Celsius */
_Noreturn void panic(void);

#endif /* !FIRMWARE_H */
