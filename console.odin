package main
import win32 "core:sys/windows"
import "core:os"

prev_in_cp  : win32.CODEPAGE
prev_out_cp : win32.CODEPAGE

prev_in_mode  : win32.DWORD
prev_out_mode : win32.DWORD

console_begin :: proc() {
	using win32

	prev_in_cp = GetConsoleCP()
	SetConsoleCP(.UTF8)

	prev_out_cp = GetConsoleOutputCP()
	SetConsoleOutputCP(.UTF8)

	GetConsoleMode(HANDLE(os.stdin), &prev_in_mode)
	in_mode := prev_in_mode
	in_mode &= ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT)
	in_mode |= ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT
	SetConsoleMode(HANDLE(os.stdin), in_mode)

	GetConsoleMode(HANDLE(os.stdout), &prev_out_mode)
	out_mode := prev_out_mode
	out_mode |= ENABLE_VIRTUAL_TERMINAL_PROCESSING
	out_mode &= ~ENABLE_WRAP_AT_EOL_OUTPUT
	SetConsoleMode(HANDLE(os.stdout), out_mode)
}
console_end :: proc() {
	using win32
	SetConsoleMode(HANDLE(os.stdin), prev_in_mode)
	SetConsoleMode(HANDLE(os.stdout), prev_out_mode)
	SetConsoleCP(prev_in_cp)
	SetConsoleOutputCP(prev_out_cp)
}

