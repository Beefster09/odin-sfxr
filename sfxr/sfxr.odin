package sfxr


import "core:encoding/json"
import "core:intrinsics"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:reflect"
import "core:runtime"
import "core:strconv"


Wave_Shape :: enum i32 {
	Square   = 0,
	Sawtooth = 1,
	Sine     = 2,
	Noise    = 3,
}

Params :: struct {
	// should match original serialization order and versioning
	// see https://github.com/grimfang4/sfxr/blob/master/sfxr/source/main.cpp#L196
	wave_type: Wave_Shape,

	sound_vol: f32 `v:"102"`,

	//  Tone
	base_freq:     f32 `json:"p_base_freq"`,     // Start frequency
	freq_limit:    f32 `json:"p_freq_limit"`,    // Min frequency cutoff
	freq_ramp:     f32 `json:"p_freq_ramp"`,     // Slide (SIGNED)
	freq_dramp:    f32 `json:"p_freq_dramp" v:"101"`,    // Delta slide (SIGNED)

	//  Square wave duty (proportion of time signal is high vs. low)
	duty:          f32 `json:"p_duty"`,          // Square duty
	duty_ramp:     f32 `json:"p_duty_ramp"`,     // Duty sweep (SIGNED)

	//  Vibrato
	vib_strength:  f32 `json:"p_vib_strength"`,  // Vibrato depth
	vib_speed:     f32 `json:"p_vib_speed"`,     // Vibrato speed
	vib_delay:     f32, // not in jsfxr

	//  Envelope
	env_attack:    f32 `json:"p_env_attack"`,    // Attack time
	env_sustain:   f32 `json:"p_env_sustain"`,   // Sustain time
	env_decay:     f32 `json:"p_env_decay"`,     // Decay time
	env_punch:     f32 `json:"p_env_punch"`,     // Sustain punch

	filter_on: bool, // not in jsfxr
	//  Low-pass filter
	lpf_resonance: f32 `json:"p_lpf_resonance"`, // Low-pass filter resonance
	lpf_freq:      f32 `json:"p_lpf_freq"`,      // Low-pass filter cutoff
	lpf_ramp:      f32 `json:"p_lpf_ramp"`,      // Low-pass filter cutoff sweep (SIGNED)

	//  High-pass filter
	hpf_freq:      f32 `json:"p_hpf_freq"`,      // High-pass filter cutoff
	hpf_ramp:      f32 `json:"p_hpf_ramp"`,      // High-pass filter cutoff sweep (SIGNED)

	//  Flanger
	pha_offset:    f32 `json:"p_pha_offset"`,    // Flanger offset (SIGNED)
	pha_ramp:      f32 `json:"p_pha_ramp"`,      // Flanger sweep (SIGNED)

	//  Repeat
	repeat_speed:  f32 `json:"p_repeat_speed"`,  // Repeat speed

	//  Tonal change
	arp_mod:       f32 `json:"p_arp_mod" v:"101"`,       // Change amount (SIGNED)
	arp_speed:     f32 `json:"p_arp_speed" v:"101"`,     // Change speed
}
SERIAL_PARAMS_SIZE :: size_of(Params) + size_of(i32) - 3  // i32 version, accounts for padding after filter_on
PARAMS_CURRENT_VERSION :: 102

Error :: enum {
	Ok = 0,
	Invalid_Data,
	Allocation_Failure,
	Buffer_Too_Small,

	Unknown = -1,
	Not_Implemented = -2,
}

generate_8bit :: #force_inline proc(
	ps: ^Params,
	sample_rate: int = 44100,
	db_gain: f32 = 0,
	seed: Maybe(u64) = nil,
	allocator := context.allocator,
) -> ([]u8, Error) {
	return generate_pcm(u8, ps, sample_rate, db_gain, seed, allocator)
}

