# Byte Pusher Virtual Machine

A [BytePusher](https://esolangs.org/wiki/BytePusher) virtual machine that translates the one [ByteByteJump](https://esolangs.org/wiki/ByteByteJump) instruction to x86-64 assembly.

## Scope

I wanted to explore Just-In-Time compilers with the hope of maybe writing one for a more complicated instruction set sometimes in the future. This was my "first step" towards that goal. This project's compiler is non-optimizing and so it's not actually any faster than the interpreter from what I could see (note: didn't do any serious benchmarking)

### TODO

- [ ] Audio

### Usage

This application is run from the terminal. A typical command might look like: `./bp-jit ./bin/demo/nyan.bp`

### Building

Most recently built on Zig [v0.11.0-dev.3258+7621e5693](https://github.com/ziglang/zig/tree/7621e5693)

## Dependencies

Dependency | Source
--- | ---
mach-glfw | <https://github.com/hexops/mach-glfw>
zgui | [https://github.com/michal-z/zig-gamedev](https://github.com/michal-z/zig-gamedev/tree/cb46c095dcbf1e86361cde4d6d12ab32ef691842/libs/zgui)
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
