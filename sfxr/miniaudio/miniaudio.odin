// On-demand miniaudio decoder for sfxr parameters

package sfxr_ma

import "core:runtime"
import "core:slice"

import ma "vendor:miniaudio"

import sfxr ".."


Generator :: struct {
	base: ma.data_source_base,
	playback: sfxr.Playback_State,
	odin_context: runtime.Context,
}

generator_init :: proc {
	generator_init_params,
	generator_init_bin,
}

generator_init_params :: proc(g: ^Generator, parameters: sfxr.Params, sample_rate := 44100) -> ma.result {
	cfg := ma.data_source_config_init()
	cfg.vtable = &g_sfxr_vtable
	status := ma.data_source_init(&cfg, cast(^ma.data_source) &g.base)
	if status != .SUCCESS {
		return status
	}
	if sfxr.playback_init(&g.playback, parameters, sample_rate) != .Ok {
		return .ERROR
	}
	g.odin_context = context
	return .SUCCESS
}

generator_init_bin :: proc(g: ^Generator, data: []u8, sample_rate := 44100) -> ma.result {
	cfg := ma.data_source_config_init()
	cfg.vtable = &g_sfxr_vtable
	status := ma.data_source_init(&cfg, cast(^ma.data_source) &g.base)
	if status != .SUCCESS {
		return status
	}
	params: sfxr.Params
	if sfxr.from_bin(&params, data) != .Ok {
		return .INVALID_ARGS
	}
	if sfxr.playback_init(&g.playback, params, sample_rate) != .Ok {
		return .ERROR
	}
	g.odin_context = context
	return .SUCCESS
}

create_sound :: proc {
	create_sound_params,
	create_sound_bin,
}

create_sound_params :: proc(engine: ^ma.engine, params: sfxr.Params, sample_rate := 44100, allocator := context.allocator) -> (sound: ^ma.sound, status: ma.result) {
	generator := new(Generator, allocator)
	defer if status != .SUCCESS {
		free(generator)
	}
	status = generator_init_params(generator, params, sample_rate)
	if status != .SUCCESS {
		return nil, status
	}

	sound = new(ma.sound, allocator)
	defer if status != .SUCCESS {
		free(sound)
	}
	status = ma.sound_init_from_data_source(engine, cast(^ma.data_source) generator, 0, nil, sound)
	if status != .SUCCESS {
		return nil, status
	}
	return sound, .SUCCESS
}

create_sound_bin :: proc(engine: ^ma.engine, data: []u8, sample_rate := 44100, allocator := context.allocator) -> (sound: ^ma.sound, status: ma.result) {
	generator := new(Generator, allocator)
	defer if status != .SUCCESS {
		free(generator)
	}
	status = generator_init_bin(generator, data, sample_rate)
	if status != .SUCCESS {
		return nil, status
	}

	sound = new(ma.sound, allocator)
	defer if status != .SUCCESS {
		free(sound)
	}
	status = ma.sound_init_from_data_source(engine, cast(^ma.data_source) generator, 0, nil, sound)
	if status != .SUCCESS {
		return nil, status
	}
	return sound, .SUCCESS
}

destroy_sound :: proc(sound: ^ma.sound) {
	// NOTE: this works iff this sound was created with any of the create_sound* procs
	free(sound.pDataSource)
	free(sound)
}

@private
g_sfxr_vtable := ma.data_source_vtable {
	generator_read,
	generator_seek,
	generator_get_data_format,
	generator_get_cursor,
	generator_get_length,
	generator_on_set_looping,
	0,
}

@private
generator_read :: proc "c" (ds: ^ma.data_source, p_frames_out: rawptr, frame_count: u64, p_frames_read: ^u64) -> ma.result {
	g := cast(^Generator) ds
	context = g.odin_context
	buffer := slice.from_ptr(cast([^]f32) p_frames_out, int(frame_count))
	n_read, err := sfxr.generate_into_buffer(buffer, &g.playback)
	if err == .Ok {
		p_frames_read^ = u64(n_read)
		return .SUCCESS
	} else {
		return .ERROR
	}
}

@private
generator_seek :: proc "c" (ds: ^ma.data_source, frame_index: u64) -> ma.result {
	if frame_index == 0 {
		g := cast(^Generator) ds
		context = g.odin_context
		sfxr.playback_reset(&g.playback)
		return .SUCCESS
	}
	return .BAD_SEEK
}

@private
generator_get_data_format :: proc "c" (ds: ^ma.data_source, p_data_format: ^ma.format, p_channels: ^u32, p_sample_rate: ^u32, p_channel_map: [^]ma.channel, channel_map_cap: uint) -> ma.result {
	g := cast(^Generator) ds
	p_data_format^ = .f32
	p_channels^ = 1
	p_sample_rate^ = u32(g.playback.sample_rate)
	if channel_map_cap >= 1 && p_channel_map != nil {
		p_channel_map[0] = .MONO
	}
	return .SUCCESS
}

@private
generator_get_cursor :: proc "c" (ds: ^ma.data_source, p_cursor: ^u64) -> ma.result{
	p_cursor^ = u64((cast(^Generator) ds).playback.t)
	return .SUCCESS
}

@private
generator_get_length :: proc "c" (ds: ^ma.data_source, p_length: ^u64) -> ma.result {
	return .NOT_IMPLEMENTED
}

@private
generator_on_set_looping :: proc "c" (ds: ^ma.data_source, isLooping: b32) -> ma.result {
	return .NOT_IMPLEMENTED
}
