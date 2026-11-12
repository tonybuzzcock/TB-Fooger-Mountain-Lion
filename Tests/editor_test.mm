// editor_test.mm  (macOS only)
// Loads the built plugin, opens its panel in an offscreen window the way a host
// does, renders screenshots, drives the controls with synthetic mouse events,
// checks host automation messages, and closes it again.
//
//   editor_test <plugin binary> <output dir for PNGs>

#import <Cocoa/Cocoa.h>

#include "../Source/VST2/vst2_abi.h"
#include "../Source/VST2/Params.h"
#include "../Source/VST2/Editor.h"

#include <dlfcn.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <algorithm>
#include <vector>

static int failures = 0;
static void check (bool ok, const char* what)
{
    std::printf ("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (! ok) ++failures;
}

static int automateCalls = 0, beginCalls = 0, endCalls = 0;
static VstIntPtr VST_CALL hostCallback (AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float)
{
    switch (opcode)
    {
        case audioMasterVersion:   return 2400;
        case audioMasterAutomate:  ++automateCalls; return 0;
        case audioMasterBeginEdit: ++beginCalls; return 1;
        case audioMasterEndEdit:   ++endCalls; return 1;
        default:                   return 0;
    }
}

typedef AEffect* (*EntryProc) (audioMasterCallback);

static VstIntPtr call (AEffect* e, VstInt32 op, VstInt32 idx = 0, VstIntPtr val = 0, void* ptr = 0, float opt = 0.0f)
{
    return e->dispatcher (e, op, idx, val, ptr, opt);
}

static NSData* renderPNG (NSView* v, const std::string& path)
{
    const NSRect b = [v bounds];
    NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect: b];
    [v cacheDisplayInRect: b toBitmapImageRep: rep];
    NSData* png = [rep representationUsingType: NSPNGFileType properties: [NSDictionary dictionary]];
    [png writeToFile: [NSString stringWithUTF8String: path.c_str()] atomically: YES];
    std::printf ("  wrote %s (%lu bytes)\n", path.c_str(), (unsigned long) [png length]);
    return png;
}

// Send a mouse event at a point in the panel's (flipped) coordinates.
static void mouse (NSWindow* w, NSView* v, NSEventType type, NSPoint panelPt, int clicks = 1)
{
    const NSPoint wp = [v convertPoint: panelPt toView: nil];
    NSEvent* e = [NSEvent mouseEventWithType: type location: wp modifierFlags: 0 timestamp: 0
                                windowNumber: [w windowNumber] context: nil eventNumber: 0
                                  clickCount: clicks pressure: 1.0f];
    if (type == NSLeftMouseDown) [v mouseDown: e];
    else if (type == NSLeftMouseDragged) [v mouseDragged: e];
    else [v mouseUp: e];
}

static void pump (double secs)
{
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: secs]];
}

