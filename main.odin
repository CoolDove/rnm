package main

import "base:runtime"
import "core:strings"
import "core:fmt"
import "core:mem"
import "core:sort"
import "core:os"
import "core:strconv"
import "core:math"
import "core:text/regex"
import "core:text/edit"
import "core:path/filepath"
import "core:unicode/utf8"
import "core:unicode/utf16"
import "core:terminal/ansi"

import win32 "core:sys/windows"

WIDTH  := 100
HEIGHT := 20

BARS := 4 // the height of bars

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

elements : [dynamic]Element
Element :: struct {
	file : string,

	matched : bool,
	result : strings.Builder,
	capture : regex.Capture,

	// --- for post-process
	repeat_idx : int,
}

view_offset : int

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
	{
		bufinfo : win32.CONSOLE_SCREEN_BUFFER_INFO
		win32.GetConsoleScreenBufferInfo(cast(win32.HANDLE)os.stdout, &bufinfo)
		WIDTH = int(bufinfo.dwSize.X)
		HEIGHT = int(bufinfo.dwSize.Y)
	}

	fmt.print(ansi.CSI + ansi.DECTCEM_HIDE); defer fmt.print(ansi.CSI + ansi.DECTCEM_SHOW)

	read_buffer = make([dynamic]InputEvent, 0, 64); defer delete(read_buffer)

	strings.builder_init(&sb_pattern); defer strings.builder_destroy(&sb_pattern)
	edit.init(&ed_pattern, context.allocator, context.allocator); defer edit.destroy(&ed_pattern)

	strings.builder_init(&sb_replace); defer strings.builder_destroy(&sb_replace)
	edit.init(&ed_replace, context.allocator, context.allocator); defer edit.destroy(&ed_replace)

	edit.begin(&ed_pattern, 36, &sb_pattern); defer edit.end(&ed_pattern)
	edit.begin(&ed_replace, 37, &sb_replace); defer edit.end(&ed_replace)

	current_edit = &ed_pattern

	strings.builder_init(&msg); defer strings.builder_destroy(&msg)

	hdir, err := os.open(os.get_current_directory(context.temp_allocator))
	fis, rdir_err := os.read_dir(hdir, 0)
	for fi in fis do if !fi.is_dir do append(&files, fi.name)
	defer {
		for fi in fis do os.file_info_delete(fi)
		delete(fis)
	}

	draw()
	endcmd := EndCmd.Cancel
	running := true
	string_dirty, visual_dirty := true, true
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
					} else if e.EventType == .WINDOW_BUFFER_SIZE_EVENT {
						size := e.Event.WindowBufferSizeEvent.dwSize
						WIDTH  = int(size.X)
						HEIGHT = int(size.Y)
						visual_dirty = true
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
					string_dirty = true
				} else if escape == "\x1b" {
					// nothing
				}
				// else {
				// 	set_msgf("ansi escape: {} ({})", string(escape[1:]), escape)
				// }
			case InputEventKey:
				kinput := v
				if kinput.vk == win32.VK_LEFT && kinput.mod == 0 {
					edit.move_to(current_edit, .Left)
					visual_dirty = true
				} else if kinput.vk == win32.VK_RIGHT && kinput.mod == 0 {
					edit.move_to(current_edit, .Right)
					visual_dirty = true
				} else if kinput.vk == win32.VK_LEFT && kinput.mod == 1 {
					edit.move_to(current_edit, .Word_Left)
					visual_dirty = true
				} else if kinput.vk == win32.VK_RIGHT && kinput.mod == 1 {
					edit.move_to(current_edit, .Word_Right)
					visual_dirty = true
				} else if kinput.vk == win32.VK_HOME && kinput.mod == 0 {
					edit.move_to(current_edit, .Start)
					visual_dirty = true
				} else if kinput.vk == win32.VK_END && kinput.mod == 0 {
					edit.move_to(current_edit, .End)
					visual_dirty = true
				} else if (kinput.vk == win32.VK_UP || kinput.vk == win32.VK_DOWN) && kinput.mod == 0 {
					switch_edit()
					visual_dirty = true
				}
			case InputEventChar:
				char := v
				if char > 31 && char < 127 {
					edit.input_rune(current_edit, char)
					string_dirty = true
				} else {
					if char == CTRL_Q || char == CTRL_X || char == CTRL_C {
						running = false
						break
					} else if char == ENTER {
						endcmd = .Perform
						running = false
						break
					} else if char == BKSPC {// backspace
						edit.delete_to(current_edit, .Left)
						string_dirty = true
					} else if char == CTRL_U {
						edit.delete_to(current_edit, .Start)
						string_dirty = true
					} else if char == CTRL_K {
						edit.delete_to(current_edit, .End)
						string_dirty = true
					} else if char == CTRL_W {
						edit.delete_to(current_edit, .Word_Left)
						string_dirty = true
					} else if char == CTRL_Z {
						edit.perform_command(current_edit, .Undo)
						string_dirty = true
					} else if char == CTRL_Y {
						edit.perform_command(current_edit, .Redo)
						string_dirty = true
					} else if char == CTRL_E {
						edit.input_text(current_edit, "()")
						edit.move_to(current_edit, .Left)
						string_dirty = true
					} else if char == CTRL_H {
						str := strings.to_string(current_edit.builder^)
						succ : bool
						slc := current_edit.selection.y
						if slc < len(str) {
							b := str[slc]
							if b == '(' || b == ')' {
								edit.delete_to(current_edit, .Right)
								edit.move_to(current_edit, .Left)
								edit.input_rune(current_edit, rune(b))
								edit.move_to(current_edit, .Left)
								succ = true
							}
						}
						if !succ {
							edit.input_text(current_edit, "()")
							edit.move_to(current_edit, .Left)
							edit.move_to(current_edit, .Left)
						}

					} else if char == CTRL_L {
						str := strings.to_string(current_edit.builder^)
						succ : bool
						slc := current_edit.selection.y
						if slc < len(str) {
							b := str[slc]
							if b == '(' || b == ')' {
								edit.delete_to(current_edit, .Right)
								edit.move_to(current_edit, .Right)
								edit.input_rune(current_edit, rune(b))
								edit.move_to(current_edit, .Left)
								succ = true
							}
						}
						if !succ {
							edit.input_text(current_edit, "()")
							edit.move_to(current_edit, .Left)
						}
						string_dirty = true
					} else if char == CTRL_N {
						view_offset += 1
						view_offset = math.clamp(view_offset, 0, max(int(len(elements)-HEIGHT+4+2), 0))
						visual_dirty = true
					} else if char == CTRL_P {
						view_offset -= 1
						view_offset = math.clamp(view_offset, 0, max(int(len(elements)-HEIGHT+4+2), 0))
						visual_dirty = true
					} else if char == TAB {// TAB
						switch_edit()
						visual_dirty = true
					} else {
						// set_msgf("invisible char: %d", char)
						visual_dirty = true
					}
				}
			}
		}
		if string_dirty {
			update_elements()
			view_offset = 0
		}
		if visual_dirty || string_dirty do draw()
		visual_dirty = false
		string_dirty = false
	}
	draw_flush()
	if endcmd == .Perform {
		sum : int
		for e in elements {
			if e.matched {
				to := strings.to_string(e.result)
				os.rename(e.file, to)
				fmt.printf("rename: \x1b[31m{}\x1b[39m -> \x1b[32m{}\x1b[39m\n", e.file, to)
				sum += 1
			}
		}
		fmt.printf("renamed \x1b[33m{}\x1b[39m files.\n", sum)
	} else if endcmd == .Cancel {
		fmt.print("cancelled")
	}
	console_end()
}
EndCmd :: enum {
	Cancel, Perform
}

