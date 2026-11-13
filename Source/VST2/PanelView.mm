// PanelView.mm
// The custom panel for TB Fooger Ring Mod: an original design laid out like
// the user's MF-102. Walnut sides, a black face, RING MODULATOR on one line
// across the top, the LFO and MODULATOR sections in outlined boxes with
// light grey header bands, black skirted knobs with white or brushed
// aluminium caps and scales as on the unit, blue slide switches, the LEVEL /
// LFO / BYPASS LEDs (lit from the running circuit), and the chrome
// footswitch with the user's TB electronic logo to its left. A strip of
// plugin controls runs along the bottom (Input, Output, presets, readout).
//
// Cocoa, manual retain/release, and only APIs that exist in Mac OS X 10.8.5.
// Everything is drawn in code; no image files.

#import <Cocoa/Cocoa.h>

#include "Editor.h"
#include "Params.h"
#include "Presets.h"
#include "TBLogo.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

using namespace tbfooger;

namespace
{

enum CtlType { kCtlKnob, kCtlSlide, kCtlFootswitch, kCtlSmallKnob };

struct Ctl
{
    int param;
    int type;
    CGFloat cx, cy, r;     // r: knob skirt radius, or a slide switch's half width
    bool whiteCap;         // big knobs: white cap (else brushed aluminium)
    const char* label;     // readout name
    const char* posA;      // small knob left end
    const char* posB;      // small knob right end
};

// The face (photo 1540 x 2489 scaled to 480 wide, with the gap above the
// footswitch cut to a quarter at the user's request), then the strip
const CGFloat kFaceH = 636.0;
const CGFloat kStripTop = 636.0;
const CGFloat kWoodL = 22.0, kWoodR = 457.0;
const NSRect kLfoBox = { { 59.0, 61.0 }, { 140.0, 407.0 } };
const NSRect kModBox = { { 273.0, 61.0 }, { 140.0, 407.0 } };
const CGFloat kHeaderH = 27.0;
const CGFloat kSlideHalfH = 17.0;

const Ctl kCtls[] = {
    { kAmount,  kCtlKnob,       134, 168, 40, true,  "AMOUNT",    0, 0 },
    { kLfoWave, kCtlSlide,      134, 280, 44, false, "LFO WAVE",  0, 0 },
    { kRate,    kCtlKnob,       131, 398, 40, false, "RATE",      0, 0 },
    { kDrive,   kCtlKnob,       237, 158, 29, true,  "DRIVE",     0, 0 },
    { kMix,     kCtlKnob,       340, 168, 40, false, "MIX",       0, 0 },
    { kRange,   kCtlSlide,      341, 280, 44, false, "LO / HI",   0, 0 },
    { kFreq,    kCtlKnob,       350, 398, 40, false, "FREQUENCY", 0, 0 },
    { kEffect,  kCtlFootswitch, 237, 555, 24, false, "EFFECT",    0, 0 },
    // Plugin strip
    { kInput,   kCtlSmallKnob,   40, 686, 17, false, "INPUT",  "-12", "+12" },
    { kOutput,  kCtlSmallKnob,  108, 686, 17, false, "OUTPUT", "-24", "+24" },
};
const int kNumCtls = (int) (sizeof (kCtls) / sizeof (kCtls[0]));

// Section titles and control names on the face
const CGFloat kTopLabelY = 97.0;      // AMOUNT, DRIVE, MIX
const CGFloat kLowLabelY = 331.0;     // RATE, FREQUENCY

// LEDs in the middle column
const NSPoint kLedLevel = { 237.0, 283.0 };
const NSPoint kLedLfo = { 237.0, 358.0 };
const NSPoint kLedBypass = { 237.0, 433.0 };

const NSRect kLogoBox = { { 56.0, 519.0 }, { 124.0, 72.0 } };   // left of the footswitch

// Preset section in the strip: a SAVE button and slots 1..8, then the readout
const CGFloat kPresetLabelY = 658.0;
const NSRect kSaveRect = { { 152.0, 673.0 }, { 46.0, 26.0 } };
const CGFloat kSlotX0 = 206.0, kSlotPitch = 33.0, kSlotW = 29.0, kSlotY = 673.0, kSlotH = 26.0;
const NSRect kReadoutRect = { { 14.0, 722.0 }, { 452.0, 46.0 } };

inline NSRect slotRect (int k) { return NSMakeRect (kSlotX0 + k * kSlotPitch, kSlotY, kSlotW, kSlotH); }

// Pointer angle (radians, 0 = up, clockwise positive) for a 0..1 value.
inline CGFloat valueAngle (CGFloat v) { return (CGFloat) ((-150.0 + 300.0 * v) * M_PI / 180.0); }

// Point at angle a (0 = up, clockwise) and radius r around (cx, cy) in flipped coordinates.
inline NSPoint polar (CGFloat cx, CGFloat cy, CGFloat r, CGFloat a)
{
    return NSMakePoint (cx + r * std::sin (a), cy - r * std::cos (a));
}

NSColor* rgb (int r, int g, int b) { return [NSColor colorWithCalibratedRed: r / 255.0 green: g / 255.0 blue: b / 255.0 alpha: 1.0]; }
NSColor* paint() { return rgb (226, 228, 230); }     // the face's light grey lettering

NSFont* boldFont (CGFloat size)
{
    NSFont* f = [NSFont fontWithName: @"Helvetica-Bold" size: size];
    return f ? f : [NSFont boldSystemFontOfSize: size];
}

NSFont* plainFont (CGFloat size)
{
    NSFont* f = [NSFont fontWithName: @"Helvetica" size: size];
    return f ? f : [NSFont systemFontOfSize: size];
}

NSFont* obliqueFont (CGFloat size)
{
    NSFont* f = [NSFont fontWithName: @"Helvetica-Oblique" size: size];
    return f ? f : plainFont (size);
}

NSDictionary* textAttrs (NSFont* font, NSColor* color, CGFloat kern)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
              font, NSFontAttributeName, color, NSForegroundColorAttributeName,
              [NSNumber numberWithDouble: kern], NSKernAttributeName, nil];
}

void drawText (const char* s, NSFont* font, NSColor* color, CGFloat cx, CGFloat cy, CGFloat kern = 0.0)
{
    NSString* str = [NSString stringWithUTF8String: s];
    NSDictionary* attrs = textAttrs (font, color, kern);
    const NSSize sz = [str sizeWithAttributes: attrs];
    [str drawAtPoint: NSMakePoint (cx - (sz.width - kern) * 0.5, cy - sz.height * 0.5) withAttributes: attrs];
}

