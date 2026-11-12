# TB Fooger Ring Mod (Mountain Lion VST)

A model of the **Moog moogerfooger MF-102 Ring Modulator**, built from its schematic
(`Docs/MF-102_Ring_Modulator_schematic.pdf`, drawing 11-3302) and a photo of the user's unit,
as a **VST 2.4, 64-bit Intel plugin for Mac OS X 10.8.5** (Pro Tools 11 through Blue Cat PatchWork).
Non-commercial, for personal use.

The modern Mac version (CLAP / VST3 / AU) will live in `TB-Fooger-2026-MAC`.

## Controls

Front panel, as on the unit:

| Section | Control | Range |
|---|---|---|
| LFO | AMOUNT | 0-10 (no LFO below about 2: Q5's threshold) |
| LFO | Square / sine switch | the sine is the triangle rounded by the OTA, as on the unit |
| LFO | RATE | 0.1-25 Hz, octave marks |
| | DRIVE | input gain x1 to x34 (U1A, 1 + 50K / 1K5) |
| MODULATOR | MIX | dry to ring modulator, half and half at 5 |
| MODULATOR | LO / HI | carrier range |
| MODULATOR | FREQUENCY | HI 30 Hz-4 kHz, LO 0.6-80 Hz, octave marks |
| | Footswitch | effect / bypass |

LEDs: **LEVEL** (green from 0.1 V at the drive stage's output, red from 1.06 V, green out above 2.02 V),
**LFO** (red, following the LFO), **BYPASS** (red with the effect in, green bypassed).

Plugin strip: Input (+-12 dB), Output (+-24 dB), 8 presets, readout.

No expression or CV inputs (not wanted).

## How it's modelled

- **Drive stage**: 10n / 1M input coupling, 10K / 470p, TL072 non-inverting gain over 1K5 + 22u, soft
  rails at about +-7.6 V.
- **Multiplier**: the wet OTAs (LM13600 U4A/U4B) get the audio through 220n and 33K / 680; their bias
  currents are steered by the carrier across the MPQ3906 pair (U11A/B), which also rounds the triangle
  carrier into a sine. Wet current = -I_wet x tanh(carrier / 2Vt) x tanh(audio / 2Vt). The dry OTA (U5A)
  takes the audio through 68K / 680. Outputs join into 2K4 || 1n.
- **MIX** is the degenerated pair U11C/U11D (470 R per emitter, 10K tail), solved by Newton. The
  footswitch pulls U11D's base to 1.6 V through 4K7 / 1K and 22u, an 18 ms fade that sends all the current
  to the dry OTA. So, as on the unit, **bypass goes through DRIVE and the dry OTA**: it isn't a hard-wire
  bypass, and its level follows DRIVE.
- **Carrier gate**: the LM339 peak follower (680 R into 100u, 4K7 discharge) drives Q2/Q3/Q4, which takes
  the multiplier's current away when nothing is playing, so the carrier doesn't bleed through. The same
  follower lights LEVEL.
- 4x oversampling, plain C++98, no allocation while processing.

### Estimates (not fixed by the drawing)

All in `Source/DSP/RingMod.cpp` as named constants:

- Carrier and LFO frequency ranges: taken from the panel scales (evenly spaced octaves, so linear pots into
  exponential converters). HI 31.25-4000 Hz, LO /50, RATE 0.1-25.6 Hz.
- `kLfoDepthMaxOct` = 1.0: carrier swing of +-1 octave at AMOUNT 10. **Tune this against your unit.**
- `kCarrierPeakV`: the carrier triangle's swing across the steering pair (1.3 x 2Vt, a clean sine).
- `kLfoSwing` = 1.16 V: the LFO's triangle / square swing.
- `kOpSwing` = 7.6 V: TL072 output swing on +-9 V.
- DRIVE pot taper: audio (10 % at mid) assumed.
- The trimmers (CARRIER NULL, PROG NULL) are taken as perfectly set.

## Build

GitHub Actions builds the bundle on an Intel macOS runner with `-mmacosx-version-min=10.8.5`, checks
that the binary declares 10.8.5 and links only libraries that 10.8.5 has, loads it in a test host, drives
the panel offscreen and publishes screenshots to the `gui-preview` branch.

Local tests (Linux or Mac): `make -C Tests run vst-run`, sanitizers: `make -C Tests asan`.

## Install

Actions -> latest run -> Artifacts -> `TB-Fooger-mountain-lion-vst`; unzip (twice), copy
`TB Fooger Ring Mod.vst` to `/Library/Audio/Plug-Ins/VST/`, rescan in PatchWork.
