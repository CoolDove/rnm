package main

import "core:strings"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:text/regex"
import "core:text/edit"
import "core:path/filepath"
import "core:unicode/utf8"
import "core:unicode/utf16"
import "core:terminal/ansi"

import win32 "core:sys/windows"

HEIGHT :: 20

SAVE_CURSOR    :: ansi.CSI + ansi.SCP
RESTORE_CURSOR :: ansi.CSI + ansi.RCP
ERASE_LINE     :: ansi.CSI+ansi.EL

msg : strings.Builder
// input_buffer : strings.Builder // gap buffer this

ed_pattern, ed_replace : edit.State
sb_pattern, sb_replace : strings.Builder

set_msgf :: proc(fmtstr: string, args: ..any, location := #caller_location) {
	strings.builder_reset(&msg)
	if len(args)>0 do strings.write_string(&msg, fmt.tprintf(fmtstr, ..args))
	else do strings.write_string(&msg, fmtstr)
	strings.write_string(&msg, fmt.tprintf("\t\x1b[34m{}\x1b[39m", location))
}

files : [dynamic]string

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	console_begin()
	defer console_end()

	fmt.print(ansi.CSI + ansi.DECTCEM_HIDE); defer fmt.print(ansi.CSI + ansi.DECTCEM_SHOW)


	// init datas
	files = make([dynamic]string); defer delete(files)

	strings.builder_init(&sb_pattern); defer strings.builder_destroy(&sb_pattern)
	edit.init(&ed_pattern, context.allocator, context.allocator); defer edit.destroy(&ed_pattern)

	strings.builder_init(&sb_replace); defer strings.builder_destroy(&sb_replace)
	edit.init(&ed_replace, context.allocator, context.allocator); defer edit.destroy(&ed_replace)

	edit.begin(&ed_pattern, 36, &sb_pattern); defer edit.end(&ed_pattern)
	edit.begin(&ed_replace, 37, &sb_replace); defer edit.end(&ed_replace)

	running := true
	strings.builder_init(&msg); defer strings.builder_destroy(&msg)

	hdir, err := os.open(os.get_current_directory(context.temp_allocator))
	fis, rdir_err := os.read_dir(hdir, 0); defer delete(fis)
	for i in fis {
		if !i.is_dir {
			append(&files, i.name)
		}
	}
	defer {
		for i in fis {
			os.file_info_delete(i)
		}
	}

	draw()
	for running {
		buf : [8]u8
		buf[1] = 0
		n_read, err := os.read(os.stdin, buf[:])

		set_msgf("key: {}, {}", string(buf[:n_read]), buf[:n_read])
		runes := utf8.string_to_runes(cast(string)buf[:n_read]); defer delete(runes)

		edit.update_time(&ed_pattern)
		edit.update_time(&ed_replace)

		key : rune
		for char in runes {
			if char > 31 && char != 127 {
				edit.input_rune(&ed_pattern, char)
				// set_msgf("input rune, {}", ed_pattern.builder)
			} else {
				if char == CTRL_Q || char == CTRL_X || char == CTRL_C {
					running = false
					break
				}
				if char == 127 {// backspace
					edit.delete_to(&ed_pattern, .Left)
				} else if char == CTRL_U {
					edit.delete_to(&ed_pattern, .Start)
				} else if char == CTRL_W {
					edit.delete_to(&ed_pattern, .Word_Left)
				} else if char == CTRL_N {
					edit.perform_command(&ed_pattern, .Undo)
				} else if char == CTRL_Y {
					edit.perform_command(&ed_pattern, .Redo)
				}
				key = char
			}
		}
		draw()
	}
	console_end()
}

draw :: proc() {
	// input := strings.to_string(input_buffer)
	input : string
	if ed_pattern.builder != nil do input = strings.to_string(sb_pattern)

	fmt.printf(ERASE_LINE)
	fmt.printf("@ {}\n", strings.to_string(msg))
	fmt.printf(ERASE_LINE)
	fmt.printf("> {}\x1b[42m \x1b[49m\n", input)

	regx, regx_err := regex.create(input, {.Unicode, .Case_Insensitive})
	defer regex.destroy_regex(regx)

	sb : strings.Builder
	strings.builder_init(&sb); defer strings.builder_destroy(&sb)
	for h in 0..<HEIGHT {
		fmt.printf(ERASE_LINE)// erase line
		if h < len(files) {
			file := files[h]
			if regx_err == nil {
				capture, ok := regex.match(regx, file)
				defer regex.destroy_capture(capture)
				if ok && len(input) > 0 {
					fmt.print(' ')
					fmt.printf(SAVE_CURSOR)
					fmt.printf("\x1b[39m{}", file)
					fmt.print(RESTORE_CURSOR)
					for c, idx in soa_zip(pos=capture.pos, group=capture.groups) {
						for i in 0..<c.pos.x do fmt.print("\x1b[C")
						fmt.printf("\x1b[33m{}", c.group)
						fmt.printf(RESTORE_CURSOR)
					}
					fmt.printf("\x1b[%d%s  (capture {} groups: {})\n", len(file)+1, ansi.CUF, len(capture.pos), soa_zip(pos=capture.pos, group=capture.groups))
				} else {
					fmt.printf(" \x1b[39m{}\n", files[h])
				}
			} else {
				fmt.printf(" \x1b[39m{}\n", files[h])
			}
		} else {
			fmt.printf("\x1b[39m\n")
		}
	}
	fmt.printf("\x1b[%dA", HEIGHT+2)
	fmt.printf("\x1b[0G") // return to the start
}

ESC :: 0x1b

CTRL_C :rune: 'C' - 0x40
CTRL_X :rune: 'X' - 0x40
CTRL_Q :rune: 'Q' - 0x40
CTRL_W :rune: 'W' - 0x40
CTRL_U :rune: 'U' - 0x40
CTRL_N :rune: 'N' - 0x40
CTRL_Y :rune: 'Y' - 0x40