// Number scale round a knob: n ticks over the 300 degree travel; labels[k]
// (may be 0 or "") at tick k; a second line under it from labels2.
void drawScale (CGFloat cx, CGFloat cy, CGFloat r, int n, const char* const* labels, const char* const* labels2)
{
    NSColor* white = paint();
    [white set];
    for (int k = 0; k < n; ++k)
    {
        const CGFloat a = valueAngle ((CGFloat) k / (n - 1));
        NSBezierPath* t = [NSBezierPath bezierPath];
        [t moveToPoint: polar (cx, cy, r + 3.0, a)];
        [t lineToPoint: polar (cx, cy, r + 10.0, a)];
        [t setLineWidth: 1.3];
        [t stroke];
        const char* l1 = labels ? labels[k] : 0;
        const char* l2 = labels2 ? labels2[k] : 0;
        if (l1 && l1[0])
        {
            const NSPoint p = polar (cx, cy, r + ((l2 && l2[0]) ? 22.0 : 19.0), a);
            if (l2 && l2[0])
            {
                drawText (l1, plainFont (10.5), white, p.x, p.y - 5.5);
                drawText (l2, plainFont (10.5), white, p.x, p.y + 5.5);
            }
            else
                drawText (l1, plainFont (11.0), white, p.x, p.y);
        }
    }
}

const char* const kScale010[11] = { "0", "", "2", "", "4", "", "6", "", "8", "", "10" };
const char* const kScaleRate[9] = { "0.1", "0.2", "0.4", "0.8", "", "3.2", "6.4", "12", "25" };
const char* const kScaleFreqHi[8] = { "30", "", "120", "", "", "1K", "", "4K" };
const char* const kScaleFreqLo[8] = { "0.6", "", "2.5", "", "", "20", "", "80" };

} // namespace

//==============================================================================
// Font size for one line in the readout: the usual size, or smaller so the
// whole text fits (a 40-character preset name never needs scrolling)
static CGFloat fitFontSize (const char* s, CGFloat size, CGFloat maxW)
{
    if (! s || ! *s) return size;
    NSString* str = [NSString stringWithUTF8String: s];
    if (! str) return size;
    NSDictionary* a = [NSDictionary dictionaryWithObject: boldFont (size) forKey: NSFontAttributeName];
    const CGFloat w = [str sizeWithAttributes: a].width;
    if (w <= maxW || w <= 0.0) return size;
    const CGFloat f = size * maxW / w;
    return f < 7.0 ? 7.0 : f;
}

@interface TBFoogerRingModPanelView : NSView <NSTextFieldDelegate>
{
    EditorHost* host;
    float shown[kNumParams];
    float meter[kNumMeters];
    NSTimer* timer;
    int dragCtl;
    CGFloat dragStartY, dragStartValue;
    int readoutParam;
    bool saveMode;
    int activePreset;
    bool presetUsed[kNumPresetSlots];
    char status[96];
    NSTextField* nameField;   // naming a preset, over the readout
    NSTextField* retiredField;// a finished one, taken away once its own event is over
    int namingSlot;
    NSImage* backdrop;    // wood and face texture, made once
}
- (id) initWithFrame: (NSRect) frame host: (EditorHost*) h;
- (void) shutdown;
@end

@implementation TBFoogerRingModPanelView

- (id) initWithFrame: (NSRect) frame host: (EditorHost*) h
{
    self = [super initWithFrame: frame];
    if (self)
    {
        host = h;
        for (int i = 0; i < kNumParams; ++i) shown[i] = host->getParam (i);
        for (int i = 0; i < kNumMeters; ++i) meter[i] = host->getMeter (i);
        dragCtl = -1;
        readoutParam = -1;
        saveMode = false;
        activePreset = -1;
        status[0] = 0;
        nameField = nil;
        retiredField = nil;
        namingSlot = -1;
        backdrop = nil;
        host->refreshPresets();
        for (int k = 0; k < kNumPresetSlots; ++k) presetUsed[k] = host->presetExists (k);
        timer = [[NSTimer timerWithTimeInterval: 1.0 / 20.0 target: self selector: @selector (tick:)
                                       userInfo: nil repeats: YES] retain];
        [[NSRunLoop currentRunLoop] addTimer: timer forMode: NSDefaultRunLoopMode];
        [[NSRunLoop currentRunLoop] addTimer: timer forMode: NSEventTrackingRunLoopMode];
    }
    return self;
}

- (void) shutdown
{
    [NSObject cancelPreviousPerformRequestsWithTarget: self];
    namingSlot = -1;
    [self dropRetired];
    if (nameField)
    {
        [nameField setDelegate: nil];
        [nameField setTarget: nil];
        [nameField removeFromSuperview];
        [nameField release];
        nameField = nil;
    }
    if (timer) { [timer invalidate]; [timer release]; timer = nil; }
    if (backdrop) { [backdrop release]; backdrop = nil; }
    host = 0;
}

- (void) dealloc
{
    [self shutdown];
    [super dealloc];
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (BOOL) acceptsFirstMouse: (NSEvent*) e { (void) e; return YES; }

// Host-side changes (automation, presets) and the LEDs redraw the panel.
- (void) tick: (NSTimer*) t
{
    (void) t;
    if (! host) return;
    bool changed = false, lamps = false;
    for (int i = 0; i < kNumParams; ++i)
    {
        const float v = host->getParam (i);
        if (v != shown[i]) { shown[i] = v; changed = true; }
    }
    for (int i = 0; i < kNumMeters; ++i)
    {
        const float v = host->getMeter (i);
        if (std::fabs (v - meter[i]) > 0.01f) { meter[i] = v; lamps = true; }
    }
    if (changed) [self setNeedsDisplay: YES];
    else if (lamps) [self setNeedsDisplayInRect: NSMakeRect (kLedLevel.x - 24.0, kLedLevel.y - 24.0, 48.0, kLedBypass.y - kLedLevel.y + 48.0)];
}

//------------------------------------------------------------------------------
// Drawing

// Walnut sides and the black face's fine grain, drawn once into an image
- (NSImage*) backdropImage
{
    if (backdrop) return backdrop;
    const CGFloat w = [self bounds].size.width;
    backdrop = [[NSImage alloc] initWithSize: NSMakeSize (w, kFaceH)];
    [backdrop lockFocus];

    // Walnut: warm brown with long wandering grain lines
    const CGFloat sideX[2] = { 0.0, kWoodR };
    const CGFloat sideW[2] = { kWoodL, w - kWoodR };
    unsigned seed = 102u;
    for (int s = 0; s < 2; ++s)
    {
        const NSRect side = NSMakeRect (sideX[s], 0, sideW[s], kFaceH);
        NSGradient* g = [[[NSGradient alloc] initWithColorsAndLocations:
                            rgb (122, 66, 34), 0.0, rgb (158, 92, 52), 0.45, rgb (134, 74, 40), 0.75, rgb (104, 54, 28), 1.0, nil] autorelease];
        [g drawInRect: side angle: 0.0];
        [NSGraphicsContext saveGraphicsState];
        NSRectClip (side);
        for (int k = 0; k < 26; ++k)
        {
            seed = seed * 1664525u + 1013904223u; const CGFloat x0 = side.origin.x + (seed >> 8) / 16777216.0 * side.size.width;
            seed = seed * 1664525u + 1013904223u; const CGFloat amp = 0.6 + (seed >> 8) / 16777216.0 * 2.4;
            seed = seed * 1664525u + 1013904223u; const CGFloat per = 60.0 + (seed >> 8) / 16777216.0 * 220.0;
            seed = seed * 1664525u + 1013904223u; const double dark = (seed >> 8) / 16777216.0;
            NSBezierPath* line = [NSBezierPath bezierPath];
            for (int y = 0; y <= (int) kFaceH; y += 6)
            {
                const NSPoint p = NSMakePoint (x0 + amp * std::sin (y / per * 2.0 * M_PI + k), y);
                if (y == 0) [line moveToPoint: p]; else [line lineToPoint: p];
            }
            [line setLineWidth: 0.6 + dark * 1.2];
            [[NSColor colorWithCalibratedRed: 0.22 green: 0.10 blue: 0.04 alpha: 0.15 + 0.35 * dark] set];
            [line stroke];
        }
        // Rounded edge: light on the outer side, shade where it meets the face
        NSGradient* edge = [[[NSGradient alloc] initWithColorsAndLocations:
                               [NSColor colorWithCalibratedWhite: 1.0 alpha: s == 0 ? 0.10 : 0.0], 0.0,
                               [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.0], 0.5,
                               [NSColor colorWithCalibratedWhite: 0.0 alpha: s == 0 ? 0.35 : 0.0], 1.0, nil] autorelease];
        [edge drawInRect: side angle: s == 0 ? 0.0 : 180.0];
        [NSGraphicsContext restoreGraphicsState];
    }

    // The black face, faintly grained like the anodised metal
    const NSRect face = NSMakeRect (kWoodL, 0, kWoodR - kWoodL, kFaceH);
    NSGradient* fg = [[[NSGradient alloc] initWithStartingColor: rgb (36, 37, 40) endingColor: rgb (24, 25, 27)] autorelease];
    [fg drawInRect: face angle: 90.0];
    for (int k = 0; k < 6000; ++k)
    {
        seed = seed * 1664525u + 1013904223u; const CGFloat x = kWoodL + (seed >> 8) / 16777216.0 * face.size.width;
        seed = seed * 1664525u + 1013904223u; const CGFloat y = (seed >> 8) / 16777216.0 * kFaceH;
        seed = seed * 1664525u + 1013904223u; const double q = (seed >> 8) / 16777216.0;
        [[NSColor colorWithCalibratedWhite: q < 0.5 ? 1.0 : 0.0 alpha: 0.03 + 0.05 * q] set];
        NSRectFillUsingOperation (NSMakeRect (x, y, 1.0, 1.0), NSCompositeSourceOver);
    }
    // Shadow under the wood's edges
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.5] set];
    NSRectFillUsingOperation (NSMakeRect (kWoodL, 0, 2.0, kFaceH), NSCompositeSourceOver);
    NSRectFillUsingOperation (NSMakeRect (kWoodR - 2.0, 0, 2.0, kFaceH), NSCompositeSourceOver);

    [backdrop unlockFocus];
    return backdrop;
}

