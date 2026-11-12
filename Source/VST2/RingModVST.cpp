// RingModVST.cpp
// VST 2.4 wrapper for TB Fooger Ring Mod (the moogerfooger MF-102).
//
// - Parameters follow the unit's front panel (LFO Amount, LFO wave, Rate,
//   Drive, Mix, Lo/Hi, Frequency, the Effect footswitch), then the
//   plugin-only Input and Output trims.
// - Stereo in, stereo out: each side runs through its own copy of the
//   circuit with the same settings and the LFOs in step. A mono source (both
//   inputs identical) is processed once and the second copy kept in sync.
// - On the Mac, a custom panel (PanelView.mm); elsewhere the host shows
//   generic controls.
// - Reports the oversampler latency; no tail (the circuit has no memory
//   beyond its coupling networks).
// - Plain C++98; the editor uses only Cocoa APIs present in Mac OS X 10.8.

#include "vst2_abi.h"
#include "Params.h"
#include "Editor.h"
#include "Presets.h"
#include "../DSP/RingMod.h"

#include <cmath>
#include <cstdio>
#include <cstring>

#if defined(__SSE__) || defined(__x86_64__) || defined(_M_X64)
  #include <xmmintrin.h>
  #define TBVS_HAVE_SSE 1
#endif

namespace
{

const VstInt32 kUniqueID    = VST_FOURCC ('T', 'B', 'r', 'm');
const VstInt32 kVersion     = 1000;       // 1.0.0
const VstInt32 kNumChannels = 2;
const char* const kPluginName = "TB Fooger Ring Mod";

using namespace tbfooger;

void copyString (char* dst, const char* src, size_t maxLen)
{
    std::strncpy (dst, src, maxLen);
    dst[maxLen] = 0;
}

class RingModVST : public EditorHost
{
public:
    explicit RingModVST (audioMasterCallback hostCallback)
        : host (hostCallback), sampleRate (44100.0), editor (0)
    {
        std::memset (&effect, 0, sizeof (effect));
        effect.magic = kEffectMagic;
        effect.dispatcher = &dispatcherProc;
        effect.process = &processAccumulateProc;
        effect.setParameter = &setParameterProc;
        effect.getParameter = &getParameterProc;
        effect.processReplacing = &processReplacingProc;
        effect.processDoubleReplacing = 0;
        effect.numPrograms = 1;
        effect.numParams = kNumParams;
        effect.numInputs = kNumChannels;
        effect.numOutputs = kNumChannels;
        effect.flags = effFlagsCanReplacing;
#if defined(__APPLE__)
        effect.flags |= effFlagsHasEditor;
#endif
        effect.initialDelay = RingMod::latencySamples();
        effect.ioRatio = 1.0f;
        effect.object = this;
        effect.uniqueID = kUniqueID;
        effect.version = kVersion;

        for (int i = 0; i < kNumParams; ++i)
            params[i] = kDefaults[i];

        copyString (programName, "Default", kVstMaxProgNameLen);
        applyAllParams();
        prepare();
    }

    ~RingModVST()
    {
#if defined(__APPLE__)
        if (editor) editorClose (editor);
#endif
    }

    AEffect* getAEffect() { return &effect; }

    //==========================================================================
    // EditorHost
    float getParam (int index) const
    {
        return (index >= 0 && index < kNumParams) ? params[index] : 0.0f;
    }
    void getParamDisplay (int index, char* text) const
    {
        if (index >= 0 && index < kNumParams) formatParam (index, text);
        else text[0] = 0;
    }
    float getMeter (int which) const
    {
        if (which == kMeterLevel) return (float) unit[0].envelopeVolts();
        if (which == kMeterLfo)   return (float) unit[0].lfoLedLevel();
        return 0.0f;
    }
    void guiBeginEdit (int index) { if (host) host (&effect, audioMasterBeginEdit, index, 0, 0, 0.0f); }
    void guiEndEdit (int index)   { if (host) host (&effect, audioMasterEndEdit, index, 0, 0, 0.0f); }
    void guiSetParam (int index, float value)
    {
        setParameter (index, value);
        if (host && index >= 0 && index < kNumParams)
            host (&effect, audioMasterAutomate, index, 0, 0, params[index]);
    }

