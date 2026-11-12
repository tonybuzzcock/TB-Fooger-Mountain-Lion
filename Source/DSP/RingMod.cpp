// RingMod.cpp
// See RingMod.h for the circuit. Component values are from the drawing;
// the named constants marked ESTIMATE are not fixed by it.

#include "RingMod.h"

#include <cmath>
#include <cstring>

namespace tbfooger
{

namespace
{
    const double kVt = 0.02585;                 // thermal voltage at 27 C

    // Drive stage, TL072 on +-9 V
    const double kR1 = 10.0e3, kC1 = 10.0e-9, kR2 = 1.0e6, kC2 = 470.0e-12;
    const double kR3 = 1.5e3, kC18 = 22.0e-6;
    const double kP1 = 50.0e3;
    const double kOpSwing = 7.6;                // ESTIMATE: TL072 output swing on +-9 V

    // OTA input dividers
    const double kR16 = 33.0e3, kR12 = 68.0e3, kRn3 = 680.0, kC7 = 220.0e-9;
    const double kWetDiv = kRn3 / (kR16 + kRn3);
    const double kDryDiv = kRn3 / (kR12 + kRn3);

    // Output node
    const double kR22 = 2.4e3, kC16 = 1.0e-9;

    // MIX pair: 10K tail from +5, 470 R per emitter
    const double kMixTailR = 10.0e3, kMixDegen = 470.0, kVbe = 0.65;
    // MIX pot -5..+5 -> 68K -> 6K8 to ground
    const double kR39 = 68.0e3, kR38 = 6.8e3, kP5 = 50.0e3;
    // Bypass: 4049 (9 V) -> 4K7 / 1K, 22u
    const double kR33 = 4.7e3, kR34 = 1.0e3, kC8 = 22.0e-6, kLogicHigh = 9.0;

    // Carrier: U10A x2, 10K into 1K between the bases, 10n across.
    // ESTIMATE: the VCO triangle's swing, chosen so the pair rounds it into
    // a sine (peak at 1.3 x 2Vt across the bases, about 2 % THD).
    const double kCarrierPeakV = 1.3 * 2.0 * kVt;
    const double kCarrierLpHz = 1.0 / (2.0 * 3.14159265358979 * (1.0e3 * 10.0e3 / 11.0e3) * 10.0e-9);

    // Peak follower: 680 R into 100u, 4K7 discharge
    const double kR15 = 680.0, kR7 = 4.7e3, kC4 = 100.0e-6;
    // Gate: Q2/Q3 22K tail from +5, Q4 22K base / 2K2 emitter to -5
    const double kR19 = 22.0e3, kR18 = 22.0e3, kR13 = 2.2e3;

    // Frequencies (ESTIMATE: from the panel's scales; both are evenly
    // spaced octaves, so the pots are linear into exponential converters)
    const double kCarHiMin = 31.25;     // HI: 30 .. 4K over 7 octaves
    const double kCarOctaves = 7.0;
    const double kLoRatio = 50.0;       // LO: 0.6 .. 80 (220n + 4n7 against 4n7)
    const double kLfoMin = 0.1;         // RATE: 0.1 .. 25 over 8 octaves
    const double kLfoOctaves = 8.0;

    // LFO: triangle and square swing (ESTIMATE: the square's OTA current,
    // 9.2 V / 47K, into 6K2), then 330K / 18K into U5B
    const double kLfoSwing = 1.16;
    const double kLfoDiv = 18.0e3 / (330.0e3 + 18.0e3);
    // AMOUNT: P2 (50K lin, 3K3 to ground, top at +5) -> 470K into Q5's
    // emitter, 4M7 to -5 against it (a starting threshold).
    // ESTIMATE: the carrier's peak swing at AMOUNT 10, in octaves.
    const double kLfoDepthMaxOct = 1.0;

    inline double clampd (double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }

    inline double softClip (double v, double limit)
    {
        // Rounded rail: linear to about 80 % of the swing
        const double x = v / limit;
        const double ax = std::fabs (x);
        if (ax < 0.8) return v;
        const double over = (ax - 0.8) / 0.2;
        const double y = 0.8 + 0.2 * std::tanh (over);
        return (x < 0.0 ? -y : y) * limit;
    }

    inline double audioTaper (double x)
    {
        // 10 % at mid rotation
        const double k = 4.394449154672439;     // 2 ln 9
        return (std::exp (k * x) - 1.0) / (std::exp (k) - 1.0);
    }