- (void) drawScrewAt: (NSPoint) c
{
    const CGFloat r = 7.5;
    NSBezierPath* head = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - r, c.y - r, 2 * r, 2 * r)];
    NSGradient* g = [[[NSGradient alloc] initWithStartingColor: rgb (150, 150, 146) endingColor: rgb (52, 52, 50)] autorelease];
    [g drawInBezierPath: head relativeCenterPosition: NSMakePoint (-0.35, 0.4)];
    [rgb (16, 16, 16) set];
    [head setLineWidth: 0.8];
    [head stroke];
    // Phillips cross
    NSBezierPath* x = [NSBezierPath bezierPath];
    [x moveToPoint: NSMakePoint (c.x - 4.2, c.y)]; [x lineToPoint: NSMakePoint (c.x + 4.2, c.y)];
    [x moveToPoint: NSMakePoint (c.x, c.y - 4.2)]; [x lineToPoint: NSMakePoint (c.x, c.y + 4.2)];
    [x setLineWidth: 1.6];
    [rgb (28, 28, 28) set];
    [x stroke];
}

- (void) drawSectionBox: (NSRect) box title: (const char*) title size: (CGFloat) size
{
    const CGFloat rad = 9.0;
    NSBezierPath* outline = [NSBezierPath bezierPathWithRoundedRect: box xRadius: rad yRadius: rad];
    // Header band: the box's top, filled light grey
    [NSGraphicsContext saveGraphicsState];
    [outline addClip];
    [rgb (196, 198, 200) set];
    NSRectFill (NSMakeRect (box.origin.x, box.origin.y, box.size.width, kHeaderH));
    [NSGraphicsContext restoreGraphicsState];
    [paint() set];
    [outline setLineWidth: 1.4];
    [outline stroke];
    drawText (title, boldFont (size), rgb (70, 71, 74), NSMidX (box), box.origin.y + kHeaderH * 0.5 + 0.5, 0.5);
}

// Switch legends: lit ones glow blue-white, unlit ones are a dim grey
- (void) setLegendGlow: (bool) lit
{
    if (! lit) return;
    NSShadow* g = [[[NSShadow alloc] init] autorelease];
    [g setShadowOffset: NSMakeSize (0.0, 0.0)];
    [g setShadowBlurRadius: 7.0];
    [g setShadowColor: [NSColor colorWithCalibratedRed: 0.35 green: 0.75 blue: 1.0 alpha: 1.0]];
    [g set];
}

- (void) strokeLegend: (NSBezierPath*) path lit: (bool) lit
{
    [NSGraphicsContext saveGraphicsState];
    [self setLegendGlow: lit];
    [(lit ? rgb (200, 236, 255) : rgb (86, 88, 92)) set];
    [path stroke];
    if (lit) [path stroke];          // twice: a stronger glow
    [NSGraphicsContext restoreGraphicsState];
}

- (void) drawLegendText: (const char*) s at: (NSPoint) p lit: (bool) lit
{
    [NSGraphicsContext saveGraphicsState];
    [self setLegendGlow: lit];
    drawText (s, lit ? boldFont (12.5) : plainFont (12.0), lit ? rgb (200, 236, 255) : rgb (86, 88, 92), p.x, p.y);
    if (lit) drawText (s, boldFont (12.5), rgb (200, 236, 255), p.x, p.y);
    [NSGraphicsContext restoreGraphicsState];
}