generate_pcm :: proc(
	$T: typeid,
	ps: ^Params,
	sample_rate: int = 44100,
	db_gain: f32 = 0,
	seed: Maybe(u64) = nil,
	allocator := context.allocator,
) -> (pcm_samples: []T, err: Error) {
	pb: Playback_State
	playback_init(&pb, ps, sample_rate, seed)

	est_samples := math.sum(pb.envelope_length[:])
	buffer, alloc_err := make([dynamic]T, 0, est_samples, allocator)
	if alloc_err != .None {
		return nil, .Allocation_Failure
	}
	defer if err == .Ok {
		runtime.shrink(&buffer, len(buffer))
	} else {
		delete(buffer)
	}

	for {
		chunk: [4096]T
		n, gen_err := generate_into_buffer(chunk[:], &pb, db_gain)
		if gen_err != .Ok {
			return nil, gen_err
		}
		if n > 0 {
			append(&buffer, ..chunk[:n])
		}
		if n < 4096 { break }
	}

	return buffer[:], .Ok
}

Playback_State :: struct {
	parameters: Params,

	t: int,
	repeat_time: int,
	elapsed_since_repeat: int,

	period, period_max: f32,
	enable_frequency_cutoff: bool,
	period_mult, period_mult_slide: f32,
	duty_cycle, duty_cycle_slide: f32,
	arpeggio_multiplier: f32,
	arpeggio_time: int,

	fltw, fltw_d: f32,
	flthp, flthp_d: f32,
	fltdmp: f32,
	fltp, fltdp, fltphp: f32,

	vibrato_speed: f32,
	vibrato_amplitude: f32,
	vibrato_phase: f32,

	envelope_length: [3]int,
	envelope_stage: int,
	envelope_elapsed: int,

	flanger_buffer: [1024]f32,
	flanger_offset: f32,
	flanger_offset_slide: f32,

	noise_buffer: [32]f32,
	rand_state: rand.Rand,

	phase: int,
	ipp: int,

	sample_rate: int,
	oversampling: int,
	sample_sum: f32,
	num_summed: int,
	summands: f32,
}
@private ENV_ATTACK  :: 0
@private ENV_SUSTAIN :: 1
@private ENV_DECAY   :: 2

playback_init :: proc(pb: ^Playback_State, parameters: ^Params, sample_rate: int, seed: Maybe(u64) = nil) {
	pb.parameters = parameters^
	_playback_init_for_repeat(pb)
	ps := pb.parameters

	rand.init(&pb.rand_state, seed.(u64) or_else u64(intrinsics.read_cycle_counter()))

	pb.fltw = math.pow(ps.lpf_freq, 3) * 0.1
	pb.fltw_d = 1 + ps.lpf_ramp * 0.0001
	pb.fltdmp = clamp(5 / (1 + math.pow(ps.lpf_resonance, 2) * 20) * (0.01 + pb.fltw), 0, 0.8)
	pb.flthp = math.pow(ps.hpf_freq, 2) * 0.1
	pb.flthp_d = 1 + ps.hpf_ramp * 0.0003

	// Vibrato
	pb.vibrato_speed = math.pow(ps.vib_speed, 2) * 0.01
	pb.vibrato_amplitude = ps.vib_strength * 0.5

	// Envelope
	pb.envelope_length = {
		int(ps.env_attack  * ps.env_attack  * 100_000),
		int(ps.env_sustain * ps.env_sustain * 100_000),
		int(ps.env_decay   * ps.env_decay   * 100_000),
	}

	// Flanger
	pb.flanger_offset = 1020 * math.pow(ps.pha_offset, 2) * math.sign(ps.pha_offset)
	pb.flanger_offset_slide = math.pow(ps.pha_ramp, 2) * math.sign(ps.pha_ramp)

	// Repeat
	repeat_time := int(math.pow(1 - ps.repeat_speed, 2) * 20_000 + 32)
	if ps.repeat_speed == 0 {
		repeat_time = 0
	}

	pb.fltp = 0
	pb.fltdp = 0
	pb.fltphp = 0

	for _, i in pb.noise_buffer {
		pb.noise_buffer[i] = rand.float32_range(-1, 1, &pb.rand_state)
	}

	pb.envelope_stage   = 0
	pb.envelope_elapsed = 0

	pb.vibrato_phase = 0

	pb.phase = 0
	pb.ipp   = 0
	mem.zero(&pb.flanger_buffer[0], size_of(f32) * len(pb.flanger_buffer))

	pb.oversampling = 8
	pb.sample_rate = sample_rate
	pb.sample_sum = 0
	pb.num_summed = 0
	pb.summands = 44100 / f32(sample_rate)

	pb.t = 0
}