    // MIX pot wiper into 68K / 6K8: U11C's base
    double mixBaseVolts (double x)
    {
        x = clampd (x, 0.0, 1.0);
        const double vw = -5.0 + 10.0 * x;
        const double rw = kP5 * x * (1.0 - x);
        return vw * kR38 / (kR38 + kR39 + rw);
    }

    // Share of the MIX pair's current through U11D (to the multiplier), for
    // U11C's base at vc and U11D's at vd. Newton in the logit of the share,
    // from the guess u (updated).
    double solveMixPair (double vc, double vd, double& u)
    {
        const double vLow = vc < vd ? vc : vd;
        double tail = (5.0 - kVbe - vLow) / (kMixTailR + 0.5 * kMixDegen);
        if (tail < 1.0e-6) tail = 1.0e-6;
        const double target = vc - vd;      // PNP: the lower base takes more
        for (int it = 0; it < 6; ++it)
        {
            const double f = 1.0 / (1.0 + std::exp (-u));
            const double g = kVt * u + kMixDegen * tail * (2.0 * f - 1.0) - target;
            const double dg = kVt + 2.0 * kMixDegen * tail * f * (1.0 - f);
            double step = g / dg;
            step = clampd (step, -4.0, 4.0);
            u -= step;
            if (std::fabs (step) < 1.0e-7) break;
        }
        u = clampd (u, -60.0, 60.0);
        return 1.0 / (1.0 + std::exp (-u));
    }

    double mixTailAmps (double vc, double vd)
    {
        const double vLow = vc < vd ? vc : vd;
        const double t = (5.0 - kVbe - vLow) / (kMixTailR + 0.5 * kMixDegen);
        return t > 0.0 ? t : 0.0;
    }

