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
	rand_state: ^rand.Rand = nil,
	allocator := context.allocator,
) -> ([]u8, Error) {
	return generate_pcm(u8, ps, sample_rate, db_gain, rand_state, allocator)
}

generate_pcm :: proc(
	$T: typeid,
	ps: ^Params,
	sample_rate: int = 44100,
	db_gain: f32 = 0,
	rand_state: ^rand.Rand = nil,
	allocator := context.allocator,
) -> (pcm_samples: []T, err: Error) where intrinsics.type_is_numeric(T) {
	// TODO: modify this to allow generating segments of pcm into a fixed buffer
	// so that this can e.g. be used as a custom decoder in miniaudio

	OVERSAMPLING :: 8

	Repeat_Params :: struct {
		elapsed_since_repeat: int,

		period, period_max: f32,
		enable_frequency_cutoff: bool,
		period_mult, period_mult_slide: f32,
		duty_cycle, duty_cycle_slide: f32,
		arpeggio_multiplier: f32,
		arpeggio_time: int,
	}

	init_for_repeat :: proc(rp: ^Repeat_Params, ps: ^Params) {
		rp.elapsed_since_repeat = 0

		rp.period     = 100 / (ps.base_freq  * ps.base_freq  + 0.001)
		rp.period_max = 100 / (ps.freq_limit * ps.freq_limit + 0.001)
		rp.enable_frequency_cutoff = ps.freq_limit > 0
		rp.period_mult    = 1 - math.pow(ps.freq_ramp, 3)  * 0.01
		rp.period_mult_slide = -math.pow(ps.freq_dramp, 3) * 0.000001

		rp.duty_cycle = 0.5 - ps.duty * 0.5
		rp.duty_cycle_slide = -ps.duty_ramp * 0.00005

		if ps.arp_mod >= 0 {
			rp.arpeggio_multiplier = 1 - math.pow(ps.arp_mod, 2) * .9
		}
		else {
			rp.arpeggio_multiplier = 1 + math.pow(ps.arp_mod, 2) * 10
		}
		rp.arpeggio_time = int(math.pow(1 - ps.arp_speed, 2) * 20000 + 32)
		if ps.arp_speed == 1 {
			rp.arpeggio_time = 0
		}
	}

	rp: Repeat_Params
	init_for_repeat(&rp, ps)

	// from SoundEffect.init

	fltw := math.pow(ps.lpf_freq, 3) * 0.1
	fltw_d := 1 + ps.lpf_ramp * 0.0001
	fltdmp := clamp(5 / (1 + math.pow(ps.lpf_resonance, 2) * 20) * (0.01 + fltw), 0, 0.8)
	flthp := math.pow(ps.hpf_freq, 2) * 0.1
	flthp_d := 1 + ps.hpf_ramp * 0.0003

	// Vibrato
	vibrato_speed := math.pow(ps.vib_speed, 2) * 0.01
	vibrato_amplitude := ps.vib_strength * 0.5

	// Envelope
	envelope_length := [3]int {
		int(ps.env_attack  * ps.env_attack  * 100_000),
		int(ps.env_sustain * ps.env_sustain * 100_000),
		int(ps.env_decay   * ps.env_decay   * 100_000),
	}
	envelope_punch := ps.env_punch
	ENV_ATTACK  :: 0
	ENV_SUSTAIN :: 1
	ENV_DECAY   :: 2

	// Flanger
	flanger_offset := math.pow(ps.pha_offset, 2) * 1020
	if ps.pha_offset < 0 { flanger_offset = -flanger_offset }
	flanger_offset_slide := math.pow(ps.pha_ramp, 2) * 1
	if ps.pha_ramp < 0 { flanger_offset_slide = -flanger_offset_slide }

	// Repeat
	repeat_time := int(math.pow(1 - ps.repeat_speed, 2) * 20_000 + 32)
	if ps.repeat_speed == 0 {
		repeat_time = 0
	}

	linear_gain := math.pow(10, db_gain) * (math.exp(ps.sound_vol) - 1)

	// from SoundEffect.getRawBuffer

	fltp: f32 = 0
	fltdp: f32 = 0
	fltphp: f32 = 0

	noise_buffer: [32]f32
	for _, i in noise_buffer {
		noise_buffer[i] = rand.float32_range(-1, 1, rand_state)
	}

	envelope_stage   := 0
	envelope_elapsed := 0

	vibrato_phase: f32 = 0

	phase := 0
	ipp   := 0
	flanger_buffer: [1024]f32

	est_samples := (envelope_length[0] + envelope_length[1] + envelope_length[2])

	buffer, alloc_err := make([dynamic]T, 0, est_samples, allocator)
	if alloc_err != .None {
		return nil, .Allocation_Failure
	}
	defer if err == .Ok {
		runtime.shrink(&buffer, len(buffer))
	} else {
		delete(buffer)
	}

	sample_sum: f32 = 0
	num_summed := 0
	summands := 44100 / f32(sample_rate)

	for t := 0;; t += 1 {
		// Repeats
		if repeat_time != 0 {
			rp.elapsed_since_repeat += 1
			if rp.elapsed_since_repeat >= repeat_time {
				init_for_repeat(&rp, ps)
			}
		}

		// Arpeggio (single)
		if(rp.arpeggio_time != 0 && t >= rp.arpeggio_time) {
			rp.arpeggio_time = 0
			rp.period *= rp.arpeggio_multiplier
		}

		// Frequency slide, and frequency slide slide!
		rp.period_mult += rp.period_mult_slide
		rp.period *= rp.period_mult
		if rp.period > rp.period_max {
			rp.period = rp.period_max
			if rp.enable_frequency_cutoff {
				break
			}
		}

		// Vibrato
		rfperiod := rp.period
		if (vibrato_amplitude > 0) {
			vibrato_phase += vibrato_speed
			rfperiod = rp.period * (1 + math.sin(vibrato_phase) * vibrato_amplitude)
		}
		iperiod := max(int(rfperiod), OVERSAMPLING)

		// Square wave duty cycle
		rp.duty_cycle = clamp(rp.duty_cycle + rp.duty_cycle_slide, 0, 0.5)

		// Volume envelope
		envelope_elapsed += 1
		if envelope_elapsed > envelope_length[envelope_stage] {
			envelope_elapsed = 0
			envelope_stage += 1
			if envelope_stage > 2 { break }
		}
		env_vol: f32
		envf := f32(envelope_elapsed) / f32(envelope_length[envelope_stage])
		switch envelope_stage {
			case ENV_ATTACK:
				env_vol = envf
			case ENV_SUSTAIN:
				env_vol = 1 + (1 - envf) * 2 * envelope_punch
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
		for si in 0 ..< OVERSAMPLING {
			sub_sample: f32
			phase += 1
			if (phase >= iperiod) {
				phase %= iperiod
				if ps.wave_type == .Noise {
					for _, i in noise_buffer {
						noise_buffer[i] = rand.float32_range(-1, 1, rand_state)
					}
				}
			}

			// Base waveform
			fp := f32(phase) / f32(iperiod)
			switch ps.wave_type {
				case .Square:
					if fp < rp.duty_cycle {
						sub_sample = 0.5
					} else {
						sub_sample = -0.5
					}

				case .Sawtooth:
					if fp < rp.duty_cycle {
						sub_sample = -1 + 2 * fp/rp.duty_cycle
					} else {
						sub_sample = 1 - 2 * (fp - rp.duty_cycle) / (1 - rp.duty_cycle)
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

		sample = sample / OVERSAMPLING * ps.sound_vol * linear_gain

		when intrinsics.type_is_integer(T) {
			when intrinsics.type_is_unsigned(T) {
				append(&buffer, T(clamp(
					(sample + 1) * f32(max(T) / 2),
					f32(min(T)), f32(max(T)),
				)))
			}
			else {
				append(&buffer, T(clamp(
					sample * f32(max(T)),
					f32(min(T)), f32(max(T)),
				)))
			}
		} else {
			append(&buffer, T(sample))
		}
	}

	return buffer[:], .Ok
}


from_bin :: proc(ps: ^Params, data: []u8) -> Error {
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
	return .Not_Implemented
}
to_bin_alloc :: proc(ps: ^Params, allocator := context.allocator) -> ([]u8, Error) { return nil, .Not_Implemented }
to_json :: proc(ps: ^Params, allocator := context.allocator) -> ([]u8, Error) { return nil, .Not_Implemented }