- (void) drawBackground
{
    const NSRect b = [self bounds];
    [[self backdropImage] drawInRect: NSMakeRect (0, 0, b.size.width, kFaceH) fromRect: NSZeroRect
                           operation: NSCompositeSourceOver fraction: 1.0 respectFlipped: YES hints: nil];

    // Plugin strip, a slightly darker silver
    NSGradient* strip = [[[NSGradient alloc] initWithStartingColor: rgb (196, 199, 203)
                                                       endingColor: rgb (166, 170, 175)] autorelease];
    [strip drawInRect: NSMakeRect (0, kStripTop, b.size.width, b.size.height - kStripTop) angle: 90.0];
    [rgb (40, 40, 42) set];
    NSRectFill (NSMakeRect (0, kStripTop, b.size.width, 2.0));
    [rgb (238, 240, 242) set];
    NSRectFill (NSMakeRect (0, kStripTop + 2.0, b.size.width, 1.0));

    // Screws
    const NSPoint screws[6] = { { 39, 56 }, { 438, 56 }, { 35, 354 }, { 445, 354 }, { 34, 588 }, { 445, 586 } };
    for (int k = 0; k < 6; ++k) [self drawScrewAt: screws[k]];

    // The model name on one line, the unit's oblique lettering
    NSColor* white = paint();
    drawText ("RING MODULATOR", obliqueFont (21.0), white, 237.0, 37.0, 1.2);

    // Section boxes
    [self drawSectionBox: kLfoBox title: "LFO" size: 17.0];
    [self drawSectionBox: kModBox title: "MODULATOR" size: 15.0];

    // Control names
    NSFont* nameFont = plainFont (17.0);
    drawText ("AMOUNT", nameFont, white, 134.0, kTopLabelY, 0.4);
    drawText ("DRIVE", nameFont, white, 237.0, kTopLabelY, 0.4);
    drawText ("MIX", nameFont, white, 340.0, kTopLabelY, 0.4);
    drawText ("RATE", nameFont, white, 132.0, kLowLabelY, 0.4);
    drawText ("FREQUENCY", nameFont, white, 342.0, kLowLabelY, 0.4);
    NSFont* ledFont = plainFont (10.5);
    drawText ("LEVEL", ledFont, white, kLedLevel.x, kLedLevel.y - 28.0, 0.3);
    drawText ("LFO", ledFont, white, kLedLfo.x, kLedLfo.y - 25.0, 0.3);
    drawText ("BYPASS", ledFont, white, kLedBypass.x, kLedBypass.y - 25.0, 0.3);

    // Switch legends: square and sine wave; LO and HI. The selected side's
    // legend lights up, the other is dimmed, so the switch reads at a glance.
    {
        const bool sine = isOn (shown[kLfoWave]), hi = isOn (shown[kRange]);
        NSBezierPath* sq = [NSBezierPath bezierPath];
        const CGFloat y0 = 263.0, y1 = 252.0, x = 88.0, w = 8.0;
        [sq moveToPoint: NSMakePoint (x, y0)];
        for (int k = 0; k < 3; ++k)
        {
            [sq lineToPoint: NSMakePoint (x + k * 2 * w + 2.5, y0)];
            [sq lineToPoint: NSMakePoint (x + k * 2 * w + 2.5, y1)];
            [sq lineToPoint: NSMakePoint (x + k * 2 * w + w + 2.5, y1)];
            [sq lineToPoint: NSMakePoint (x + k * 2 * w + w + 2.5, y0)];
        }
        [sq lineToPoint: NSMakePoint (x + 6 * w + 2.0, y0)];
        [sq setLineWidth: 1.6];
        NSBezierPath* sn = [NSBezierPath bezierPath];
        for (int k = 0; k <= 60; ++k)
        {
            const NSPoint p = NSMakePoint (147.0 + k * 0.62, 257.5 - 6.0 * std::sin (k / 60.0 * 3.0 * M_PI));
            if (k == 0) [sn moveToPoint: p]; else [sn lineToPoint: p];
        }
        [sn setLineWidth: 1.8];
        [self strokeLegend: sq lit: ! sine];
        [self strokeLegend: sn lit: sine];
        [self drawLegendText: "LO" at: NSMakePoint (307.0, 258.0) lit: ! hi];
        [self drawLegendText: "HI" at: NSMakePoint (375.0, 258.0) lit: hi];
    }

    // Knob scales
    drawScale (kCtls[0].cx, kCtls[0].cy, kCtls[0].r, 11, kScale010, 0);
    drawScale (kCtls[4].cx, kCtls[4].cy, kCtls[4].r, 11, kScale010, 0);
    drawScale (kCtls[2].cx, kCtls[2].cy, kCtls[2].r, 9, kScaleRate, 0);
    drawScale (kCtls[6].cx, kCtls[6].cy, kCtls[6].r, 8, kScaleFreqHi, kScaleFreqLo);

    // TB electronic logo to the left of the footswitch, "electronic" in white on the black
    tblogo::drawTBLogo (kLogoBox, white);
}

// Black skirted knob: scalloped skirt, a white or brushed aluminium cap, a
// white dot on the skirt's edge for the pointer.
- (void) drawBigKnobAt: (NSPoint) ctr radius: (CGFloat) r value: (CGFloat) v whiteCap: (bool) whiteCap
{
    const CGFloat a = valueAngle (v);

    // Shadow and the scalloped skirt (turns with the knob)
    NSBezierPath* skirt = [NSBezierPath bezierPath];
    for (int k = 0; k <= 240; ++k)
    {
        const CGFloat t = (CGFloat) (2.0 * M_PI * k / 240.0);
        const CGFloat rr = r * (1.0 - 0.035 * (0.5 - 0.5 * std::cos (12.0 * t)));
        const NSPoint p = polar (ctr.x, ctr.y, rr, t + a);
        if (k == 0) [skirt moveToPoint: p]; else [skirt lineToPoint: p];
    }
    [skirt closePath];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* sh = [[[NSShadow alloc] init] autorelease];
    [sh setShadowOffset: NSMakeSize (2.0, -5.0)];
    [sh setShadowBlurRadius: 8.0];
    [sh setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.75]];
    [sh set];
    [rgb (10, 10, 12) set];
    [skirt fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient* sk = [[[NSGradient alloc] initWithColorsAndLocations:
                         rgb (78, 78, 84), 0.0, rgb (26, 26, 29), 0.5, rgb (6, 6, 8), 1.0, nil] autorelease];
    [sk drawInBezierPath: skirt relativeCenterPosition: NSMakePoint (-0.35, 0.5)];
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.9] set];
    [skirt setLineWidth: 1.0];
    [skirt stroke];

    // Body rising to the cap
    const CGFloat rb = r * 0.74;
    NSBezierPath* body = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (ctr.x - rb, ctr.y - rb, 2 * rb, 2 * rb)];
    NSGradient* bg = [[[NSGradient alloc] initWithColorsAndLocations:
                         rgb (64, 64, 70), 0.0, rgb (18, 18, 20), 0.6, rgb (4, 4, 6), 1.0, nil] autorelease];
    [bg drawInBezierPath: body relativeCenterPosition: NSMakePoint (-0.4, 0.55)];

    // Cap
    const CGFloat rc = r * 0.60;
    NSBezierPath* cap = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (ctr.x - rc, ctr.y - rc, 2 * rc, 2 * rc)];
    if (whiteCap)
    {
        NSGradient* cg = [[[NSGradient alloc] initWithStartingColor: rgb (255, 255, 253) endingColor: rgb (214, 214, 210)] autorelease];
        [cg drawInBezierPath: cap relativeCenterPosition: NSMakePoint (-0.3, 0.4)];
    }
    else
    {
        NSGradient* cg = [[[NSGradient alloc] initWithColorsAndLocations:
                             rgb (236, 238, 240), 0.0, rgb (176, 179, 183), 0.35, rgb (214, 216, 219), 0.6, rgb (150, 153, 157), 1.0, nil] autorelease];
        [cg drawInBezierPath: cap angle: -50.0];
        // Brushed rings
        [NSGraphicsContext saveGraphicsState];
        [cap addClip];
        for (int k = 1; k < 9; ++k)
        {
            const CGFloat rr = rc * k / 9.0;
            NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (ctr.x - rr, ctr.y - rr, 2 * rr, 2 * rr)];
            [[NSColor colorWithCalibratedWhite: (k & 1) ? 1.0 : 0.0 alpha: 0.06] set];
            [ring setLineWidth: 0.8];
            [ring stroke];
        }
        [NSGraphicsContext restoreGraphicsState];
    }
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.6] set];
    [cap setLineWidth: 0.8];
    [cap stroke];

    // The white dot on the skirt
    const NSPoint d = polar (ctr.x, ctr.y, r * 0.86, a);
    [rgb (248, 246, 236) set];
    [[NSBezierPath bezierPathWithOvalInRect: NSMakeRect (d.x - 2.6, d.y - 2.6, 5.2, 5.2)] fill];
}