    void refreshPresets() { presets.load(); }
    bool presetExists (int slot) const { return presets.has (slot); }
    bool savePreset (int slot)
    {
        presets.load();                 // keep slots saved by other instances
        presets.put (slot, params);
        return presets.save();
    }
    bool loadPreset (int slot)
    {
        float v[kNumParams];
        if (! presets.get (slot, v)) return false;
        for (int i = 0; i < kNumParams; ++i)
        {
            guiBeginEdit (i);
            guiSetParam (i, v[i]);
            guiEndEdit (i);
        }
        return true;
    }

private:
    //==========================================================================
    static RingModVST* self (AEffect* e) { return static_cast<RingModVST*> (e->object); }

    static VstIntPtr VST_CALL dispatcherProc (AEffect* e, VstInt32 opcode, VstInt32 index,
                                              VstIntPtr value, void* ptr, float opt)
    {
        RingModVST* p = self (e);
        if (opcode == effClose)
        {
            delete p;
            return 1;
        }
        return p->dispatch (opcode, index, value, ptr, opt);
    }

    static void VST_CALL setParameterProc (AEffect* e, VstInt32 index, float value)
    {
        self (e)->setParameter (index, value);
    }

    static float VST_CALL getParameterProc (AEffect* e, VstInt32 index)
    {
        RingModVST* p = self (e);
        return (index >= 0 && index < kNumParams) ? p->params[index] : 0.0f;
    }

    static void VST_CALL processReplacingProc (AEffect* e, float** in, float** out, VstInt32 n)
    {
        self (e)->processReplacing (in, out, n);
    }

    static void VST_CALL processAccumulateProc (AEffect* e, float** in, float** out, VstInt32 n)
    {
        RingModVST* p = self (e);
        float* tmp[kNumChannels];
        for (int c = 0; c < kNumChannels; ++c)
            tmp[c] = p->scratch[c];

        VstInt32 done = 0;
        while (done < n)
        {
            const VstInt32 chunk = (n - done) < kScratch ? (n - done) : kScratch;
            float* ins[kNumChannels];
            for (int c = 0; c < kNumChannels; ++c)
                ins[c] = in[c] + done;
            p->processReplacing (ins, tmp, chunk);
            for (int c = 0; c < kNumChannels; ++c)
                for (VstInt32 i = 0; i < chunk; ++i)
                    out[c][done + i] += tmp[c][i];
            done += chunk;
        }
    }

