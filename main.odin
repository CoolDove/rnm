package main

import "core:strings"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
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

ed_pattern, ed_replace : edit.State
sb_pattern, sb_replace : strings.Builder

current_edit : ^edit.State

InputEvent :: union {
	InputEventKey,
	InputEventChar,
	InputEventEscape,
}
InputEventEscape :: struct {
	buffer : [32]u8,
	length : int,
}
InputEventKey :: struct {
	vk  : int,
	mod : u8, // ctrl | shift | alt
}
InputEventChar :: rune

read_buffer : [dynamic]InputEvent

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

	read_buffer = make([dynamic]InputEvent, 0, 64); defer delete(read_buffer)

	strings.builder_init(&sb_pattern); defer strings.builder_destroy(&sb_pattern)
	edit.init(&ed_pattern, context.allocator, context.allocator); defer edit.destroy(&ed_pattern)

	strings.builder_init(&sb_replace); defer strings.builder_destroy(&sb_replace)
	edit.init(&ed_replace, context.allocator, context.allocator); defer edit.destroy(&ed_replace)

	edit.begin(&ed_pattern, 36, &sb_pattern); defer edit.end(&ed_pattern)
	edit.begin(&ed_replace, 37, &sb_replace); defer edit.end(&ed_replace)

	current_edit = &ed_pattern

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
		free_all(context.temp_allocator)
		{
			n_events : win32.DWORD
			events : [32]win32.INPUT_RECORD
			if win32.ReadConsoleInputW(cast(win32.HANDLE)os.stdin, &events[0], 32, &n_events) {
				clear(&read_buffer)
				events := events[:n_events]
				escape : [32]u8
				escaping : int
				for e in events {
					if e.EventType == .KEY_EVENT && e.Event.KeyEvent.bKeyDown {
						ascii := cast(u8)e.Event.KeyEvent.uChar.AsciiChar 
						unicd := cast(rune)e.Event.KeyEvent.uChar.UnicodeChar
						if ascii == '\x1b' || escaping > 0 {
							escape[escaping] = ascii
							escaping += 1
						} else {
							append(&read_buffer, unicd)
						}
					}
				}
				if escaping > 0 {
					escp := string(escape[:escaping]) 
					if escp == "\x1b[A" {
						append(&read_buffer, InputEventKey{ win32.VK_UP, 0 })
					} else if escp == "\x1b[B" {
						append(&read_buffer, InputEventKey{ win32.VK_DOWN, 0 })
					} else if escp == "\x1b[C" {
						append(&read_buffer, InputEventKey{ win32.VK_RIGHT, 0 })
					} else if escp == "\x1b[D" {
						append(&read_buffer, InputEventKey{ win32.VK_LEFT, 0 })
					} else if escp == "\x1b[1;5A" {
						append(&read_buffer, InputEventKey{ win32.VK_UP, 1 })
					} else if escp == "\x1b[1;5B" {
						append(&read_buffer, InputEventKey{ win32.VK_DOWN, 1 })
					} else if escp == "\x1b[1;5C" {
						append(&read_buffer, InputEventKey{ win32.VK_RIGHT, 1 })
					} else if escp == "\x1b[1;5D" {
						append(&read_buffer, InputEventKey{ win32.VK_LEFT, 1 })
					} else if escp == "\x1b[H" {
						append(&read_buffer, InputEventKey{ win32.VK_HOME, 0 })
					} else if escp == "\x1b[F" {
						append(&read_buffer, InputEventKey{ win32.VK_END, 0 })
					} else {
						append(&read_buffer, InputEventEscape{escape, escaping})
					}
				}
			}
		}
		edit.update_time(&ed_pattern)
		edit.update_time(&ed_replace)

		inputs := read_buffer[:]
		for input in inputs {
			switch &v in input {
			case InputEventEscape:
				escape := string(v.buffer[:v.length])
				if escape == "\x1b[3~" {// delete
					edit.delete_to(current_edit, .Right)
				} else if escape == "\x1b" {
					// nothing
				} else {
					set_msgf("ansi escape: {} ({})", string(escape[1:]), escape)
				}
			case InputEventKey:
				kinput := v
				if kinput.vk == win32.VK_LEFT && kinput.mod == 0 {
					edit.move_to(current_edit, .Left)
				} else if kinput.vk == win32.VK_RIGHT && kinput.mod == 0 {
					edit.move_to(current_edit, .Right)
				} else if kinput.vk == win32.VK_LEFT && kinput.mod == 1 {
					edit.move_to(current_edit, .Word_Left)
				} else if kinput.vk == win32.VK_RIGHT && kinput.mod == 1 {
					edit.move_to(current_edit, .Word_Right)
				} else if kinput.vk == win32.VK_HOME && kinput.mod == 0 {
					edit.move_to(current_edit, .Start)
				} else if kinput.vk == win32.VK_END && kinput.mod == 0 {
					edit.move_to(current_edit, .End)
				}
			case InputEventChar:
				char := v
				if char > 31 && char < 127 {
					edit.input_rune(current_edit, char)
				} else {
					if char == CTRL_Q || char == CTRL_X || char == CTRL_C {
						running = false
						break
					} else if char == BKSPC {// backspace
						edit.delete_to(current_edit, .Left)
					} else if char == CTRL_U {
						edit.delete_to(current_edit, .Start)
					} else if char == CTRL_K {
						edit.delete_to(current_edit, .End)
					} else if char == CTRL_W {
						edit.delete_to(current_edit, .Word_Left)
					} else if char == CTRL_Z {
						edit.perform_command(current_edit, .Undo)
					} else if char == CTRL_Y {
						edit.perform_command(current_edit, .Redo)
					} else if char == CTRL_E {
						edit.input_text(current_edit, "()")
						edit.move_to(current_edit, .Left)
					} else if char == TAB {// TAB
						if current_edit == &ed_pattern do current_edit = &ed_replace
						else if current_edit == &ed_replace do current_edit = &ed_pattern
						else {
							set_msgf("\x1b[31mERR: current edit is nil\x1b[39m")
							current_edit = &ed_pattern
						}
					} else {
						// set_msgf("invisible char: %d", char)
					}
				}
			}
		}
		draw()
	}
	console_end()
}