// Grey knurled knob with a red position line (the strip's trims).
- (void) drawKnobAt: (NSPoint) ctr radius: (CGFloat) r value: (CGFloat) v
{
    [NSGraphicsContext saveGraphicsState];
    NSShadow* sh = [[[NSShadow alloc] init] autorelease];
    [sh setShadowOffset: NSMakeSize (1.5, -2.5)];
    [sh setShadowBlurRadius: 4.0];
    [sh setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.45]];
    [sh set];
    [rgb (90, 93, 97) set];
    [[NSBezierPath bezierPathWithOvalInRect: NSMakeRect (ctr.x - r, ctr.y - r, 2 * r, 2 * r)] fill];
    [NSGraphicsContext restoreGraphicsState];

    const int ridges = 40;
    for (int k = 0; k < ridges; ++k)
    {
        const CGFloat a0 = (CGFloat) (2.0 * M_PI * k / ridges);
        const CGFloat a1 = (CGFloat) (2.0 * M_PI * (k + 0.5) / ridges);
        NSBezierPath* w = [NSBezierPath bezierPath];
        [w moveToPoint: ctr];
        [w lineToPoint: polar (ctr.x, ctr.y, r, a0)];
        [w lineToPoint: polar (ctr.x, ctr.y, r, a1)];
        [w closePath];
        const CGFloat lit = 0.5 + 0.5 * std::cos (a0 + 0.8);
        [[NSColor colorWithCalibratedWhite: 0.40 + 0.22 * lit alpha: 1.0] set];
        [w fill];
    }

    const CGFloat rc = r * 0.78;
    NSGradient* cap = [[[NSGradient alloc] initWithStartingColor: rgb (172, 175, 179)
                                                     endingColor: rgb (104, 107, 111)] autorelease];
    NSBezierPath* capPath = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (ctr.x - rc, ctr.y - rc, 2 * rc, 2 * rc)];
    [cap drawInBezierPath: capPath angle: -60.0];
    [rgb (70, 72, 75) set];
    [capPath setLineWidth: 0.8];
    [capPath stroke];

    const CGFloat a = valueAngle (v);
    NSBezierPath* line = [NSBezierPath bezierPath];
    [line moveToPoint: polar (ctr.x, ctr.y, r * 0.18, a)];
    [line lineToPoint: polar (ctr.x, ctr.y, r * 0.98, a)];
    [line setLineWidth: 2.4];
    [line setLineCapStyle: NSRoundLineCapStyle];
    [rgb (200, 30, 30) set];
    [line stroke];
}

// Blue slide switch in its black slot: the selected half of the lever is
// raised and lit, the other dark (right = on: sine / HI).
- (void) drawSlide: (const Ctl&) c
{
    const bool right = isOn (shown[c.param]);
    const NSRect slot = NSMakeRect (c.cx - c.r, c.cy - kSlideHalfH, 2 * c.r, 2 * kSlideHalfH);
    NSBezierPath* sp = [NSBezierPath bezierPathWithRoundedRect: slot xRadius: 2 yRadius: 2];
    [rgb (8, 8, 9) set];
    [sp fill];
    [rgb (70, 72, 76) set];
    [sp setLineWidth: 1.0];
    [sp stroke];

    const NSRect lever = NSInsetRect (slot, 3.0, 4.0);
    const CGFloat half = lever.size.width * 0.5;
    const NSRect flat = right ? NSMakeRect (lever.origin.x, lever.origin.y, half, lever.size.height)
                              : NSMakeRect (lever.origin.x + half, lever.origin.y, half, lever.size.height);
    const NSRect raised = right ? NSMakeRect (lever.origin.x + half - 2.0, lever.origin.y - 2.0, half + 2.0, lever.size.height + 3.0)
                                : NSMakeRect (lever.origin.x, lever.origin.y - 2.0, half + 2.0, lever.size.height + 3.0);
    // The unselected half: dark, unlit blue
    NSGradient* fg = [[[NSGradient alloc] initWithStartingColor: rgb (36, 58, 92) endingColor: rgb (24, 40, 68)] autorelease];
    [fg drawInRect: flat angle: 90.0];

    // The selected half: raised and lit from inside, with a glow round it
    NSBezierPath* rp = [NSBezierPath bezierPathWithRoundedRect: raised xRadius: 2 yRadius: 2];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* glow = [[[NSShadow alloc] init] autorelease];
    [glow setShadowOffset: NSMakeSize (0.0, 0.0)];
    [glow setShadowBlurRadius: 12.0];
    [glow setShadowColor: [NSColor colorWithCalibratedRed: 0.30 green: 0.70 blue: 1.0 alpha: 1.0]];
    [glow set];
    [rgb (60, 150, 245) set];
    [rp fill];
    [rp fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient* rg = [[[NSGradient alloc] initWithColorsAndLocations:
                         rgb (210, 240, 255), 0.0, rgb (110, 190, 255), 0.35, rgb (46, 136, 236), 0.8, rgb (30, 104, 206), 1.0, nil] autorelease];
    [rg drawInBezierPath: rp angle: 90.0];
    [rgb (16, 60, 130) set];
    [rp setLineWidth: 0.8];
    [rp stroke];
    // The ridge where the lever steps up
    [[NSColor colorWithCalibratedWhite: 1.0 alpha: 0.6] set];
    const CGFloat ex = right ? NSMinX (raised) + 1.0 : NSMaxX (raised) - 1.0;
    NSRectFillUsingOperation (NSMakeRect (ex - 0.5, NSMinY (raised) + 2, 1.0, raised.size.height - 4), NSCompositeSourceOver);
}

// Bicolour LED: lens colour mixed from red and green brightness (0..1 each).
- (void) drawLedAt: (NSPoint) c red: (CGFloat) rr green: (CGFloat) gg
{
    const CGFloat lit = rr > gg ? rr : gg;
    if (lit > 0.02)
    {
        const CGFloat hr = 20.0;
        NSColor* tint = [NSColor colorWithCalibratedRed: (rr > 0.02 ? 1.0 : 0.15) green: (gg > 0.02 ? (rr > 0.02 ? 0.7 : 1.0) : 0.12) blue: 0.08 alpha: 1.0];
        NSGradient* halo = [[[NSGradient alloc] initWithColorsAndLocations:
                               [tint colorWithAlphaComponent: 0.7 * lit], 0.0,
                               [tint colorWithAlphaComponent: 0.22 * lit], 0.45,
                               [tint colorWithAlphaComponent: 0.0], 1.0, nil] autorelease];
        [halo drawInBezierPath: [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - hr, c.y - hr, 2 * hr, 2 * hr)]
              relativeCenterPosition: NSMakePoint (0.0, 0.0)];
    }
    const CGFloat rb = 10.0, rl = 7.5;
    NSBezierPath* bezel = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - rb, c.y - rb, 2 * rb, 2 * rb)];
    [rgb (14, 14, 15) set];
    [bezel fill];
    [rgb (60, 61, 64) set];
    [bezel setLineWidth: 1.0];
    [bezel stroke];
    // Dark lens: a dull smoky amber; lit: red, green or amber between
    const CGFloat r0 = 70, g0 = 62, b0 = 48;
    const CGFloat rLit = 255 * rr + 120 * gg, gLit = 60 * rr + 235 * gg, bLit = 30;
    const CGFloat k = lit;
    const CGFloat R = r0 + (std::min ((CGFloat) 255, rLit) - r0) * k;
    const CGFloat G = g0 + (std::min ((CGFloat) 255, gLit) - g0) * k;
    const CGFloat B = b0 + (bLit - b0) * k;
    NSBezierPath* lens = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - rl, c.y - rl, 2 * rl, 2 * rl)];
    NSGradient* lg = [[[NSGradient alloc] initWithStartingColor: [NSColor colorWithCalibratedRed: std::min (1.0, (R + 90) / 255.0) green: std::min (1.0, (G + 80) / 255.0) blue: std::min (1.0, (B + 60) / 255.0) alpha: 1.0]
                                                    endingColor: [NSColor colorWithCalibratedRed: R / 255.0 * 0.8 green: G / 255.0 * 0.8 blue: B / 255.0 * 0.8 alpha: 1.0]] autorelease];
    [lg drawInBezierPath: lens relativeCenterPosition: NSMakePoint (-0.3, 0.4)];
    [[NSColor colorWithCalibratedWhite: 1.0 alpha: 0.3 + 0.4 * k] set];
    [[NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - 3.8, c.y - 4.6, 2.8, 2.2)] fill];
}