@private
_playback_init_for_repeat :: proc(pb: ^Playback_State) {
	ps := pb.parameters
	pb.elapsed_since_repeat = 0

	pb.period     = 100 / (ps.base_freq  * ps.base_freq  + 0.001)
	pb.period_max = 100 / (ps.freq_limit * ps.freq_limit + 0.001)
	pb.enable_frequency_cutoff = ps.freq_limit > 0
	pb.period_mult    = 1 - math.pow(ps.freq_ramp, 3)  * 0.01
	pb.period_mult_slide = -math.pow(ps.freq_dramp, 3) * 0.000001

	pb.duty_cycle = 0.5 - ps.duty * 0.5
	pb.duty_cycle_slide = -ps.duty_ramp * 0.00005

	if ps.arp_mod >= 0 {
		pb.arpeggio_multiplier = 1 - math.pow(ps.arp_mod, 2) * .9
	}
	else {
		pb.arpeggio_multiplier = 1 + math.pow(ps.arp_mod, 2) * 10
	}
	pb.arpeggio_time = int(math.pow(1 - ps.arp_speed, 2) * 20000 + 32)
	if ps.arp_speed == 1 {
		pb.arpeggio_time = 0
	}
}

generate_into_buffer :: proc(
	buffer: []$T,
	pb: ^Playback_State,
	db_gain: f32 = 0,
) -> (num_samples_written: int, err: Error)  where intrinsics.type_is_numeric(T) {
	using pb
	ps := pb.parameters

	linear_gain := math.pow(10, db_gain / 10) * (math.exp(ps.sound_vol) - 1)

	for num_samples_written < len(buffer) {
		// Repeats
		if repeat_time != 0 {
			pb.elapsed_since_repeat += 1
			if pb.elapsed_since_repeat >= repeat_time {
				_playback_init_for_repeat(pb)
			}
		}

		// Arpeggio (single)
		if(pb.arpeggio_time != 0 && t >= pb.arpeggio_time) {
			pb.arpeggio_time = 0
			pb.period *= pb.arpeggio_multiplier
		}

		// Frequency slide, and frequency slide slide!
		pb.period_mult += pb.period_mult_slide
		pb.period *= pb.period_mult
		if pb.period > pb.period_max {
			pb.period = pb.period_max
			if pb.enable_frequency_cutoff {
				break
			}
		}

		// Vibrato
		rfperiod := pb.period
		if (vibrato_amplitude > 0) {
			vibrato_phase += vibrato_speed
			rfperiod = pb.period * (1 + math.sin(vibrato_phase) * vibrato_amplitude)
		}
		iperiod := max(int(rfperiod), pb.oversampling)

		// Square wave duty cycle
		pb.duty_cycle = clamp(pb.duty_cycle + pb.duty_cycle_slide, 0, 0.5)

		// Volume envelope
		envelope_elapsed += 1
		if envelope_elapsed > envelope_length[envelope_stage] {
			envelope_elapsed = 0
			envelope_stage += 1
			if envelope_stage > 2 {
				break
			}
		}
		env_vol: f32
		envf := f32(envelope_elapsed) / f32(envelope_length[envelope_stage])
		switch envelope_stage {
			case ENV_ATTACK:
				env_vol = envf
			case ENV_SUSTAIN:
				env_vol = 1 + (1 - envf) * 2 * ps.env_punch
			case ENV_DECAY:
				env_vol = 1 - envf
		}

		// Flanger step
		flanger_offset += flanger_offset_slide
		iphase := clamp(abs(int(flanger_offset)), 0, 1023)

		if (flthp_d != 0) {
			flthp = clamp(flthp * flthp_d, 0.00001, 0.1)
		}

		// 8x oversampling
		sample: f32
		for si in 0 ..< pb.oversampling {
			sub_sample: f32
			phase += 1
			if (phase >= iperiod) {
				phase %= iperiod
				if ps.wave_type == .Noise {
					for _, i in noise_buffer {
						noise_buffer[i] = rand.float32_range(-1, 1, &rand_state)
					}
				}
			}

			// Base waveform
			fp := f32(phase) / f32(iperiod)
			switch ps.wave_type {
				case .Square:
					if fp < pb.duty_cycle {
						sub_sample = 0.5
					} else {
						sub_sample = -0.5
					}

				case .Sawtooth:
					if fp < pb.duty_cycle {
						sub_sample = -1 + 2 * fp/pb.duty_cycle
					} else {
						sub_sample = 1 - 2 * (fp - pb.duty_cycle) / (1 - pb.duty_cycle)
					}

				case .Sine:
					sub_sample = math.sin(fp * math.TAU)

				case .Noise:
					sub_sample = noise_buffer[phase * 32 / iperiod]
			}

			// Low-pass filter
			pp := fltp
			fltw = clamp(fltw * fltw_d, 0, 0.1)
			if (ps.filter_on) {
				fltdp += (sub_sample - fltp) * fltw
				fltdp -= fltdp * fltdmp
			} else {
				fltp = sub_sample
				fltdp = 0
			}
			fltp += fltdp

			// High-pass filter
			fltphp += fltp - pp
			fltphp -= fltphp * flthp
			sub_sample = fltphp

			// Flanger
			flanger_buffer[ipp & 1023] = sub_sample
			sub_sample += flanger_buffer[(ipp - iphase + 1024) & 1023]
			ipp = (ipp + 1) & 1023

			// final accumulation and envelope application
			sample += sub_sample * env_vol
		}

		pb.t += 1

		// Accumulate samples appropriately for sample rate
		sample_sum += sample
		num_summed += 1
		if f32(num_summed) >= summands {
			num_summed = 0
			sample = sample_sum / summands
			sample_sum = 0
		} else {
			continue
		}

		sample = sample / f32(pb.oversampling) * ps.sound_vol * linear_gain

		when intrinsics.type_is_integer(T) {
			when intrinsics.type_is_unsigned(T) {
				buffer[num_samples_written] = T(clamp(
					(sample + 1) * f32(max(T) / 2),
					f32(min(T)), f32(max(T)),
				))
			}
			else {
				buffer[num_samples_written] = T(clamp(
					sample * f32(max(T)),
					f32(min(T)), f32(max(T)),
				))
			}
		} else {
			buffer[num_samples_written] = T(sample)
		}
		num_samples_written += 1
	}

	return num_samples_written, .Ok
}