draw :: proc() {
	input := strings.to_string(sb_pattern)

	fmt.printf(ERASE_LINE)
	fmt.printf("@ {}\n", strings.to_string(msg))

	_draw_edit(&ed_pattern, current_edit == &ed_pattern)
	_draw_edit(&ed_replace, current_edit == &ed_replace)

	fmt.print("---------------------------------------\n")

	regx, regx_err := regex.create(input, {.Unicode, .Case_Insensitive})
	defer regex.destroy_regex(regx)

	for h in 0..<HEIGHT {
		fmt.printf(ERASE_LINE)// erase line
		if h < len(files) {
			file := files[h]
			if regx_err == nil {
				capture, ok := regex.match(regx, file)
				defer regex.destroy_capture(capture)
				if ok && len(input) > 0 {
					fmt.print("\x1b[44m*\x1b[49m")
					fmt.printf(SAVE_CURSOR)
					fmt.printf("\x1b[39m{}", file)
					fmt.print(RESTORE_CURSOR)
					for c, idx in soa_zip(pos=capture.pos, group=capture.groups) {
						if idx == 0 do continue
						for i in 0..<c.pos.x do fmt.print("\x1b[C")
						fmt.printf("\x1b[3{}m{}", (idx-1+5)%6+1, c.group)
						fmt.printf(RESTORE_CURSOR)
					}
					// ** replace
					sb : strings.Builder
					strings.builder_init(&sb); defer strings.builder_destroy(&sb)
					replacer := strings.to_string(ed_replace.builder^)
					idx := 0
					for idx<len(replacer) {
						using strings
						replaced : bool
						if replacer[idx] == '\\' && idx+1<len(replacer) {
							d := replacer[idx+1]
							if d <= '9' && d > '0' {
								value := int(d)-48
								if value < len(capture.groups) {
									write_string(&sb, capture.groups[value])
									replaced = true
									idx += 1
								}
							} else if d == '\\' {
								write_byte(&sb, '\\')
								idx += 1
							}
						}
						if !replaced {
							write_byte(&sb, replacer[idx])
						}
						idx += 1
					}
					fmt.printf("\x1b[%d%s -> \x1b[33m{}\x1b[39m\n", len(file)+1, ansi.CUF, strings.to_string(sb))
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
	fmt.printf("\x1b[%dA", HEIGHT+4)
	fmt.printf("\x1b[0G") // return to the start

	_draw_edit :: proc(te: ^edit.State, active: bool) {
		str : string
		if te.builder != nil do str = strings.to_string(te.builder^)
		fmt.printf(ERASE_LINE)
		if active {
			fmt.print("> ")
			if len(str) > 0 {// draw the text
				slc := te.selection
				if slc.x == slc.y {
					fmt.printf("\x1b[49m\x1b[39m{}", str[:slc.x])
					if slc.x == len(str) {
						fmt.print("\x1b[42m\x1b[30m \x1b[39m\x1b[49m")
					} else {
						fmt.printf("\x1b[42m\x1b[30m{}\x1b[39m\x1b[49m", rune(str[slc.x]))
						if slc.x < len(str)-1 do fmt.print(str[slc.x+1:])
					}
				}
			} else {
				fmt.print("\x1b[42m\x1b[30m \x1b[39m\x1b[49m")
			}
			fmt.print("\n")
		} else {
			fmt.printf("\x1b[49m\x1b[39m> {}\n", str)
		}
	}
}

ESC :: 0x1b

CTRL_C :rune: 'C' - 0x40
CTRL_X :rune: 'X' - 0x40
CTRL_Q :rune: 'Q' - 0x40
CTRL_W :rune: 'W' - 0x40
CTRL_U :rune: 'U' - 0x40
CTRL_Z :rune: 'Z' - 0x40
CTRL_Y :rune: 'Y' - 0x40
CTRL_K :rune: 'K' - 0x40
TAB :rune: 9

CTRL_E :rune: 'E' - 0x40

BKSPC :rune: 127