switch_edit :: proc() {
	if current_edit == &ed_pattern do current_edit = &ed_replace
	else if current_edit == &ed_replace do current_edit = &ed_pattern
	else {
		set_msgf("\x1b[31mERR: current edit is nil\x1b[39m")
		current_edit = &ed_pattern
	}
}

draw_flush :: proc() {
	fmt.printf("\x1b[4B")
	for i in 0..<(HEIGHT-BARS) {
		fmt.print(ERASE_LINE)
		if i < HEIGHT-BARS-1 do fmt.print('\n')
	}
	fmt.printf("\x1b[{}A", HEIGHT-BARS-1)
}
draw :: proc() {
	input := strings.to_string(sb_pattern)

	fmt.printf(ERASE_LINE)
	fmt.printf("@ {}\n", strings.to_string(msg))
	_draw_edit(&ed_pattern, current_edit == &ed_pattern, 'P')
	_draw_edit(&ed_replace, current_edit == &ed_replace, 'R')
	fmt.print(ERASE_LINE)
	fmt.print("────────────────────────────────────────────\n")

	for h in 0..<(HEIGHT-BARS) {
		fmt.printf(ERASE_LINE)// erase line
		if h+view_offset < len(elements) {
			elem := elements[h+view_offset]
			file := elem.file
			if elem.matched {
				fmt.print("\x1b[44m*\x1b[49m")
				fmt.printf(SAVE_CURSOR)
				fmt.printf("\x1b[39m{}", file)
				fmt.print(RESTORE_CURSOR)
				for c, idx in soa_zip(pos=elem.capture.pos, group=elem.capture.groups) {
					if idx == 0 do continue
					for i in 0..<c.pos.x do fmt.print("\x1b[C")
					fmt.printf("\x1b[3{}m{}", (idx-1+5)%6+1, c.group)
					fmt.printf(RESTORE_CURSOR)
				}
				fmt.printf("\x1b[{}C  ->  {}", len(file), strings.to_string(elem.result))
			} else {
				fmt.printf(" \x1b[39m{}", file)
			}
		} else {
			fmt.printf("\x1b[39m")
		}
		if h < HEIGHT-BARS-1 do fmt.print('\n')
	}
	fmt.printf("\x1b[%dA", HEIGHT)
	fmt.printf("\x1b[0G") // return to the start

	_draw_edit :: proc(te: ^edit.State, active: bool, prefix: rune) {
		str : string
		if te.builder != nil do str = strings.to_string(te.builder^)
		fmt.printf(ERASE_LINE)
		if active {
			fmt.printf("{} ", prefix)
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
			fmt.printf("\x1b[49m\x1b[39m{} {}\n", prefix, str)
		}
	}
}

