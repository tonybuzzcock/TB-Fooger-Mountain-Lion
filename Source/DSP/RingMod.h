// RingMod.h
// Moog moogerfooger MF-102 Ring Modulator (drawing 11-3302, Nov 2002),
// modelled from the schematic. +-9 V for the op-amps, +-5 V for the
// LM13600 OTAs and the transistor arrays.
//
//   AUDIO IN -> 10n film (1M to ground) -> 10K / 470p -> TL072 U1A,
//      non-inverting: DRIVE (P1 50K) over 1K5 + 22u bipolar: x1 .. x34
//      above 5 Hz                                              = node D
//   D -> 220n -> 33K / 680 -> the wet OTAs U4A (-) and U4B (+): a four-
//      quadrant multiplier. Their bias currents come from the MPQ3906 pair
//      U11A/U11B, whose bases see the carrier (x2 in U10A, then 10K / 1K,
//      10n across the bases), so the current steers between the two OTAs.
//      Wet current out = -I_wet * tanh(carrier / 2Vt) * tanh(audio / 2Vt).
//   D -> 68K / 680 -> the dry OTA U5A (+).
//   OTA outputs joined into 2K4 || 1n -> TL072 U1B follower -> 330 -> OUT.
//
//   MIX: the MPQ3906 pair U11C/U11D (470 R in each emitter, 10K tail from
//      +5) splits the current between the dry OTA and the multiplier. P5
//      (50K lin, -5..+5) -> 68K / 6K8 drives U11C's base; U11D's base sits
//      at 0 V with the effect in, and is pulled to 1.6 V (4K7 / 1K from the
//      4049, 22u: an 18 ms fade) to bypass, which sends everything to the
//      dry OTA.
//   Carrier gate: LM339 peak follower on node D (680 R into 100u, 4K7
//      discharge), into the 2N3906 pair Q2/Q3 (22K tail): with no input,
//      Q2 turns on Q4 (2N3904, 2K2 emitter), which sinks the multiplier's
//      tail current so the carrier can't bleed through. The same follower
//      lights the LEVEL LED (green from 0.1 V, red from 1.06 V, green out
//      above 2.02 V).
//   Carrier VCO: LM13600 integrator (4n7 film, + 220n film in LO) and
//      Schmitt trigger: a triangle, rounded into a sine by the multiplier's
//      own transistor pair. Exponential converter U12C/U12D: FREQUENCY
//      (P4 50K lin) through 130K into 1K8, LFO through U5B into the same
//      1K8.
//   LFO: LM13600 triangle / square (100n film), RATE (P3 50K lin) through
//      its own exponential converter U12A/U12B. TRI/SQUARE switch -> 330K /
//      18K -> OTA U5B (rounds the triangle), whose bias is the AMOUNT pot
//      (P2 50K lin) through 470K into Q5 (4M7 to -5 sets a starting
//      threshold). The LFO LED (red half only, "NC" green) follows the
//      triangle through U8D.
//
// Modelled as a circuit: the drive stage and its rails, the coupling
// networks, the OTAs' tanh transfer, the MIX and carrier current steering
// (Newton on the degenerated pair), the gate and the peak follower.
// Modelled behaviourally (estimates in RingMod.cpp): the VCO and LFO
// frequencies (from the panel's scales), the triangle swings, the LFO's
// depth into the exponential converter.
//
// Volts in, volts out (1.0 = 1 V). Runs at 4x with Oversampler4x.
// Plain C++98, no allocation after construction.

#ifndef TBFOOGER_RINGMOD_H
#define TBFOOGER_RINGMOD_H

#include "Filters.h"
#include "Oversampler4x.h"

namespace tbfooger
{

class RingMod
{
public:
    RingMod();

    void prepare (double sampleRate);
    void reset();

    // Front panel (0..1 pot rotation), in the panel's order
    void setAmount (double v);          // LFO AMOUNT, 50K lin
    void setLfoSine (bool sine);        // LFO switch: square / sine (triangle)
    void setRate (double v);            // LFO RATE, 50K lin, 0.1 .. 25 Hz
    void setDrive (double v);           // DRIVE, 50K (audio taper assumed)
    void setMix (double v);             // MIX, 50K lin
    void setRangeHi (bool hi);          // LO / HI switch
    void setFrequency (double v);       // FREQUENCY, 50K lin
    void setEffectOn (bool on);         // footswitch
    // Plugin only
    void setInputGainDb (double dB);
    void setOutputGainDb (double dB);

    // Mono in, mono out
    void process (const float* in, float* out, int numSamples);

    static int latencySamples() { return Oversampler4x::latencySamples(); }

    // Introspection for the panel, the wrapper and the tests
    static double lfoHz (double ratePot);
    static double carrierHz (double freqPot, bool hi);
    static double driveGain (double drivePot);           // U1A gain above 5 Hz
    static double wetFraction (double mixPot, bool effectOn);   // share of the MIX current to the multiplier
    static double lfoDepthOctaves (double amountPot);    // peak swing of the carrier, octaves
    double envelopeVolts() const { return env; }         // the peak follower (LEVEL LED)
    double lfoLedLevel() const;                          // 0..1 brightness of the LFO LED
    double currentCarrierHz() const { return lastCarrierHz; }
    double gateOpen() const { return lastGate; }         // 0..1: multiplier current let through

    // LEVEL LED thresholds (the LM339 ladder: 220, 2K2, 2K2, 6K8 from +5)
    static double levelGreenOn()  { return 5.0 * 220.0 / 11420.0; }
    static double levelRedOn()    { return 5.0 * 2420.0 / 11420.0; }
    static double levelGreenOff() { return 5.0 * 4620.0 / 11420.0; }

private:
    double tickOs (double x);
    void   updateSmoothed();
    void   updateDriveNet();

    double fsBase, fsOs;
    Oversampler4x up, down;

    // Targets and smoothed values
    double amtT, rateT, driveT, mixT, freqT, inT, outT;
    double amt, rate, drive, mix, freq, inG, outG;
    double sineT, sine, rangeT;
    bool   effectOn, hiRange;
    double smKnob;

    // Audio path
    FirstOrder inHp, inLp;      // 10n into 1M; 10K / 470p
    FirstOrder driveNet;        // U1A gain network
    double     driveSet;
    FirstOrder wetHp;           // 220n into 33K + 680
    FirstOrder outLp;           // 2K4 || 1n
    FirstOrder carLp;           // 10n across the carrier pair's bases

    // Peak follower, gate, MIX pair state
    double env;
    double bypassV;             // U11D base (18 ms fade)
    double bypassCoef;
    double mixU;                // Newton state (logit of the wet share)

    // Oscillators
    double carPhase;            // 0..1
    double lfoPhase;            // 0..1
    double lfoTri;              // -1..1 raw triangle / square (as switched)
    double lfoRaw;              // the triangle, for the LED

    double lastCarrierHz, lastGate;
    int    ctrlCount;

    // Slow-moving values, refreshed every 16 oversampled ticks or on change
    double baseCarHz, depthOct, lfoInc, lfoNorm;
    double mixVc, mixVd, mixTail, mixWet;
};

} // namespace tbfooger

#endif
