// ringmod_test.cpp
// Offline checks for the TB Fooger Ring Mod DSP. Builds on Linux or macOS:
//   make -C Tests run      (writes demo WAVs to Tests/renders)
//
// 1. Drive stage: gain range, the LEVEL LED's thresholds, rails
// 2. Ring modulation: sidebands, input and carrier suppression, the
//    carrier's frequency on both ranges, LO as tremolo
// 3. MIX crossfade, bypass through the dry OTA (no carrier, no click)
// 4. LFO: rate, AMOUNT depth and threshold, square vs sine, the LED
// 5. Carrier gate: shut in silence, open while playing
// 6. Stability sweep: knob corners x 10 mV-4 V x 41 Hz-15 kHz, plus noise
// 7. Automation of every control while playing; CPU; demo renders

#include "../Source/DSP/RingMod.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <ctime>
#include <string>
#include <vector>

using namespace tbfooger;

static const double kPiT = 3.14159265358979323846;
static const int kSr = 44100;
static int failures = 0;

static void check (bool ok, const char* what)
{
    std::printf ("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (! ok) ++failures;
}

static bool allFinite (const std::vector<float>& x, double limit)
{
    for (size_t i = 0; i < x.size(); ++i)
        if (! (x[i] == x[i]) || std::fabs (x[i]) > limit) return false;
    return true;
}

static double rmsRange (const std::vector<float>& x, size_t from, size_t to)
{
    double s = 0.0;
    if (to > x.size()) to = x.size();
    for (size_t i = from; i < to; ++i) s += (double) x[i] * x[i];
    return to > from ? std::sqrt (s / (double) (to - from)) : 0.0;
}

static double peakRange (const std::vector<float>& x, size_t from, size_t to)
{
    double p = 0.0;
    if (to > x.size()) to = x.size();
    for (size_t i = from; i < to; ++i) p = std::max (p, (double) std::fabs (x[i]));
    return p;
}

static std::vector<float> sine (double f, double amp, double sec)
{
    std::vector<float> v ((size_t) (sec * kSr));
    for (size_t i = 0; i < v.size(); ++i) v[i] = (float) (amp * std::sin (2.0 * kPiT * f * i / kSr));
    return v;
}

static std::vector<float> run (RingMod& a, const std::vector<float>& in)
{
    std::vector<float> out (in.size());
    for (size_t pos = 0; pos < in.size(); pos += 256)
    {
        const int n = (int) std::min ((size_t) 256, in.size() - pos);
        a.process (&in[pos], &out[pos], n);
    }
    return out;
}

static void defaults (RingMod& a)
{
    a.setAmount (0.0); a.setLfoSine (true); a.setRate (0.5); a.setDrive (0.5); a.setMix (1.0);
    a.setRangeHi (true); a.setFrequency (0.5); a.setEffectOn (true);
    a.setInputGainDb (0.0); a.setOutputGainDb (0.0);
}

// FREQUENCY pot position for a carrier frequency
static double potFor (double hz, bool hi)
{
    const double base = hi ? 31.25 : 0.625;
    return std::log (hz / base) / std::log (2.0) / 7.0;
}

// Amplitude of the component at f (Goertzel over a whole number of cycles)
static double level (const std::vector<float>& x, size_t from, size_t to, double f)
{
    double sr = 0.0, si = 0.0;
    if (to > x.size()) to = x.size();
    for (size_t i = from; i < to; ++i)
    {
        const double w = 2.0 * kPiT * f * i / kSr;
        sr += x[i] * std::cos (w); si += x[i] * std::sin (w);
    }
    const double n = (double) (to - from);
    return 2.0 * std::sqrt (sr * sr + si * si) / n;
}

static double db (double a, double b) { return 20.0 * std::log10 ((a + 1e-15) / (b + 1e-15)); }

static void writeWav (const std::string& path, const std::vector<float>& x, int sr)
{
    FILE* f = std::fopen (path.c_str(), "wb");
    if (! f) return;
    const unsigned dataBytes = (unsigned) x.size() * 2, riff = 36 + dataBytes;
    const unsigned short fmt = 1, ch = 1, bits = 16, align = 2;
    const unsigned rate = (unsigned) sr, bps = rate * 2, fmtLen = 16;
    std::fwrite ("RIFF", 1, 4, f); std::fwrite (&riff, 4, 1, f); std::fwrite ("WAVEfmt ", 1, 8, f);
    std::fwrite (&fmtLen, 4, 1, f); std::fwrite (&fmt, 2, 1, f); std::fwrite (&ch, 2, 1, f);
    std::fwrite (&rate, 4, 1, f); std::fwrite (&bps, 4, 1, f); std::fwrite (&align, 2, 1, f);
    std::fwrite (&bits, 2, 1, f); std::fwrite ("data", 1, 4, f); std::fwrite (&dataBytes, 4, 1, f);
    for (size_t i = 0; i < x.size(); ++i)
    {
        double v = x[i] * 0.9;
        v = v > 1.0 ? 1.0 : (v < -1.0 ? -1.0 : v);
        const short s = (short) std::floor (v * 32767.0 + 0.5);
        std::fwrite (&s, 2, 1, f);
    }
    std::fclose (f);
}

// A decaying plucked string (Karplus-Strong), added into buf at start
static void pluck (std::vector<float>& buf, size_t start, double freq, double amp, double dur)
{
    const int period = std::max (2, (int) (kSr / freq + 0.5));
    std::vector<double> line (period);
    unsigned seed = (unsigned) (freq * 1000.0) + (unsigned) start;
    for (int i = 0; i < period; ++i)
    {
        seed = seed * 1664525u + 1013904223u;
        line[i] = ((seed >> 9) / 4194304.0 - 1.0) * amp;
    }
    const size_t n = (size_t) (dur * kSr);
    int idx = 0;
    double prev = 0.0;
    for (size_t i = 0; i < n && start + i < buf.size(); ++i)
    {
        const double cur = line[idx];
        const double next = 0.996 * 0.5 * (cur + prev);
        prev = cur;
        line[idx] = next;
        buf[start + i] += (float) cur;
        if (++idx >= period) idx = 0;
    }
}

static std::vector<float> makeChords (double seconds)
{
    std::vector<float> v ((size_t) (seconds * kSr), 0.0f);
    const double chords[4][4] = { { 82.4, 123.5, 164.8, 207.7 }, { 110.0, 164.8, 220.0, 277.2 },
                                  { 98.0, 146.8, 196.0, 246.9 }, { 73.4, 110.0, 146.8, 185.0 } };
    for (int c = 0; c * 2.0 < seconds; ++c)
        for (int s = 0; s < 4; ++s)
            pluck (v, (size_t) ((c * 2.0 + s * 0.012) * kSr), chords[c % 4][s], 0.22, 2.0);
    return v;
}

static std::vector<float> makeRiff (double seconds)
{
    std::vector<float> v ((size_t) (seconds * kSr), 0.0f);
    const double notes[8] = { 82.4, 98.0, 110.0, 123.5, 110.0, 98.0, 146.8, 130.8 };
    for (int i = 0; i * 0.25 < seconds; ++i)
        pluck (v, (size_t) (i * 0.25 * kSr), notes[i % 8], 0.35, 0.6);
    return v;
}

static std::vector<float> noise (double amp, double sec, unsigned seed)
{
    std::vector<float> v ((size_t) (sec * kSr));
    for (size_t i = 0; i < v.size(); ++i)
    {
        seed = seed * 1664525u + 1013904223u;
        v[i] = (float) (amp * ((seed >> 9) / 4194304.0 - 1.0));
    }
    return v;
}

int main (int argc, char** argv)
{
    const std::string renderDir = argc > 1 ? argv[1] : "renders";
    RingMod* ap = new RingMod();
    RingMod& a = *ap;
    a.prepare (kSr);

    std::printf ("\n1. Drive stage and LEVEL LED\n");
    {
        double prev = 0.0; bool mono = true;
        for (int k = 0; k <= 10; ++k)
        {
            const double g = RingMod::driveGain (k / 10.0);
            if (g <= prev) mono = false;
            prev = g;
        }
        std::printf ("  DRIVE gain %.2f at 0, %.2f at 5, %.1f at 10\n", RingMod::driveGain (0), RingMod::driveGain (0.5), RingMod::driveGain (1));
        check (mono && std::fabs (RingMod::driveGain (0) - 1.0) < 1e-9 && std::fabs (RingMod::driveGain (1) - (1.0 + 50.0 / 1.5)) < 1e-6,
               "DRIVE: x1 to x34.3 (1 + 50K / 1K5), rising");
        // Follower levels: quiet, healthy, hot
        const double ins[3] = { 0.01, 0.15, 1.0 };
        double env[3];
        for (int k = 0; k < 3; ++k)
        {
            defaults (a); a.setDrive (0.5); a.reset();
            run (a, sine (220.0, ins[k], 1.0));
            env[k] = a.envelopeVolts();
        }
        std::printf ("  follower: %.3f V, %.3f V, %.3f V (green from %.3f, red from %.3f, green off at %.3f)\n",
                     env[0], env[1], env[2], RingMod::levelGreenOn(), RingMod::levelRedOn(), RingMod::levelGreenOff());
        check (env[0] < RingMod::levelGreenOn(), "10 mV at DRIVE 5: LEVEL dark");
        check (env[1] > RingMod::levelGreenOn() && env[1] < RingMod::levelRedOn(), "150 mV at DRIVE 5: LEVEL green");
        check (env[2] > RingMod::levelGreenOff(), "1 V at DRIVE 5: LEVEL red");
        // Rails: hot input stays bounded
        defaults (a); a.setDrive (1.0); a.setMix (0.0); a.reset();
        std::vector<float> y = run (a, sine (220.0, 4.0, 0.5));
        check (allFinite (y, 3.0), "4 V in at DRIVE 10 stays bounded by the OTAs");
    }

    std::printf ("\n2. Ring modulation\n");
    {
        const double fin = 1000.0, fc = 300.0;
        defaults (a); a.setFrequency (potFor (fc, true)); a.setDrive (0.3); a.reset();
        std::vector<float> y = run (a, sine (fin, 0.1, 1.0));
        const size_t s0 = kSr / 2, s1 = kSr;
        const double lo = level (y, s0, s1, fin - fc), hi = level (y, s0, s1, fin + fc);
        const double thru = level (y, s0, s1, fin), car = level (y, s0, s1, fc);
        const double h3 = level (y, s0, s1, fin + 3 * fc);
        std::printf ("  1 kHz x 300 Hz: 700 Hz %.4f, 1300 Hz %.4f, 1 kHz %.2g, 300 Hz %.2g, 1900 Hz %.2g\n", lo, hi, thru, car, h3);
        check (lo > 0.005 && std::fabs (db (lo, hi)) < 1.0, "both sidebands, equal");
        check (db (lo, thru) > 40.0, "input suppressed by more than 40 dB at MIX 10");
        check (db (lo, car) > 40.0, "carrier suppressed by more than 40 dB");
        check (db (lo, h3) > 20.0 && db (lo, h3) < 50.0, "the sine-shaped carrier: 3rd-harmonic sidebands well down but there");
        // Measured carrier frequency from the sidebands' spacing, both ranges, ends of the knob
        const double pots[3] = { 0.0, 0.5, 1.0 };
        bool okF = true;
        for (int r = 0; r < 2; ++r)
            for (int k = 0; k < 3; ++k)
            {
                const double f = RingMod::carrierHz (pots[k], r == 1);
                if (r == 1 && f > 3000.0) continue;
                const double fi = r == 1 ? 5000.0 : 1000.0;
                defaults (a); a.setRangeHi (r == 1); a.setFrequency (pots[k]); a.setDrive (0.3); a.reset();
                std::vector<float> z = run (a, sine (fi, 0.1, 1.5));
                const double up = level (z, kSr / 2, (size_t) (1.5 * kSr), fi + f);
                const double off = level (z, kSr / 2, (size_t) (1.5 * kSr), fi + f * 1.06);
                if (f > 20.0 && ! (up > 3.0 * off)) okF = false;
                std::printf ("  %s FREQ %.1f: %.3g Hz, sideband %.4f (6%% off: %.4f)\n", r ? "HI" : "LO", pots[k] * 10, f, up, off);
            }
        check (std::fabs (RingMod::carrierHz (0, true) - 31.25) < 0.01 && std::fabs (RingMod::carrierHz (1, true) - 4000) < 0.1, "HI: 30 .. 4K as on the scale");
        check (std::fabs (RingMod::carrierHz (0, false) - 0.625) < 0.01 && std::fabs (RingMod::carrierHz (1, false) - 80) < 0.01, "LO: 0.6 .. 80 as on the scale");
        check (std::fabs (RingMod::carrierHz (2.0 / 7.0, true) - 125.0) < 0.1 && std::fabs (RingMod::carrierHz (5.0 / 7.0, true) - 1000.0) < 0.1,
               "scale marks 120 and 1K land on their ticks");
        check (okF, "sidebands where the knob says");
        // LO 1 Hz: tremolo-like, the level rises and falls twice per carrier cycle
        defaults (a); a.setRangeHi (false); a.setFrequency (potFor (1.0, false)); a.reset();
        std::vector<float> t = run (a, sine (440.0, 0.1, 3.0));
        double mx = 0, mn = 1e9;
        for (int k = 0; k < 20; ++k) { const double r = rmsRange (t, kSr + k * kSr / 20, kSr + (k + 1) * kSr / 20); mx = std::max (mx, r); mn = std::min (mn, r); }
        std::printf ("  LO 1 Hz: level %.4f .. %.4f over 50 ms windows\n", mn, mx);
        check (mx > 4.0 * mn, "LO range: slow amplitude modulation");
    }

    std::printf ("\n3. MIX and bypass\n");
    {
        double prev = -1.0; bool mono = true;
        for (int k = 0; k <= 20; ++k) { const double w = RingMod::wetFraction (k / 20.0, true); if (w < prev - 1e-12) mono = false; prev = w; }
        std::printf ("  wet share: %.3f at 0, %.3f at 5, %.3f at 10, %.4f bypassed\n", RingMod::wetFraction (0, true), RingMod::wetFraction (0.5, true),
                     RingMod::wetFraction (1, true), RingMod::wetFraction (1, false));
        check (mono && RingMod::wetFraction (0, true) < 0.01 && RingMod::wetFraction (1, true) > 0.99 && std::fabs (RingMod::wetFraction (0.5, true) - 0.5) < 0.02,
               "MIX crossfades dry to ring mod, half and half at 5");
        check (RingMod::wetFraction (1, false) < 0.001, "bypass sends the whole current to the dry OTA");
        const double fin = 1000.0, fc = 300.0;
        double thru[3], side[3];
        const double mixes[3] = { 0.0, 0.5, 1.0 };
        for (int k = 0; k < 3; ++k)
        {
            defaults (a); a.setFrequency (potFor (fc, true)); a.setMix (mixes[k]); a.setDrive (0.3); a.reset();
            std::vector<float> y = run (a, sine (fin, 0.1, 1.0));
            thru[k] = level (y, kSr / 2, kSr, fin); side[k] = level (y, kSr / 2, kSr, fin + fc);
        }
        std::printf ("  dry 1 kHz / sideband: MIX 0 %.4f / %.2g, MIX 5 %.4f / %.4f, MIX 10 %.2g / %.4f\n", thru[0], side[0], thru[1], side[1], thru[2], side[2]);
        check (db (thru[0], side[0]) > 40.0, "MIX 0: dry only");
        check (side[1] > 0.2 * side[2] && thru[1] > 0.2 * thru[0], "MIX 5: both");
        // Bypass: no carrier, fades in 18 ms rather than clicking
        defaults (a); a.setFrequency (potFor (fc, true)); a.setEffectOn (false); a.setDrive (0.3); a.reset();
        std::vector<float> y = run (a, sine (fin, 0.1, 1.0));
        std::printf ("  bypassed: 1 kHz %.4f, sideband %.2g\n", level (y, kSr / 2, kSr, fin), level (y, kSr / 2, kSr, fin + fc));
        check (db (level (y, kSr / 2, kSr, fin), level (y, kSr / 2, kSr, fin + fc)) > 50.0, "bypassed: no ring modulation");
        defaults (a); a.setMix (0.0); a.reset();
        std::vector<float> x = sine (fin, 0.1, 1.0), z (x.size());
        a.process (&x[0], &z[0], kSr / 2);
        a.setEffectOn (false);
        a.process (&x[kSr / 2], &z[kSr / 2], kSr / 2);
        double jump = 0.0;
        for (size_t i = kSr / 2 + 1; i < (size_t) kSr; ++i) jump = std::max (jump, (double) std::fabs (z[i] - z[i - 1]));
        double normal = 0.0;
        for (size_t i = kSr / 4; i < (size_t) kSr / 2; ++i) normal = std::max (normal, (double) std::fabs (z[i] - z[i - 1]));
        check (jump < 1.5 * normal + 1e-4, "footswitch at MIX 0: no step in the dry signal");
    }

    std::printf ("\n4. LFO\n");
    {
        std::printf ("  RATE: %.3f Hz .. %.1f Hz\n", RingMod::lfoHz (0), RingMod::lfoHz (1));
        check (std::fabs (RingMod::lfoHz (0) - 0.1) < 1e-9 && std::fabs (RingMod::lfoHz (1) - 25.6) < 1e-6, "RATE 0.1 .. 25 Hz as on the scale");
        check (std::fabs (RingMod::lfoHz (0.5) - 1.6) < 1e-6, "the unmarked top tick is 1.6 Hz");
        std::printf ("  AMOUNT: %.3f oct at 0, %.3f at 2, %.3f at 5, %.3f at 10\n", RingMod::lfoDepthOctaves (0), RingMod::lfoDepthOctaves (0.2),
                     RingMod::lfoDepthOctaves (0.5), RingMod::lfoDepthOctaves (1));
        check (RingMod::lfoDepthOctaves (0) == 0.0 && RingMod::lfoDepthOctaves (0.15) == 0.0, "AMOUNT: no LFO below Q5's threshold");
        check (std::fabs (RingMod::lfoDepthOctaves (1) - 1.0) < 1e-9, "AMOUNT 10: +-1 octave");
        // Measured: carrier frequency over time, both waves
        for (int w = 0; w < 2; ++w)
        {
            defaults (a); a.setAmount (1.0); a.setRate (RingMod::lfoHz (0.5) > 0 ? 0.5 : 0.5); a.setLfoSine (w == 1); a.reset();
            std::vector<float> x = sine (440.0, 0.1, 2.5), y (x.size());
            double fmin = 1e9, fmax = 0.0; int crossings = 0; double prevF = 0.0; int nearMid = 0, samples = 0;
            const double f0 = RingMod::carrierHz (0.5, true);
            for (size_t pos = 0; pos + 64 <= x.size(); pos += 64)
            {
                a.process (&x[pos], &y[pos], 64);
                const double f = a.currentCarrierHz();
                if (pos > (size_t) kSr / 2)
                {
                    fmin = std::min (fmin, f); fmax = std::max (fmax, f);
                    if ((f - f0) * (prevF - f0) < 0.0) ++crossings;
                    if (std::fabs (std::log (f / f0)) < 0.25 * std::log (2.0)) ++nearMid;
                    ++samples;
                }
                prevF = f;
            }
            const double oct = std::log (fmax / fmin) / std::log (2.0);
            std::printf ("  %s: carrier %.0f .. %.0f Hz (%.2f oct), %d crossings in 2 s, %.0f%% of the time near the middle\n",
                         w ? "sine" : "square", fmin, fmax, oct, crossings, 100.0 * nearMid / samples);
            check (std::fabs (oct - 2.0) < 0.1, "AMOUNT 10 sweeps 2 octaves peak to peak");
            check (std::abs (crossings - 6) <= 1, "RATE 5: 1.6 Hz measured");
            if (w == 0) check (nearMid < samples / 10, "square: jumps between two pitches");
            else        check (nearMid > samples / 10, "sine: glides through the middle");
        }
        defaults (a); a.setRate (1.0); a.reset();
        std::vector<float> s = sine (440.0, 0.1, 0.2), o (s.size());
        double lmin = 1, lmax = 0;
        for (size_t pos = 0; pos + 32 <= s.size(); pos += 32) { a.process (&s[pos], &o[pos], 32); lmin = std::min (lmin, a.lfoLedLevel()); lmax = std::max (lmax, a.lfoLedLevel()); }
        std::printf ("  LFO LED: %.2f .. %.2f\n", lmin, lmax);
        check (lmax - lmin > 0.7, "the LFO LED pulses with the triangle");
    }

    std::printf ("\n5. Carrier gate\n");
    {
        defaults (a); a.setRangeHi (true); a.setFrequency (potFor (1000.0, true)); a.reset();
        std::vector<float> x = sine (220.0, 0.1, 1.0);
        x.resize ((size_t) (4 * kSr), 0.0f);
        std::vector<float> y (x.size());
        double gIn = 0.0;
        for (size_t pos = 0; pos < x.size(); pos += 256)
        {
            const int n = (int) std::min ((size_t) 256, x.size() - pos);
            a.process (&x[pos], &y[pos], n);
            if (pos < (size_t) kSr && pos + n >= (size_t) kSr - 256) gIn = a.gateOpen();
        }
        std::printf ("  gate with 100 mV playing: %.2f, 3 s after it stops: %.2f, residual %.2g\n", gIn, a.gateOpen(), peakRange (y, 3 * kSr, 4 * kSr));
        check (gIn > 0.99, "gate open while playing");
        check (a.gateOpen() < 0.01, "gate shut after the note dies");
        check (peakRange (y, 3 * kSr, 4 * kSr) < 1e-4, "no carrier bleed in silence");
    }

    std::printf ("\n6. Stability sweep\n");
    {
        const double amps[4] = { 0.01, 0.1, 1.0, 4.0 };
        const double freqs[5] = { 41.0, 110.0, 440.0, 2000.0, 15000.0 };
        int runs = 0; bool ok = true;
        for (int c = 0; c < 6; ++c)
            for (int ai = 0; ai < 4; ++ai)
                for (int fi = 0; fi < 5; ++fi)
                {
                    const double v = (c & 1) ? 1.0 : 0.0, u = (c & 2) ? 1.0 : 0.0;
                    a.setAmount (v); a.setRate (u); a.setDrive (c >= 4 ? 1.0 : v); a.setMix (u); a.setFrequency (v);
                    a.setRangeHi (c != 2); a.setLfoSine (c & 1); a.setEffectOn (c != 5);
                    a.reset();
                    std::vector<float> y = run (a, sine (freqs[fi], amps[ai], 0.4));
                    if (! allFinite (y, 5.0)) ok = false;
                    ++runs;
                }
        unsigned seed = 1;
        for (int r = 0; r < 20; ++r)
        {
            double f[5];
            for (int k = 0; k < 5; ++k) { seed = seed * 1664525u + 1013904223u; f[k] = (seed >> 8) / 16777216.0; }
            a.setAmount (f[0]); a.setRate (f[1]); a.setDrive (f[2]); a.setMix (f[3]); a.setFrequency (f[4]);
            a.setRangeHi (r & 1); a.setLfoSine (r & 2);
            a.reset();
            std::vector<float> y = run (a, noise (2.0, 0.4, seed));
            if (! allFinite (y, 5.0)) ok = false;
            ++runs;
        }
        std::printf ("  %d runs\n", runs);
        check (ok, "no NaNs or runaways anywhere");
    }

    std::printf ("\n7. Automation, CPU, renders\n");
    {
        defaults (a);
        a.reset();
        std::vector<float> x = makeRiff (4.0), y (x.size());
        for (size_t pos = 0; pos < x.size(); pos += 64)
        {
            const double t = (double) pos / x.size();
            a.setAmount (0.5 + 0.5 * std::sin (2 * kPiT * 3 * t));
            a.setRate (0.5 + 0.5 * std::sin (2 * kPiT * 5 * t));
            a.setDrive (0.5 + 0.5 * std::sin (2 * kPiT * 6 * t));
            a.setMix (0.5 + 0.5 * std::sin (2 * kPiT * 7 * t));
            a.setFrequency (0.5 + 0.5 * std::sin (2 * kPiT * 8 * t));
            a.setLfoSine (std::sin (2 * kPiT * 10 * t) > 0.0);
            a.setRangeHi (std::sin (2 * kPiT * 11 * t) > 0.0);
            a.setEffectOn (std::sin (2 * kPiT * 4 * t) > 0.0);
            a.setInputGainDb (12.0 * std::sin (2 * kPiT * 2 * t));
            a.setOutputGainDb (12.0 * std::sin (2 * kPiT * 9 * t));
            const int n = (int) std::min ((size_t) 64, x.size() - pos);
            a.process (&x[pos], &y[pos], n);
        }
        check (allFinite (y, 10.0), "every control automated while playing");

        defaults (a); a.setAmount (0.7);
        a.reset();
        std::vector<float> ten = makeChords (10.0);
        std::clock_t t0 = std::clock();
        std::vector<float> yc = run (a, ten);
        const double secs = (double) (std::clock() - t0) / CLOCKS_PER_SEC;
        std::printf ("  CPU: %.1f%% of one core at 44.1 kHz\n", 10.0 * secs);
        check (secs < 3.0, "runs well under real time");

        struct R { const char* name; double amt; bool sine; double rate, drive, mix; bool hi; double fhz; bool on; bool chords; };
        const R renders[] = {
            { "bypass_riff",          0.0, true,  0.5, 0.5, 1.0, true,  350.0, false, false },
            { "bell_riff",            0.0, true,  0.5, 0.5, 1.0, true,  700.0, true,  false },
            { "dalek_riff",           0.0, true,  0.5, 0.6, 1.0, true,  30.0,  true,  false },
            { "lo_tremolo_chords",    0.0, true,  0.5, 0.4, 0.6, false, 5.0,   true,  true  },
            { "sine_sweep_chords",    1.0, true,  0.3, 0.5, 1.0, true,  500.0, true,  true  },
            { "square_trill_riff",    1.0, false, 0.6, 0.5, 0.8, true,  1000.0, true, false },
            { "half_mix_driven_riff", 0.0, true,  0.5, 0.9, 0.5, true,  250.0, true,  false },
        };
        std::vector<float> riff = makeRiff (8.0), chords = makeChords (8.0);
        for (size_t k = 0; k < sizeof (renders) / sizeof (renders[0]); ++k)
        {
            const R& r = renders[k];
            defaults (a);
            a.setAmount (r.amt); a.setLfoSine (r.sine); a.setRate (r.rate); a.setDrive (r.drive); a.setMix (r.mix);
            a.setRangeHi (r.hi); a.setFrequency (potFor (r.fhz, r.hi)); a.setEffectOn (r.on);
            a.reset();
            const std::vector<float>& src = r.chords ? chords : riff;
            std::vector<float> o = run (a, src);
            writeWav (renderDir + "/" + r.name + ".wav", o, kSr);
        }
        check (true, "demo renders written");
    }

    delete ap;
    std::printf ("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL DSP TESTS PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
