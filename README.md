# Rename Man (rnm)

**rnm** is a small terminal-based tool for batch renaming files using regular expressions, with interactive TUI.
It is written in [Odin Lang](https://odin-lang.org/) and currently supports **Windows only**.  
Other platforms' support is planned for the future.

## Usage
Simply run:
`rnm`

You can then edit the **pattern** (regex) and **replacement** fields interactively.  
Press `Enter` to confirm and apply the renaming operation.

### Keybindings

| Key        | Action                          |
|------------|---------------------------------|
| `Tab`      | Switch between pattern and replacement fields |
| `Ctrl-N`   | Scroll down the preview list    |
| `Ctrl-P`   | Scroll up the preview list      |
| `Ctrl-E`   | Insert a pair of parentheses `()` |
| `Ctrl-H`   | Expand the capture range to the left |
| `Ctrl-L`   | Expand the capture range to the right |

### Regex rule


## Build

To build the project:

```
odin build .
```