- (void) drawLeds
{
    const bool on = isOn (shown[kEffect]);
    // LEVEL: green from 0.1 V, red from 1.06 V, green out above 2.02 V (the LM339 ladder)
    const float env = meter[kMeterLevel];
    const CGFloat green = (env > 0.0963f && env < 2.023f) ? 1.0 : 0.0;
    const CGFloat red = env > 1.060f ? 1.0 : 0.0;
    [self drawLedAt: kLedLevel red: red green: green];
    // LFO: red only, brightness following the triangle
    [self drawLedAt: kLedLfo red: meter[kMeterLfo] green: 0.0];
    // BYPASS: red with the effect in, green bypassed
    [self drawLedAt: kLedBypass red: on ? 1.0 : 0.0 green: on ? 0.0 : 1.0];
}

// Chrome stomp switch: click to toggle.
- (void) drawFootswitch: (const Ctl&) c
{
    const NSPoint ctr = NSMakePoint (c.cx, c.cy);
    const bool on = isOn (shown[kEffect]);

    // Hex nut
    NSBezierPath* nut = [NSBezierPath bezierPath];
    for (int k = 0; k < 6; ++k)
    {
        const NSPoint p = polar (ctr.x, ctr.y, c.r + 16.0, (CGFloat) (k * M_PI / 3.0));
        if (k == 0) [nut moveToPoint: p]; else [nut lineToPoint: p];
    }
    [nut closePath];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* ns = [[[NSShadow alloc] init] autorelease];
    [ns setShadowOffset: NSMakeSize (1.5, -3.0)];
    [ns setShadowBlurRadius: 5.0];
    [ns setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.7]];
    [ns set];
    [rgb (150, 152, 156) set];
    [nut fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient* ng = [[[NSGradient alloc] initWithStartingColor: rgb (232, 234, 237) endingColor: rgb (112, 115, 119)] autorelease];
    [ng drawInBezierPath: nut angle: -60.0];
    [rgb (50, 52, 55) set];
    [nut setLineWidth: 0.8];
    [nut stroke];
    // Threaded collar
    const CGFloat rcol = c.r + 6.0;
    NSBezierPath* collar = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (ctr.x - rcol, ctr.y - rcol, 2 * rcol, 2 * rcol)];
    NSGradient* colg = [[[NSGradient alloc] initWithStartingColor: rgb (120, 123, 128) endingColor: rgb (214, 216, 219)] autorelease];
    [colg drawInBezierPath: collar angle: -60.0];
    [rgb (60, 62, 65) set];
    [collar setLineWidth: 0.8];
    [collar stroke];
    // Fine threads
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.18] set];
    for (int k = 0; k < 48; ++k)
    {
        const CGFloat t = (CGFloat) (2.0 * M_PI * k / 48.0);
        NSBezierPath* th = [NSBezierPath bezierPath];
        [th moveToPoint: polar (ctr.x, ctr.y, c.r + 1.0, t)];
        [th lineToPoint: polar (ctr.x, ctr.y, rcol - 0.5, t)];
        [th setLineWidth: 0.6];
        [th stroke];
    }

    // Plunger, pressed in a touch with the effect in
    const CGFloat r = on ? c.r - 1.5 : c.r;
    [NSGraphicsContext saveGraphicsState];
    NSShadow* sh = [[[NSShadow alloc] init] autorelease];
    [sh setShadowOffset: NSMakeSize (1.0, on ? -1.0 : -2.5)];
    [sh setShadowBlurRadius: on ? 2.0 : 4.0];
    [sh setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.5]];
    [sh set];
    NSBezierPath* dome = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (ctr.x - r, ctr.y - r, 2 * r, 2 * r)];
    [rgb (150, 153, 157) set];
    [dome fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient* dg = [[[NSGradient alloc] initWithStartingColor: rgb (250, 251, 252) endingColor: rgb (110, 113, 118)] autorelease];
    [dg drawInBezierPath: dome relativeCenterPosition: NSMakePoint (-0.35, 0.4)];
    [rgb (55, 57, 60) set];
    [dome setLineWidth: 1.0];
    [dome stroke];
}

- (void) drawReadout
{
    const NSRect box = kReadoutRect;
    NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect: box xRadius: 4 yRadius: 4];
    NSGradient* glow = [[[NSGradient alloc] initWithStartingColor: rgb (206, 255, 120)
                                                      endingColor: rgb (150, 232, 70)] autorelease];
    [glow drawInBezierPath: p relativeCenterPosition: NSMakePoint (0.0, 0.0)];
    [rgb (60, 62, 65) set];
    [p setLineWidth: 1.0];
    [p stroke];

    if (status[0])
    {
        drawText (status, boldFont (fitFontSize (status, 16.0, NSWidth (kReadoutRect) - 16.0)), [NSColor blackColor], NSMidX (box), NSMidY (box));
    }
    else if (readoutParam >= 0 && host)
    {
        char disp[16] = { 0 };
        host->getParamDisplay (readoutParam, disp);
        char text[96];
        const char* name = 0;
        for (int i = 0; i < kNumCtls; ++i)
            if (kCtls[i].param == readoutParam) { name = kCtls[i].label; break; }
        const int kind = kParamKind[readoutParam];
        const char* unit = (kind == kRateHz || kind == kFreqHz) ? " Hz" : ((kind == kDb12 || kind == kDb24) ? " dB" : "");
        if (kind == kFreqHz && std::strchr (disp, 'k'))
        {
            // "1.23k" -> "1.23 kHz"
            char* k = std::strchr (disp, 'k');
            *k = 0;
            unit = " kHz";
        }
        std::snprintf (text, sizeof (text), "%s   %s%s", name ? name : "", disp, unit);
        drawText (text, boldFont (fitFontSize (text, 16.0, NSWidth (kReadoutRect) - 16.0)), [NSColor blackColor], NSMidX (box), NSMidY (box));
    }
}

