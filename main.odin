package main

import "core:strings"
import "core:fmt"
import "core:os"
import "core:unicode/utf8"
import "core:unicode/utf16"
import "core:terminal/ansi"

import win32 "core:sys/windows"

HEIGHT :: 20

SAVE_CURSOR    :: ansi.CSI + ansi.SCP
RESTORE_CURSOR :: ansi.CSI + ansi.RCP

msg : strings.Builder
input_buffer : strings.Builder

set_msgf :: proc(fmtstr: string, args: ..any) {
	strings.builder_reset(&msg)
	strings.write_string(&msg, fmt.tprintf(fmtstr, args))
}

main :: proc() {
	console_begin()
	defer console_end()
	fmt.print(ansi.CSI + ansi.DECTCEM_HIDE); defer fmt.print(ansi.CSI + ansi.DECTCEM_SHOW)

	strings.builder_init(&input_buffer)
	defer strings.builder_destroy(&input_buffer)

	fmt.print(SAVE_CURSOR); defer fmt.print(RESTORE_CURSOR)

	running := true
	strings.builder_init(&msg); defer strings.builder_destroy(&msg)

	draw()
	for running {
		buf : [2048]u8
		buf[1] = 0
		n_read, err := os.read(os.stdin, buf[:])
		runes := utf8.string_to_runes(cast(string)buf[:n_read]); defer delete(runes)

		key : rune
		for char in runes {
			if char > 31 && char != 127 {
				strings.write_rune(&input_buffer, char)
			} else {
				if char == CTRL_Q || char == CTRL_X || char == CTRL_C {
					running = false
					break
				}
				if char == 127 {
					if strings.builder_len(input_buffer) > 0 {
						str := strings.to_string(input_buffer)
						r, size := utf8.decode_last_rune_in_string(str)
						for i in 0..<size do pop(&input_buffer.buf)
						set_msgf("delete {} bytes.", size)
					}
				} else if char == CTRL_U {
					strings.builder_reset(&input_buffer)
				} else if char == CTRL_W {
					if strings.builder_len(input_buffer) > 0 {
						str := strings.to_string(input_buffer)
						deleted := 0
						confirm : bool
						for {
							r, size := utf8.decode_last_rune_in_string(str[:len(str)-deleted])
							if size == 0 || deleted >= len(str) do break
							if r == ' ' {
								if confirm do break
							} else do confirm = true
							deleted += size
						}
						for d in 0..<deleted {
							pop(&input_buffer.buf)
						}
						set_msgf("delete {} bytes.", deleted)
					}
				}
				key = char
			}
		}
		draw()
	}
	console_end()
}

draw :: proc() {
	fmt.printf(ansi.CSI+ansi.EL)
	fmt.printf("@ {}\n", strings.to_string(msg))
	fmt.printf(ansi.CSI+ansi.EL)
	fmt.printf("> {}\x1b[42m \x1b[49m\n", strings.to_string(input_buffer))
	for h in 0..<HEIGHT do fmt.printf("\n")
	fmt.printf("\x1b[%dA", HEIGHT+2)
	fmt.printf("\x1b[0G") // return to the start
}

ESC :: 0x1b

CTRL_C :: 'C' - 0x40
CTRL_X :: 'X' - 0x40
CTRL_Q :: 'Q' - 0x40
CTRL_W :: 'W' - 0x40
CTRL_U :: 'U' - 0x40