    // Current Q4 sinks from the multiplier's tail for a follower voltage
    double gateStealAmps (double envV)
    {
        const double tail = (5.0 - kVbe) / kR19;
        const double ic2 = tail / (1.0 + std::exp (envV / kVt));
        const double vbe = ic2 * kR18;                  // Q4's base above -5 V
        // Soft turn-on of Q4 around 0.62 V
        const double x = (vbe - 0.62) / 0.03;
        const double sp = x > 30.0 ? x : std::log (1.0 + std::exp (x));
        return 0.03 * sp / kR13;
    }
}

//==============================================================================
double RingMod::lfoHz (double ratePot)
{
    return kLfoMin * std::pow (2.0, kLfoOctaves * clampd (ratePot, 0.0, 1.0));
}

double RingMod::carrierHz (double freqPot, bool hi)
{
    const double f = kCarHiMin * std::pow (2.0, kCarOctaves * clampd (freqPot, 0.0, 1.0));
    return hi ? f : f / kLoRatio;
}

double RingMod::driveGain (double drivePot)
{
    return 1.0 + kP1 * audioTaper (clampd (drivePot, 0.0, 1.0)) / kR3;
}

double RingMod::wetFraction (double mixPot, bool on)
{
    double u = 0.0;
    const double vd = on ? 0.0 : kLogicHigh * kR34 / (kR33 + kR34);
    return solveMixPair (mixBaseVolts (mixPot), vd, u);
}

double RingMod::lfoDepthOctaves (double amountPot)
{
    // Q5's emitter current: wiper through 470K against 4M7 to -5
    const double x = clampd (amountPot, 0.0, 1.0);
    const double vw = 5.0 * (3.3e3 + 50.0e3 * x) / (50.0e3 + 3.3e3);
    const double i = (vw - kVbe) / 470.0e3 - (kVbe + 5.0) / 4.7e6;
    const double iMax = (5.0 - kVbe) / 470.0e3 - (kVbe + 5.0) / 4.7e6;
    if (i <= 0.0) return 0.0;
    return kLfoDepthMaxOct * i / iMax;
}

double RingMod::lfoLedLevel() const
{
    // U8D: -triangle + 3.33 V, red LED through 330 R from about 1.8 V
    const double v = 3.333 - kLfoSwing * lfoRaw - 1.8;
    return clampd (v / (3.333 + kLfoSwing - 1.8), 0.0, 1.0);
}

//==============================================================================
RingMod::RingMod()
    : fsBase (44100.0), fsOs (176400.0),
      amtT (0.0), rateT (0.5), driveT (0.5), mixT (1.0), freqT (0.5), inT (1.0), outT (1.0),
      amt (0.0), rate (0.5), drive (0.5), mix (1.0), freq (0.5), inG (1.0), outG (1.0),
      sineT (1.0), sine (1.0), rangeT (1.0), effectOn (true), hiRange (true),
      smKnob (0.0), driveSet (-1.0),
      env (0.0), bypassV (0.0), bypassCoef (0.0), mixU (0.0),
      carPhase (0.0), lfoPhase (0.0), lfoTri (0.0), lfoRaw (0.0),
      lastCarrierHz (0.0), lastGate (0.0), ctrlCount (0),
      baseCarHz (350.0), depthOct (0.0), lfoInc (0.0), lfoNorm (1.0),
      mixVc (1.0e9), mixVd (1.0e9), mixTail (0.0), mixWet (0.0)
{
    prepare (44100.0);
}

void RingMod::prepare (double sampleRate)
{
    fsBase = sampleRate > 1000.0 ? sampleRate : 44100.0;
    fsOs = fsBase * Oversampler4x::kFactor;
    smKnob = 1.0 - std::exp (-1.0 / (0.015 * fsOs));
    bypassCoef = 1.0 - std::exp (-1.0 / ((kR33 * kR34 / (kR33 + kR34)) * kC8 * fsOs));

    const double lim = 0.45 * fsOs;
    inHp.highpass (1.0 / (2.0 * kPi * (kR1 + kR2) * kC1), fsOs);
    inLp.lowpass (clampd (1.0 / (2.0 * kPi * kR1 * kC2), 1.0, lim), fsOs);
    wetHp.highpass (1.0 / (2.0 * kPi * (kR16 + kRn3) * kC7), fsOs);
    outLp.lowpass (clampd (1.0 / (2.0 * kPi * kR22 * kC16), 1.0, lim), fsOs);
    carLp.lowpass (clampd (kCarrierLpHz, 1.0, lim), fsOs);
    driveSet = -1.0;
    reset();
}

void RingMod::reset()
{
    up.reset();
    down.reset();
    inHp.reset(); inLp.reset(); driveNet.reset(); wetHp.reset(); outLp.reset(); carLp.reset();
    amt = amtT; rate = rateT; drive = driveT; mix = mixT; freq = freqT; inG = inT; outG = outT;
    sine = sineT;
    hiRange = rangeT >= 0.5;
    env = 0.0;
    bypassV = effectOn ? 0.0 : kLogicHigh * kR34 / (kR33 + kR34);
    mixU = 0.0;
    solveMixPair (mixBaseVolts (mix), bypassV, mixU);
    carPhase = 0.0;
    lfoPhase = 0.25;            // start at the triangle's middle, rising
    lfoTri = lfoRaw = 0.0;
    lastCarrierHz = carrierHz (freq, hiRange);
    lastGate = 0.0;
    ctrlCount = 0;
    driveSet = -1.0;
    mixVc = mixVd = 1.0e9;      // force a solve
    lfoNorm = 1.0 / std::tanh (kLfoSwing * kLfoDiv / (2.0 * kVt));
    updateDriveNet();
}

void RingMod::setAmount (double v)      { amtT = clampd (v, 0.0, 1.0); }
void RingMod::setLfoSine (bool s)       { sineT = s ? 1.0 : 0.0; }
void RingMod::setRate (double v)        { rateT = clampd (v, 0.0, 1.0); }
void RingMod::setDrive (double v)       { driveT = clampd (v, 0.0, 1.0); }
void RingMod::setMix (double v)         { mixT = clampd (v, 0.0, 1.0); }
void RingMod::setRangeHi (bool hi)      { rangeT = hi ? 1.0 : 0.0; }
void RingMod::setFrequency (double v)   { freqT = clampd (v, 0.0, 1.0); }
void RingMod::setEffectOn (bool on)     { effectOn = on; }
void RingMod::setInputGainDb (double dB)  { inT = std::pow (10.0, clampd (dB, -48.0, 48.0) / 20.0); }
void RingMod::setOutputGainDb (double dB) { outT = std::pow (10.0, clampd (dB, -48.0, 48.0) / 20.0); }

void RingMod::updateDriveNet()
{
    if (std::fabs (drive - driveSet) < 1.0e-6) return;
    driveSet = drive;
    // (1 + s (Rp + R3) C18) / (1 + s R3 C18)
    const double rp = kP1 * audioTaper (drive);
    driveNet.setAnalog ((rp + kR3) * kC18, 1.0, kR3 * kC18, 1.0, fsOs);
}

void RingMod::updateSmoothed()
{
    amt   += smKnob * (amtT - amt);
    rate  += smKnob * (rateT - rate);
    drive += smKnob * (driveT - drive);
    mix   += smKnob * (mixT - mix);
    freq  += smKnob * (freqT - freq);
    inG   += smKnob * (inT - inG);
    outG  += smKnob * (outT - outG);
    sine  += smKnob * (sineT - sine);
    hiRange = rangeT >= 0.5;
}

double RingMod::tickOs (double x)
{
    updateSmoothed();
    if ((ctrlCount++ & 15) == 0)
    {
        updateDriveNet();
        baseCarHz = carrierHz (freq, hiRange);
        depthOct = lfoDepthOctaves (amt);
        lfoInc = lfoHz (rate) / fsOs;
    }

    // Input network and the drive stage
    double v = inLp.tick (inHp.tick (x));
    const double d = softClip (driveNet.tick (v), kOpSwing);

    // Peak follower: 680 R charging 100u while the input is above it
    {
        const double dt = 1.0 / fsOs;
        double dv = -env / (kR7 * kC4);
        if (d > env) dv += (d - env) / (kR15 * kC4);
        env += dv * dt;
        if (env < 0.0) env = 0.0;
    }

    // LFO: triangle and square, rounded by U5B's tanh
    lfoPhase += lfoInc;
    if (lfoPhase >= 1.0) lfoPhase -= 1.0;
    const double tri = lfoPhase < 0.5 ? 4.0 * lfoPhase - 1.0 : 3.0 - 4.0 * lfoPhase;
    const double sq = lfoPhase < 0.5 ? 1.0 : -1.0;
    lfoRaw = tri;
    lfoTri = sine * tri + (1.0 - sine) * sq;    // the switch, softened for a click-free change
    const double argL = kLfoSwing * lfoTri * kLfoDiv / (2.0 * kVt);
    const double lfoShaped = std::tanh (argL) * lfoNorm;

    // Carrier VCO
    double cHz = depthOct > 0.0 ? baseCarHz * std::exp (0.6931471805599453 * depthOct * lfoShaped) : baseCarHz;
    cHz = clampd (cHz, 0.01, 0.4 * fsOs);
    lastCarrierHz = cHz;
    carPhase += cHz / fsOs;
    if (carPhase >= 1.0) carPhase -= std::floor (carPhase);
    const double ctri = carPhase < 0.5 ? 4.0 * carPhase - 1.0 : 3.0 - 4.0 * carPhase;
    const double vc = carLp.tick (kCarrierPeakV * ctri);
    const double steer = std::tanh (vc / (2.0 * kVt));

    // MIX pair and bypass fade
    const double vdTarget = effectOn ? 0.0 : kLogicHigh * kR34 / (kR33 + kR34);
    bypassV += bypassCoef * (vdTarget - bypassV);
    if (std::fabs (vdTarget - bypassV) < 1.0e-9) bypassV = vdTarget;
    const double vcMix = mixBaseVolts (mix);
    if (std::fabs (vcMix - mixVc) > 1.0e-9 || bypassV != mixVd)
    {
        mixVc = vcMix; mixVd = bypassV;
        mixTail = mixTailAmps (mixVc, mixVd);
        mixWet = solveMixPair (mixVc, mixVd, mixU);
    }
    const double tail = mixTail;
    const double wetShare = mixWet;
    const double iDry = tail * (1.0 - wetShare);
    double iWet = tail * wetShare - gateStealAmps (env);
    if (iWet < 0.0) iWet = 0.0;
    lastGate = tail * wetShare > 1.0e-9 ? iWet / (tail * wetShare) : 0.0;

    // OTAs into the 2K4 node
    const double aWet = wetHp.tick (d) * kWetDiv;
    const double aDry = d * kDryDiv;
    const double iOut = -iWet * steer * std::tanh (aWet / (2.0 * kVt))
                        + iDry * std::tanh (aDry / (2.0 * kVt));
    return outLp.tick (iOut * kR22);
}

void RingMod::process (const float* in, float* out, int numSamples)
{
    double os[Oversampler4x::kFactor];
    for (int n = 0; n < numSamples; ++n)
    {
        const double x = (double) in[n];
        up.upsample (x * inG, os);
        for (int k = 0; k < Oversampler4x::kFactor; ++k)
            os[k] = tickOs (os[k]);
        double y = down.downsample (os) * outG;
        if (! (y == y)) y = 0.0;
        out[n] = (float) y;
    }
}

} // namespace tbfooger