- (void) drawPresets
{
    NSColor* ink = [NSColor blackColor];
    drawText ("PRESETS", boldFont (10.0), ink, (NSMinX (kSaveRect) + NSMaxX (slotRect (kNumPresetSlots - 1))) * 0.5, kPresetLabelY);

    NSBezierPath* sp = [NSBezierPath bezierPathWithRoundedRect: kSaveRect xRadius: 3 yRadius: 3];
    if (saveMode)
    {
        [rgb (200, 30, 30) set];
        [sp fill];
    }
    else
    {
        NSGradient* g = [[[NSGradient alloc] initWithStartingColor: rgb (232, 234, 236) endingColor: rgb (160, 163, 167)] autorelease];
        [g drawInBezierPath: sp angle: -90.0];
    }
    [rgb (40, 41, 43) set];
    [sp setLineWidth: 1.0];
    [sp stroke];
    drawText ("SAVE", boldFont (11.0), saveMode ? [NSColor whiteColor] : ink, NSMidX (kSaveRect), NSMidY (kSaveRect));

    for (int k = 0; k < kNumPresetSlots; ++k)
    {
        const NSRect r = slotRect (k);
        NSBezierPath* bp = [NSBezierPath bezierPathWithRoundedRect: r xRadius: 3 yRadius: 3];
        NSColor* fill = (k == activePreset) ? rgb (178, 245, 96) : (presetUsed[k] ? rgb (46, 47, 50) : rgb (214, 216, 219));
        NSColor* text = (k == activePreset) ? ink : (presetUsed[k] ? [NSColor whiteColor] : rgb (120, 122, 126));
        [fill set];
        [bp fill];
        [rgb (40, 41, 43) set];
        [bp setLineWidth: 1.0];
        [bp stroke];
        char num[4];
        std::snprintf (num, sizeof (num), "%d", k + 1);
        drawText (num, boldFont (12.0), text, NSMidX (r), NSMidY (r));
    }
}

- (void) drawRect: (NSRect) dirty
{
    (void) dirty;
    [self drawBackground];
    NSColor* ink = [NSColor blackColor];

    for (int i = 0; i < kNumCtls; ++i)
    {
        const Ctl& c = kCtls[i];
        switch (c.type)
        {
            case kCtlKnob:
                [self drawBigKnobAt: NSMakePoint (c.cx, c.cy) radius: c.r value: shown[c.param] whiteCap: c.whiteCap];
                break;
            case kCtlSlide:
                [self drawSlide: c];
                break;
            case kCtlFootswitch:
                [self drawFootswitch: c];
                break;
            case kCtlSmallKnob:
            {
                [self drawKnobAt: NSMakePoint (c.cx, c.cy) radius: c.r value: shown[c.param]];
                drawText (c.label, boldFont (10.5), ink, c.cx, kPresetLabelY);
                drawText (c.posA, plainFont (9.5), ink, c.cx - c.r + 1.0, c.cy + c.r + 9.0);
                drawText (c.posB, plainFont (9.5), ink, c.cx + c.r - 1.0, c.cy + c.r + 9.0);
                break;
            }
            default: break;
        }
    }
    [self drawLeds];
    [self drawPresets];
    [self drawReadout];
}

//------------------------------------------------------------------------------
// Mouse

- (int) ctlAtPoint: (NSPoint) p
{
    for (int i = 0; i < kNumCtls; ++i)
    {
        const Ctl& c = kCtls[i];
        if (c.type == kCtlSlide)
        {
            if (NSPointInRect (p, NSInsetRect (NSMakeRect (c.cx - c.r, c.cy - kSlideHalfH, 2 * c.r, 2 * kSlideHalfH), -4.0, -4.0)))
                return i;
            continue;
        }
        const CGFloat reach = c.type == kCtlFootswitch ? c.r + 16.0 : c.r + 6.0;
        const CGFloat dx = p.x - c.cx, dy = p.y - c.cy;
        if (dx * dx + dy * dy < reach * reach) return i;
    }
    return -1;
}

- (void) setParam: (int) param value: (float) v
{
    if (! host) return;
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    host->guiSetParam (param, v);
    shown[param] = host->getParam (param);
    readoutParam = param;
    [self setNeedsDisplay: YES];
}

// SAVE button and preset slots. Returns YES if the click was handled here.
//------------------------------------------------------------------------------
// Preset names: after a save, or a click on the readout while a preset is in
// use, the readout becomes a text box. Return keeps the name, Esc leaves the
// old one, a click elsewhere keeps what was typed. The text shrinks to fit.

- (void) showPreset: (int) slot verb: (const char*) verb
{
    char name[kMaxPresetName + 8] = { 0 };
    if (host) host->presetName (slot, name, (int) sizeof (name));
    if (name[0]) std::snprintf (status, sizeof (status), "%d   %s", slot + 1, name);
    else         std::snprintf (status, sizeof (status), "PRESET %d %s", slot + 1, verb);
    [self setNeedsDisplay: YES];
}

- (void) dropRetired
{
    if (! retiredField) return;
    [retiredField setDelegate: nil];
    [retiredField setTarget: nil];
    [retiredField removeFromSuperview];
    [retiredField release];
    retiredField = nil;
    if (! nameField && [self window]) [[self window] makeFirstResponder: self];
    [self setNeedsDisplay: YES];
}

// Size the name box's font so everything typed (or the hint) fits
- (void) fitNameField
{
    if (! nameField) return;
    const CGFloat maxW = NSWidth ([nameField frame]) - 10.0;
    NSString* s = [nameField stringValue];
    if ([s length] == 0) s = [[nameField cell] placeholderString];
    const char* u = s ? [s UTF8String] : "";
    [nameField setFont: boldFont (fitFontSize (u, 16.0, maxW))];
}

- (void) startNaming: (int) slot
{
    if (! host || slot < 0) return;
    if (nameField) [self finishNaming: YES];
    namingSlot = slot;
    char name[kMaxPresetName + 8] = { 0 };
    host->presetName (slot, name, (int) sizeof (name));

    const CGFloat fh = (CGFloat) (16.0 * 1.35 + 4.0);
    const NSRect r = kReadoutRect;
    nameField = [[NSTextField alloc] initWithFrame: NSMakeRect (NSMinX (r) + 6.0, NSMidY (r) - fh * 0.5,
                                                                 NSWidth (r) - 12.0, fh)];
    [nameField setBezeled: NO];
    [nameField setBordered: NO];
    [nameField setDrawsBackground: YES];
    [nameField setBackgroundColor: rgb (190, 248, 100)];
    [nameField setTextColor: [NSColor blackColor]];
    [nameField setAlignment: NSCenterTextAlignment];
    [nameField setFocusRingType: NSFocusRingTypeNone];
    [nameField setStringValue: [NSString stringWithUTF8String: name]];
    char hint[64];
    std::snprintf (hint, sizeof (hint), "NAME PRESET %d, THEN RETURN", slot + 1);
    [[nameField cell] setPlaceholderString: [NSString stringWithUTF8String: hint]];
    [[nameField cell] setScrollable: YES];
    [nameField setTarget: self];
    [nameField setAction: @selector (nameEntered:)];
    [nameField setDelegate: self];
    [self fitNameField];
    [self addSubview: nameField];
    status[0] = 0;
    readoutParam = -1;
    [[self window] makeFirstResponder: nameField];
    [self setNeedsDisplay: YES];
}

