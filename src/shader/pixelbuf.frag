#version 330 core
out vec4 frag_color;

in vec3 color;
in vec2 uv;

uniform sampler2D screen;

void main() {
	frag_color = texture(screen, uv);
}