int main (int argc, char** argv)
{
    if (argc < 3) { std::printf ("usage: %s <plugin binary> <png dir>\n", argv[0]); return 2; }
    setvbuf (stdout, 0, _IONBF, 0);   // unbuffered, so a crash still shows how far it got
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    const std::string dir = argv[2];

    // Keep the test's presets away from any real ones
    const std::string presetFile = dir + "/test_presets/Presets.txt";
    setenv ("TBFOOGER_PRESET_FILE", presetFile.c_str(), 1);
    std::remove (presetFile.c_str());

    void* lib = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
    if (! lib) { std::printf ("dlopen failed: %s\n", dlerror()); return 1; }
    EntryProc entry = (EntryProc) dlsym (lib, "VSTPluginMain");
    if (! entry) { std::printf ("no entry point\n"); return 1; }
    AEffect* e = entry (hostCallback);
    call (e, effOpen);
    call (e, effSetSampleRate, 0, 0, 0, 44100.0f);
    call (e, effMainsChanged, 0, 1);

    using namespace tbfooger;
    std::printf ("Editor\n");
    check ((e->flags & effFlagsHasEditor) != 0, "plugin reports a custom editor");
    ERect* r = 0;
    call (e, effEditGetRect, 0, 0, &r);
    check (r && r->right - r->left == kEditorWidth && r->bottom - r->top == kEditorHeight,
           "editor size as declared");

    NSWindow* win = [[NSWindow alloc] initWithContentRect: NSMakeRect (0, 0, kEditorWidth, kEditorHeight)
                                                styleMask: NSBorderlessWindowMask
                                                  backing: NSBackingStoreBuffered defer: NO];
    NSView* parent = [win contentView];
    check (call (e, effEditOpen, 0, 0, parent) == 1, "effEditOpen succeeds");
    check ([[parent subviews] count] == 1, "panel view added to the host's view");
    NSView* panel = [[parent subviews] count] ? [[parent subviews] objectAtIndex: 0] : nil;
    if (! panel) return 1;
    check (NSEqualSizes ([panel frame].size, NSMakeSize (kEditorWidth, kEditorHeight)), "panel has the declared size");

    NSData* pngDefault = renderPNG (panel, dir + "/panel_default.png");
    check ([pngDefault length] > 10000, "panel renders");

    std::printf ("\nControls\n");
    // Drag the MIX knob down 50 px: -0.25
    e->setParameter (e, kMix, 0.5f);
    const float g0 = e->getParameter (e, kMix);
    automateCalls = beginCalls = endCalls = 0;
    mouse (win, panel, NSLeftMouseDown,    NSMakePoint (340, 168));
    mouse (win, panel, NSLeftMouseDragged, NSMakePoint (340, 193));
    mouse (win, panel, NSLeftMouseDragged, NSMakePoint (340, 218));
    mouse (win, panel, NSLeftMouseUp,      NSMakePoint (340, 218));
    const float g1 = e->getParameter (e, kMix);
    std::printf ("  Mix %.2f -> %.2f\n", g0, g1);
    check (std::fabs (g1 - (g0 - 0.25f)) < 0.02f, "dragging a knob down turns it down");
    check (automateCalls > 0 && beginCalls == 1 && endCalls == 1, "host gets begin / automate / end");

    mouse (win, panel, NSLeftMouseDown, NSMakePoint (340, 168), 2);
    mouse (win, panel, NSLeftMouseUp,   NSMakePoint (340, 168), 2);
    check (std::fabs (e->getParameter (e, kMix) - kDefaults[kMix]) < 1e-6f, "double-click resets a knob");

    // Each knob answers where it is drawn (dragged up from mid-travel)
    {
        const int knobs[7] = { kAmount, kRate, kDrive, kMix, kFreq, kInput, kOutput };
        const CGFloat kx[7] = { 134, 131, 237, 340, 350, 40, 108 };
        const CGFloat ky[7] = { 168, 398, 158, 168, 398, 826, 826 };
        bool all = true;
        for (int k = 0; k < 7; ++k)
        {
            e->setParameter (e, knobs[k], 0.5f);
            mouse (win, panel, NSLeftMouseDown,    NSMakePoint (kx[k], ky[k]));
            mouse (win, panel, NSLeftMouseDragged, NSMakePoint (kx[k], ky[k] - 20));
            mouse (win, panel, NSLeftMouseUp,      NSMakePoint (kx[k], ky[k] - 20));
            if (! (e->getParameter (e, knobs[k]) > 0.55f)) { all = false; std::printf ("  knob %d did not turn\n", knobs[k]); }
            e->setParameter (e, knobs[k], kDefaults[knobs[k]]);
        }
        check (all, "all seven knobs turn");
    }

    // Slide switches: click a side
    {
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (112, 280));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (112, 280));
        const bool sq = e->getParameter (e, kLfoWave) < 0.5f;
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (318, 280));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (318, 280));
        const bool lo = e->getParameter (e, kRange) < 0.5f;
        check (sq && lo, "slide switches: square and LO");
        pump (0.1);
        renderPNG (panel, dir + "/panel_square_lo.png");
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (156, 280));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (156, 280));
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (364, 280));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (364, 280));
        check (e->getParameter (e, kLfoWave) >= 0.5f && e->getParameter (e, kRange) >= 0.5f, "and back to sine and HI");
    }

    // Stomp switch: each press toggles
    mouse (win, panel, NSLeftMouseDown, NSMakePoint (237, 695));
    mouse (win, panel, NSLeftMouseUp,   NSMakePoint (237, 695));
    check (e->getParameter (e, kEffect) < 0.5f, "footswitch bypasses the effect");
    pump (0.1);
    renderPNG (panel, dir + "/panel_bypassed.png");
    mouse (win, panel, NSLeftMouseDown, NSMakePoint (237, 695));
    mouse (win, panel, NSLeftMouseUp,   NSMakePoint (237, 695));
    check (e->getParameter (e, kEffect) >= 0.5f, "and back in");

    // Frequency turned shows in the readout
    mouse (win, panel, NSLeftMouseDown,    NSMakePoint (350, 398));
    mouse (win, panel, NSLeftMouseDragged, NSMakePoint (350, 378));
    mouse (win, panel, NSLeftMouseUp,      NSMakePoint (350, 378));
    renderPNG (panel, dir + "/panel_readout.png");
    e->setParameter (e, kFreq, kDefaults[kFreq]);

    std::printf ("\nPresets\n");
    #define SLOT(k) NSMakePoint (206.0 + (k) * 33.0 + 14.5, 826.0)
    e->setParameter (e, kDrive, 0.3f);
    e->setParameter (e, kEffect, 0.0f);
    pump (0.1);
    mouse (win, panel, NSLeftMouseDown, NSMakePoint (175, 826));    // SAVE
    mouse (win, panel, NSLeftMouseUp,   NSMakePoint (175, 826));
    mouse (win, panel, NSLeftMouseDown, SLOT (2));                   // slot 3
    mouse (win, panel, NSLeftMouseUp,   SLOT (2));
    FILE* pf = std::fopen (presetFile.c_str(), "r");
    check (pf != 0, "SAVE then a slot writes the preset file");
    if (pf) std::fclose (pf);
    renderPNG (panel, dir + "/panel_preset_saved.png");

    e->setParameter (e, kDrive, 0.9f);
    e->setParameter (e, kEffect, 1.0f);
    pump (0.1);
    automateCalls = 0;
    mouse (win, panel, NSLeftMouseDown, SLOT (2));
    mouse (win, panel, NSLeftMouseUp,   SLOT (2));
    check (std::fabs (e->getParameter (e, kDrive) - 0.3f) < 1e-5f
           && e->getParameter (e, kEffect) < 0.5f, "clicking the slot recalls the saved settings");
    check (automateCalls >= kNumParams, "recall tells the host about every parameter");

    const float before = e->getParameter (e, kDrive);
    mouse (win, panel, NSLeftMouseDown, SLOT (5));                   // empty slot 6
    mouse (win, panel, NSLeftMouseUp,   SLOT (5));
    check (e->getParameter (e, kDrive) == before, "an empty slot changes nothing");

    std::printf ("\nHost automation shows on the panel\n");
    NSData* pngBefore = renderPNG (panel, dir + "/panel_before_host.png");
    e->setParameter (e, kRate, 0.9f);
    e->setParameter (e, kEffect, 1.0f);
    pump (0.3);
    NSData* pngAfter = renderPNG (panel, dir + "/panel_changed.png");
    check (! [pngAfter isEqualToData: pngBefore], "panel redraws after host changes");

    std::printf ("\nLEDs follow the circuit\n");
    {
        // Play a healthy signal so LEVEL lights; slow LFO so its LED is lit
        e->setParameter (e, kAmount, 0.65f);
        e->setParameter (e, kRate, 0.35f);
        e->setParameter (e, kDrive, 0.55f);
        e->setParameter (e, kMix, 0.62f);
        e->setParameter (e, kFreq, 0.72f);
        const int n = 22050;
        std::vector<float> a (n), b (n), oa (n), ob (n);
        for (int i = 0; i < n; ++i) a[i] = b[i] = (float) (0.15 * std::sin (2.0 * 3.14159265358979 * 220.0 * i / 44100.0));
        float* in[2] = { &a[0], &b[0] };
        float* out[2] = { &oa[0], &ob[0] };
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (350, 398));     // readout shows FREQUENCY
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (350, 398));
        NSData* quiet = renderPNG (panel, dir + "/panel_leds_off.png");
        e->processReplacing (e, in, out, n);
        pump (0.3);
        NSData* lit = renderPNG (panel, dir + "/panel_showcase.png");
        check (! [lit isEqualToData: quiet], "LEVEL and LFO LEDs light while playing");
    }
    std::printf ("\nClose\n");
    call (e, effEditClose);
    check ([[parent subviews] count] == 0, "effEditClose removes the panel");
    check (call (e, effEditOpen, 0, 0, parent) == 1 && [[parent subviews] count] == 1, "reopens");
    call (e, effEditClose);
    call (e, effMainsChanged, 0, 0);
    call (e, effClose);
    [win release];
    [pool release];      // drain before unloading the plugin's code
    dlclose (lib);

    std::printf ("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL EDITOR CHECKS PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
