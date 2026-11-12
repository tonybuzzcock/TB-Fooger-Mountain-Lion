// Params.h
// Parameter table shared by the VST wrapper, the editor and the preset store.
//
// Front-panel controls first, in the MF-102's order (the LFO section top to
// bottom, DRIVE, the MODULATOR section top to bottom, the footswitch), then
// the plugin-only controls in the editor's bottom strip.

#ifndef TBFOOGER_PARAMS_H
#define TBFOOGER_PARAMS_H

namespace tbfooger
{

enum Param
{
    // Front panel
    kAmount = 0, kLfoWave, kRate, kDrive, kMix, kRange, kFreq, kEffect,
    // Plugin only (bottom strip of the editor)
    kInput, kOutput,
    kNumParams
};

enum Kind { kKnob, kRateHz, kFreqHz, kWave, kRangeSw, kSwitch, kDb12, kDb24 };

const char* const kParamNames[kNumParams] = {
    "Amount", "LFO Wave", "Rate", "Drive", "Mix", "Range", "Freq", "Effect",
    "Input", "Output"
};

const int kParamKind[kNumParams] = {
    kKnob, kWave, kRateHz, kKnob, kKnob, kRangeSw, kFreqHz, kSwitch,
    kDb12, kDb24
};

const float kDefaults[kNumParams] = {
    0.0f,       // AMOUNT 0: no LFO
    1.0f,       // sine
    0.5f,       // RATE 1.6 Hz
    0.5f,       // DRIVE at noon
    1.0f,       // MIX 10: all ring modulator
    1.0f,       // HI
    0.5f,       // FREQUENCY at noon (350 Hz on HI)
    1.0f,       // effect in
    0.5f, 0.5f
};

const double kInputRangeDb  = 12.0;
const double kOutputRangeDb = 24.0;

inline bool isOn (float v) { return v >= 0.5f; }

} // namespace tbfooger

#endif