- (void) finishNaming: (BOOL) keep
{
    const int slot = namingSlot;
    if (slot < 0) return;
    namingSlot = -1;                       // only once (Return, then end of editing)
    if (keep && host && nameField)
    {
        const char* utf8 = [[nameField stringValue] UTF8String];
        host->renamePreset (slot, utf8 ? utf8 : "");
    }
    [self showPreset: slot verb: "SAVED"];
    // the field may be in the middle of sending its action: take it away afterwards
    [self dropRetired];
    retiredField = nameField;
    nameField = nil;
    [retiredField setDelegate: nil];
    [retiredField setTarget: nil];
    [self performSelector: @selector (dropRetired) withObject: nil afterDelay: 0.0];
}

- (void) nameEntered: (id) sender
{
    (void) sender;
    [self finishNaming: YES];
}

- (void) controlTextDidChange: (NSNotification*) n
{
    (void) n;
    [self fitNameField];
}

- (void) controlTextDidEndEditing: (NSNotification*) n
{
    (void) n;
    [self finishNaming: YES];
}

- (BOOL) control: (NSControl*) c textView: (NSTextView*) tv doCommandBySelector: (SEL) sel
{
    (void) c; (void) tv;
    if (sel == @selector (cancelOperation:)) { [self finishNaming: NO]; return YES; }
    return NO;
}

- (BOOL) presetClick: (NSPoint) p
{
    if (NSPointInRect (p, kSaveRect))
    {
        saveMode = ! saveMode;
        std::snprintf (status, sizeof (status), "%s", saveMode ? "SAVE: CLICK A SLOT 1-8" : "");
        [self setNeedsDisplay: YES];
        return YES;
    }
    for (int k = 0; k < kNumPresetSlots; ++k)
    {
        if (! NSPointInRect (p, slotRect (k))) continue;
        if (saveMode)
        {
            const bool ok = host->savePreset (k);
            saveMode = false;
            host->refreshPresets();
            for (int j = 0; j < kNumPresetSlots; ++j) presetUsed[j] = host->presetExists (j);
            if (ok)
            {
                activePreset = k;
                std::snprintf (status, sizeof (status), "PRESET %d SAVED", k + 1);
                [self setNeedsDisplay: YES];
                [self startNaming: k];
                return YES;
            }
            std::snprintf (status, sizeof (status), "COULD NOT SAVE PRESET %d", k + 1);
        }
        else
        {
            host->refreshPresets();
            for (int j = 0; j < kNumPresetSlots; ++j) presetUsed[j] = host->presetExists (j);
            if (presetUsed[k] && host->loadPreset (k))
            {
                for (int j = 0; j < kNumParams; ++j) shown[j] = host->getParam (j);
                activePreset = k;
                [self showPreset: k verb: "LOADED"];
            }
            else
                std::snprintf (status, sizeof (status), "PRESET %d IS EMPTY", k + 1);
        }
        [self setNeedsDisplay: YES];
        return YES;
    }
    return NO;
}

- (void) mouseDown: (NSEvent*) e
{
    const NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
    if (! host) return;
    if (nameField) [self finishNaming: YES];
    if (NSPointInRect (p, kReadoutRect) && activePreset >= 0)
    {
        [self startNaming: activePreset];
        return;
    }
    if ([self presetClick: p]) return;
    const int i = [self ctlAtPoint: p];
    if (i < 0) return;
    const Ctl& c = kCtls[i];
    shown[c.param] = host->getParam (c.param);   // the live value, even between timer ticks
    readoutParam = c.param;
    status[0] = 0;
    activePreset = -1;     // settings are being changed away from the preset

    if (c.type == kCtlFootswitch || c.type == kCtlSlide)
    {
        // Footswitch: each press toggles. Slide: click a side to move it there.
        float v = isOn (shown[c.param]) ? 0.0f : 1.0f;
        if (c.type == kCtlSlide) v = p.x >= c.cx ? 1.0f : 0.0f;
        host->guiBeginEdit (c.param);
        [self setParam: c.param value: v];
        host->guiEndEdit (c.param);
        return;
    }

    host->guiBeginEdit (c.param);
    if ([e clickCount] == 2)
        [self setParam: c.param value: kDefaults[c.param]];   // double-click: back to default
    dragCtl = i;
    dragStartY = p.y;
    dragStartValue = shown[c.param];
    [self setNeedsDisplay: YES];
}

- (void) mouseDragged: (NSEvent*) e
{
    if (dragCtl < 0 || ! host) return;
    const Ctl& c = kCtls[dragCtl];
    const NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
    const bool fine = ([e modifierFlags] & NSShiftKeyMask) != 0;
    const CGFloat perPixel = fine ? 1.0 / 1000.0 : 1.0 / 200.0;
    const CGFloat v = dragStartValue + (dragStartY - p.y) * perPixel;
    [self setParam: c.param value: (float) v];
}

- (void) mouseUp: (NSEvent*) e
{
    (void) e;
    if (dragCtl >= 0 && host) host->guiEndEdit (kCtls[dragCtl].param);
    dragCtl = -1;
}

- (void) scrollWheel: (NSEvent*) e
{
    const NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
    const int i = [self ctlAtPoint: p];
    if (i < 0 || ! host) return;
    const Ctl& c = kCtls[i];
    if (c.type != kCtlKnob && c.type != kCtlSmallKnob) return;
    const CGFloat d = [e deltaY];
    if (d == 0.0) return;
    status[0] = 0;
    activePreset = -1;
    host->guiBeginEdit (c.param);
    [self setParam: c.param value: (float) (shown[c.param] + d * 0.01)];
    host->guiEndEdit (c.param);
}

@end

//==============================================================================
namespace tbfooger
{

// Both calls use their own autorelease pool, so nothing of this plugin's is
// left waiting in the host's pool when the editor closes or the plugin unloads.
void* editorOpen (void* parentView, EditorHost* host)
{
    NSView* parent = (NSView*) parentView;
    if (! parent || ! host) return 0;
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    TBFoogerRingModPanelView* v = [[TBFoogerRingModPanelView alloc]
                                     initWithFrame: NSMakeRect (0, 0, kEditorWidth, kEditorHeight) host: host];
    if (v) [parent addSubview: v];
    [pool release];
    return (void*) v;    // retained until editorClose
}

void editorClose (void* handle)
{
    TBFoogerRingModPanelView* v = (TBFoogerRingModPanelView*) handle;
    if (! v) return;
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    [v shutdown];
    [v removeFromSuperview];
    [v release];
    [pool release];
}

} // namespace tbfooger
