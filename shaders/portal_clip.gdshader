shader_type spatial;
// portal_clip.gdshader — 傳送門表面
//
// 以螢幕座標 SCREEN_UV 取樣「虛擬攝影機」渲染出的 SubViewport 貼圖，
// 所以門看起來就是一扇真正的窗：不論從哪個角度看，內容都與主攝影機的視角連續。
// 同一個 shader 用在平面（quad）與近距離時的 U 型凹陷盒（側壁、背板同樣用螢幕座標取樣，因此看起來是無縫的）。
//
// clip：丟棄門平面「前側」（法線朝向房內那一側）的片元。
//   預設關閉；只對凹陷盒啟用，確保盒子不會有任何片元穿出門平面、擋在鏡頭與門之間。
//   （各房間是凸長方體，目的地的幾何本來就都在門平面後方，所以這裡是安全網而不是主要機制。）

render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D viewport_tex : source_color, filter_linear, repeat_disable;
uniform vec4 fog_color : source_color = vec4(0.07, 0.08, 0.12, 1.0);
uniform float fog_amount : hint_range(0.0, 1.0) = 0.0;

uniform bool clip_enabled = false;
// 世界空間平面：xyz = 指向房內的單位法線，w = −dot(法線, 門中心)。 dot(n,p)+w > clip_margin 即在前側。
uniform vec4 clip_plane = vec4(0.0, 0.0, 1.0, 0.0);
uniform float clip_margin = 0.004;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (clip_enabled && dot(clip_plane.xyz, world_pos) + clip_plane.w > clip_margin) {
		discard;
	}
	vec3 seen = texture(viewport_tex, SCREEN_UV).rgb;
	ALBEDO = mix(seen, fog_color.rgb, fog_amount);
}