update_elements :: proc() {
	pattern_str := strings.to_string(sb_pattern)
	replace_str := strings.to_string(sb_replace)

	// clear the old data
	clear_elements()

	regx, regx_err := regex.create(pattern_str, {.Unicode, .Case_Insensitive})
	defer regex.destroy_regex(regx)

	repeat_map := make_map_cap(map[string]int, len(files)); defer delete(repeat_map)

	RepeatIdxInsert :: struct {
		file_index : int,
		infile_position : int,
		index_index : int, // which insert pos in this file
	}
	repeat_idx_insert := make([dynamic]RepeatIdxInsert, 0, len(files)); defer delete(repeat_idx_insert)

	n_matched : int
	for f, fidx in files {
		matched : bool
		e : Element
		e.file = f
		if regx_err == nil && pattern_str != {} {
			if capture, ok := regex.match(regx, f); ok {
				e.matched = true
				e.capture = capture
				// ** replace
				sb := &e.result
				strings.builder_init(sb)
				replace_str := strings.to_string(ed_replace.builder^)
				idx := 0

				repeat_idx_count_in_file := 0
				for idx<len(replace_str) {
					using strings
					ignore_char : bool
					if replace_str[idx] == '\\' && idx+1<len(replace_str) {
						d := replace_str[idx+1]
						if d <= '9' && d > '0' {
							value := int(d)-48
							if value < len(capture.groups) {
								write_string(sb, capture.groups[value])
								ignore_char = true
								idx += 1
							}
						} else if d == '\\' {
							write_byte(sb, '\\')
							idx += 1
						} else if d == 'D' {
							append(&repeat_idx_insert, RepeatIdxInsert { fidx, strings.builder_len(sb^), repeat_idx_count_in_file })
							repeat_idx_count_in_file += 1
							ignore_char = true
							idx += 1
						}
					}
					if !ignore_char {
						write_byte(sb, replace_str[idx])
					}
					idx += 1
				}

				n_matched += 1

				result_string := strings.to_string(sb^)
				if current_repeat_count, ok := repeat_map[result_string]; ok {
					repeat_map[result_string] = current_repeat_count + 1
					e.repeat_idx = current_repeat_count
				} else {
					repeat_map[result_string] = 1
					e.repeat_idx = 0
				}
			}
		}
		append(&elements, e)
	}

	{// insert repeat index
		tmp_buffer := scoped_strbdr()
		idxbuffer : [8]u8
		for insrt in repeat_idx_insert {
			elem := &elements[insrt.file_index]
			repeat_idx := elem.repeat_idx
			repeat_idx_str := strconv.itoa(idxbuffer[:], repeat_idx)
			using strings
			builder_reset(tmp_buffer)
			insrt_pos := insrt.infile_position + insrt.index_index * len(repeat_idx_str)
			write_string(tmp_buffer, to_string(elem.result)[insrt_pos:])
			shrink(&elem.result.buf, insrt_pos)
			write_string(&elem.result, repeat_idx_str)
			write_string(&elem.result, to_string(tmp_buffer^))
		}
	}

	elem_slice := elements[:]
	sort.quick_sort_proc(elements[:], 
		proc(a,b: Element) -> int {
			if a.matched && !b.matched do return -1
			else if !a.matched && b.matched do return 1
			else {
				ext_compare := sort.compare_strings(filepath.long_ext(a.file), filepath.long_ext(b.file))
				if ext_compare == 0 do return sort.compare_strings(a.file, b.file)
				return ext_compare
			}
		}
	)
}

clear_elements :: proc() {
	for &e in elements {
		if e.matched {
			regex.destroy_capture(e.capture)
			strings.builder_destroy(&e.result)
		}
	}
	clear(&elements)
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

CTRL_H :rune: 'H' - 0x40
CTRL_L :rune: 'L' - 0x40

CTRL_N :rune: 'N' - 0x40
CTRL_P :rune: 'P' - 0x40

TAB :rune: 9
ENTER :rune: 13

CTRL_E :rune: 'E' - 0x40

BKSPC :rune: 127
