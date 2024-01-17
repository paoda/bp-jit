# Byte Pusher Virtual Machine

A [BytePusher](https://esolangs.org/wiki/BytePusher) virtual machine that translates the one [ByteByteJump](https://esolangs.org/wiki/ByteByteJump) instruction to x86-64 assembly.

## Scope

I wanted to explore Just-In-Time compilers with the hope of maybe writing one for a more complicated instruction set sometimes in the future. This was my "first step" towards that goal. This project's compiler is non-optimizing and so it's not actually any faster than the interpreter from what I could see (note: didn't do any serious benchmarking)

### TODO

- [ ] Audio

### Usage

This application is run from the terminal. A typical command might look like: `./bp-jit ./bin/demo/nyan.bp`

### Building

Most recently built on Zig [v2024.1.0-mach](https://github.com/ziglang/zig/tree/804cee3b9)

## Dependencies

Dependency | Source
--- | ---
mach-glfw | <https://github.com/hexops/mach-glfw>
zgui | [https://github.com/michal-z/zig-gamedev](https://github.com/zig-gamedev/zig-gamedev/tree/51bf33b8eb3e8bf5d42f6192b49df5571923e6a0/libs/zgui)
zig-clap | <https://github.com/Hejsil/zig-clap>
`gl.zig` | <https://github.com/MasterQ32/zig-opengl>

`gl.zig` is an auto-generated file providing bindings for [OpenGL](https://www.opengl.org/)

## Controls

The BytePusher inherits the [CHIP-8](https://en.wikipedia.org/wiki/CHIP-8) set of controls. In this project, they're defined as:

    +---+---+---+---+
    | 1 | 2 | 3 | 4 |
    +---+---+---+---+
    | Q | W | E | R |
    +---+---+---+---+
    | A | S | D | F |
    +---+---+---+---+
    | Z | X | C | V |
    +---+---+---+---+