    //==========================================================================
    VstIntPtr dispatch (VstInt32 opcode, VstInt32 index, VstIntPtr value, void* ptr, float opt)
    {
        switch (opcode)
        {
            case effOpen:              return 0;
            case effSetProgram:        return 0;
            case effGetProgram:        return 0;
            case effSetProgramName:
                if (ptr) copyString (programName, (const char*) ptr, kVstMaxProgNameLen);
                return 0;
            case effGetProgramName:
                if (ptr) copyString ((char*) ptr, programName, kVstMaxProgNameLen);
                return 0;
            case effGetProgramNameIndexed:
                if (ptr && index == 0) { copyString ((char*) ptr, programName, kVstMaxProgNameLen); return 1; }
                return 0;

            case effGetParamLabel:
                if (ptr && index >= 0 && index < kNumParams)
                {
                    const int k = kParamKind[index];
                    copyString ((char*) ptr, (k == kDb12 || k == kDb24) ? "dB" : ((k == kRateHz || k == kFreqHz) ? "Hz" : ""), kVstMaxParamStrLen);
                }
                return 0;
            case effGetParamDisplay:
                if (ptr && index >= 0 && index < kNumParams)
                    formatParam (index, (char*) ptr);
                return 0;
            case effGetParamName:
                if (ptr && index >= 0 && index < kNumParams)
                    copyString ((char*) ptr, kParamNames[index], kVstMaxParamStrLen);
                return 0;
            case effCanBeAutomated:
                return (index >= 0 && index < kNumParams) ? 1 : 0;

            case effSetSampleRate:
                if (opt > 0.0f) sampleRate = opt;
                return 0;
            case effSetBlockSize:
                return 0;
            case effMainsChanged:
                if (value) prepare();
                return 0;

#if defined(__APPLE__)
            case effEditGetRect:
                if (ptr)
                {
                    editRect.top = 0; editRect.left = 0;
                    editRect.bottom = (short) kEditorHeight; editRect.right = (short) kEditorWidth;
                    *(ERect**) ptr = &editRect;
                    return 1;
                }
                return 0;
            case effEditOpen:
                if (editor) { editorClose (editor); editor = 0; }
                if (ptr) editor = editorOpen (ptr, this);
                return editor ? 1 : 0;
            case effEditClose:
                if (editor) { editorClose (editor); editor = 0; }
                return 0;
            case effEditIdle:
                return 0;
#endif
            case effGetPlugCategory:   return kPlugCategEffect;
            case effGetEffectName:
                if (ptr) copyString ((char*) ptr, kPluginName, kVstMaxEffectNameLen);
                return 1;
            case effGetProductString:
                if (ptr) copyString ((char*) ptr, kPluginName, kVstMaxProductStrLen);
                return 1;
            case effGetVendorString:
                if (ptr) copyString ((char*) ptr, "TB", kVstMaxVendorStrLen);
                return 1;
            case effGetVendorVersion:  return kVersion;
            case effGetVstVersion:     return 2400;

            case effCanDo:
                if (ptr)
                {
                    const char* s = (const char*) ptr;
                    if (! std::strcmp (s, "plugAsChannelInsert") || ! std::strcmp (s, "plugAsSend"))
                        return 1;
                    if (! std::strcmp (s, "receiveVstEvents") || ! std::strcmp (s, "receiveVstMidiEvent")
                        || ! std::strcmp (s, "sendVstEvents") || ! std::strcmp (s, "sendVstMidiEvent"))
                        return -1;
                }
                return 0;

            case effGetTailSize:       return 0;
            case effStartProcess:      return 0;
            case effStopProcess:       return 0;
            default:                   return 0;
        }
    }

    void formatParam (int index, char* text) const
    {
        char buf[32];
        const float v = params[index];
        switch (kParamKind[index])
        {
            case kKnob:   std::snprintf (buf, sizeof (buf), "%.1f", v * 10.0); break;
            case kRateHz:
            {
                const double hz = RingMod::lfoHz (v);
                std::snprintf (buf, sizeof (buf), hz < 10.0 ? "%.2f" : "%.1f", hz);
                break;
            }
            case kFreqHz:
            {
                const double hz = RingMod::carrierHz (v, isOn (params[kRange]));
                if (hz >= 1000.0)    std::snprintf (buf, sizeof (buf), "%.2fk", hz / 1000.0);
                else if (hz >= 10.0) std::snprintf (buf, sizeof (buf), "%.0f", hz);
                else                 std::snprintf (buf, sizeof (buf), "%.2f", hz);
                break;
            }
            case kWave:    std::strcpy (buf, isOn (v) ? "Sine" : "Square"); break;
            case kRangeSw: std::strcpy (buf, isOn (v) ? "Hi" : "Lo"); break;
            case kSwitch:  std::strcpy (buf, isOn (v) ? "On" : "Bypass"); break;
            case kDb12:   std::snprintf (buf, sizeof (buf), "%+.1f", (v * 2.0 - 1.0) * kInputRangeDb); break;
            case kDb24:   std::snprintf (buf, sizeof (buf), "%+.1f", (v * 2.0 - 1.0) * kOutputRangeDb); break;
            default:      buf[0] = 0; break;
        }
        copyString (text, buf, kVstMaxParamStrLen);
    }