from_bin :: proc(ps: ^Params, data: []u8) -> Error {
	// NOTE: sfxr binary format doesn't actually define its endianness, however it is usually little-endian like x86
	// no major platforms/architectures right now are big-endian, so this is fine 99.9% of the time
	version := mem.reinterpret_copy(i32, raw_data(data))
	i := size_of(i32)
	for field in reflect.struct_fields_zipped(Params) {
		if version_tag, exists := reflect.struct_tag_lookup(field.tag, "v"); exists && i32(strconv.atoi(string(version_tag))) > version {
			continue
		}
		mem.copy(rawptr(uintptr(ps) + field.offset), &data[i], field.type.size)
		i += field.type.size
	}
	return .Ok
}

from_json :: proc(ps: ^Params, data: []u8) -> Error {
	if err := json.unmarshal(data, ps, .JSON5, runtime.nil_allocator()); err != nil {
		return .Invalid_Data
	}
	ps.filter_on = ps.lpf_freq != 1
	return .Ok
}

to_bin :: proc {
	to_bin_buf,
	to_bin_alloc,
}

to_bin_buf :: proc(ps: ^Params, buf: []u8) -> Error {
	if len(buf) < SERIAL_PARAMS_SIZE {
		return .Buffer_Too_Small
	}
	version: i32 = PARAMS_CURRENT_VERSION
	mem.copy(&buf[0], &version, size_of(i32))
	i := size_of(i32)
	for field in reflect.struct_fields_zipped(Params) {
		mem.copy(&buf[i], rawptr(uintptr(ps) + field.offset), field.type.size)
		i += field.type.size
	}
	return .Ok
}

to_bin_alloc :: proc(ps: ^Params, allocator := context.allocator) -> (buf: []u8, err: Error) {
	buf = make([]u8, SERIAL_PARAMS_SIZE)
	defer if err != .Ok {
		delete(buf)
	}
	return buf, to_bin_buf(ps, buf)
}

to_json :: proc(ps: ^Params, allocator := context.allocator) -> ([]u8, Error) {
	data, err := json.marshal(ps, {spec = .JSON, pretty = true}, allocator)
	if err != nil {
		return nil, .Invalid_Data
	}
	return data, .Ok
}