    void setParameter (VstInt32 index, float value)
    {
        if (index < 0 || index >= kNumParams) return;
        if (! (value == value)) return;   // NaN guard
        if (value < 0.0f) value = 0.0f;
        if (value > 1.0f) value = 1.0f;
        params[index] = value;
        applyParam (index);
    }

    void applyParam (int index)
    {
        const double v = params[index];
        const bool on = isOn (params[index]);
        for (int c = 0; c < kNumChannels; ++c)
        {
            RingMod& u = unit[c];
            switch (index)
            {
                case kAmount:  u.setAmount (v); break;
                case kLfoWave: u.setLfoSine (on); break;
                case kRate:    u.setRate (v); break;
                case kDrive:   u.setDrive (v); break;
                case kMix:     u.setMix (v); break;
                case kRange:   u.setRangeHi (on); break;
                case kFreq:    u.setFrequency (v); break;
                case kEffect:  u.setEffectOn (on); break;
                case kInput:   u.setInputGainDb ((v * 2.0 - 1.0) * kInputRangeDb); break;
                case kOutput:  u.setOutputGainDb ((v * 2.0 - 1.0) * kOutputRangeDb); break;
                default: break;
            }
        }
    }

    void applyAllParams()
    {
        for (int i = 0; i < kNumParams; ++i)
            applyParam (i);
    }

    void prepare()
    {
        for (int c = 0; c < kNumChannels; ++c)
            unit[c].prepare (sampleRate);
    }

    void processReplacing (float** in, float** out, VstInt32 n)
    {
        if (n <= 0 || ! in || ! out) return;

#if TBVS_HAVE_SSE
        const unsigned int oldCsr = _mm_getcsr();
        _mm_setcsr (oldCsr | 0x8040);   // flush denormals to zero
#endif
        // Inputs may alias the outputs (in-place): process in chunks through scratch
        VstInt32 done = 0;
        while (done < n)
        {
            const VstInt32 chunk = (n - done) < kScratch ? (n - done) : kScratch;
            std::memcpy (inBuf[0], in[0] + done, (size_t) chunk * sizeof (float));
            std::memcpy (inBuf[1], in[1] + done, (size_t) chunk * sizeof (float));
            const bool mono = in[0] == in[1]
                || std::memcmp (inBuf[0], inBuf[1], (size_t) chunk * sizeof (float)) == 0;
            unit[0].process (inBuf[0], out[0] + done, (int) chunk);
            if (mono)
            {
                if (out[1] != out[0])
                    std::memcpy (out[1] + done, out[0] + done, (size_t) chunk * sizeof (float));
                unit[1] = unit[0];      // keep the right side's circuit in step
            }
            else
                unit[1].process (inBuf[1], out[1] + done, (int) chunk);
            done += chunk;
        }

#if TBVS_HAVE_SSE
        _mm_setcsr (oldCsr);
#endif
    }

    //==========================================================================
    enum { kScratch = 512 };

    AEffect effect;
    audioMasterCallback host;
    double sampleRate;
    float params[kNumParams];
    char programName[kVstMaxProgNameLen + 1];
    RingMod unit[kNumChannels];
    void* editor;
    ERect editRect;
    PresetStore presets;
    float scratch[kNumChannels][kScratch];   // processAccumulate's outputs
    float inBuf[kNumChannels][kScratch];     // processReplacing's inputs (in-place safe)
};

} // namespace

//==============================================================================
VST_EXPORT AEffect* VSTPluginMain (audioMasterCallback host)
{
    if (! host)
        return 0;
    RingModVST* plugin = new RingModVST (host);
    return plugin->getAEffect();
}

#if defined(__APPLE__)
VST_EXPORT AEffect* main_macho (audioMasterCallback host)
{
    return VSTPluginMain (host);
}
#endif
