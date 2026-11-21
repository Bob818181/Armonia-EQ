// Callback di rendering Core Audio (solo macOS).
//
// Il motore usa un "aggregate device" privato composto da:
//   [0] il dispositivo di uscita reale (clock principale)
//   [1] il driver loopback (es. BlackHole 2ch) con compensazione della deriva
// Un'unica AUHAL legge i canali di ingresso del loopback (= audio di sistema),
// li elabora con ArmoniaDSP e li scrive sui canali stereo del dispositivo reale.
// Nessuna allocazione, lock o chiamata Objective-C/Swift nel thread audio.

#if defined(__APPLE__)

#include "ArmoniaRender.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

struct AEQRenderContext {
    AudioUnit unit;
    AEQEngine *dsp;
    AudioBufferList *inputList;
    float **inputBuffers;
    UInt32 inputChannels;
    UInt32 loopLeft, loopRight;
    UInt32 outLeft, outRight;
    int outMono;
    UInt32 maxFrames;
    float *workL, *workR;
    _Atomic int renderErrors;
};

AEQRenderContext *aeq_render_create(AEQEngine *dsp, UInt32 inputChannels, UInt32 loopLeft, UInt32 loopRight,
                                    UInt32 outLeft, UInt32 outRight, int outMono, UInt32 maxFrames) {
    if (!dsp || inputChannels == 0 || maxFrames == 0) return NULL;
    AEQRenderContext *c = (AEQRenderContext *)calloc(1, sizeof(AEQRenderContext));
    if (!c) return NULL;
    c->dsp = dsp;
    c->inputChannels = inputChannels;
    c->loopLeft = loopLeft;
    c->loopRight = loopRight;
    c->outLeft = outLeft;
    c->outRight = outRight;
    c->outMono = outMono;
    c->maxFrames = maxFrames;
    c->inputList = (AudioBufferList *)calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * inputChannels);
    c->inputBuffers = (float **)calloc(inputChannels, sizeof(float *));
    c->workL = (float *)calloc(maxFrames, sizeof(float));
    c->workR = (float *)calloc(maxFrames, sizeof(float));
    if (!c->inputList || !c->inputBuffers || !c->workL || !c->workR) {
        aeq_render_destroy(c);
        return NULL;
    }
    c->inputList->mNumberBuffers = inputChannels;
    for (UInt32 i = 0; i < inputChannels; i++) {
        c->inputBuffers[i] = (float *)calloc(maxFrames, sizeof(float));
        if (!c->inputBuffers[i]) {
            aeq_render_destroy(c);
            return NULL;
        }
        c->inputList->mBuffers[i].mNumberChannels = 1;
        c->inputList->mBuffers[i].mDataByteSize = maxFrames * sizeof(float);
        c->inputList->mBuffers[i].mData = c->inputBuffers[i];
    }
    return c;
}

void aeq_render_set_unit(AEQRenderContext *c, AudioUnit unit) {
    if (c) c->unit = unit;
}

void aeq_render_destroy(AEQRenderContext *c) {
    if (!c) return;
    if (c->inputBuffers) {
        for (UInt32 i = 0; i < c->inputChannels; i++) free(c->inputBuffers[i]);
        free(c->inputBuffers);
    }
    free(c->inputList);
    free(c->workL);
    free(c->workR);
    free(c);
}

int aeq_render_error_count(AEQRenderContext *c) {
    return c ? atomic_load(&c->renderErrors) : 0;
}

OSStatus aeq_render_callback(void *_Nonnull inRefCon, AudioUnitRenderActionFlags *_Nonnull ioActionFlags,
                             const AudioTimeStamp *_Nonnull inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames,
                             AudioBufferList *_Nullable ioData) {
    (void)ioActionFlags;
    (void)inBusNumber;
    AEQRenderContext *c = (AEQRenderContext *)inRefCon;
    if (!ioData) return noErr;

#if defined(__x86_64__) || defined(__i386__)
    // Flush-to-zero / denormals-are-zero: evita rallentamenti con code di riverbero molto deboli.
    _mm_setcsr(_mm_getcsr() | 0x8040);
#endif

    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        if (ioData->mBuffers[i].mData) memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
    }
    if (!c || !c->unit || inNumberFrames > c->maxFrames) return noErr;

    for (UInt32 i = 0; i < c->inputChannels; i++) {
        c->inputList->mBuffers[i].mDataByteSize = inNumberFrames * sizeof(float);
        c->inputList->mBuffers[i].mData = c->inputBuffers[i];
    }
    AudioUnitRenderActionFlags flags = 0;
    OSStatus err = AudioUnitRender(c->unit, &flags, inTimeStamp, 1, inNumberFrames, c->inputList);
    if (err != noErr) {
        atomic_fetch_add(&c->renderErrors, 1);
        return noErr; // silenzio, nessun glitch rumoroso
    }

    const float *srcL = c->inputBuffers[c->loopLeft < c->inputChannels ? c->loopLeft : 0];
    const float *srcR = c->inputBuffers[c->loopRight < c->inputChannels ? c->loopRight : 0];
    memcpy(c->workL, srcL, inNumberFrames * sizeof(float));
    memcpy(c->workR, srcR, inNumberFrames * sizeof(float));

    aeq_process(c->dsp, c->workL, c->workR, inNumberFrames);

    const UInt32 nOut = ioData->mNumberBuffers;
    if (c->outMono) {
        if (c->outLeft < nOut && ioData->mBuffers[c->outLeft].mData) {
            float *o = (float *)ioData->mBuffers[c->outLeft].mData;
            for (UInt32 i = 0; i < inNumberFrames; i++) o[i] = 0.5f * (c->workL[i] + c->workR[i]);
        }
    } else {
        if (c->outLeft < nOut && ioData->mBuffers[c->outLeft].mData)
            memcpy(ioData->mBuffers[c->outLeft].mData, c->workL, inNumberFrames * sizeof(float));
        if (c->outRight < nOut && ioData->mBuffers[c->outRight].mData)
            memcpy(ioData->mBuffers[c->outRight].mData, c->workR, inNumberFrames * sizeof(float));
    }
    return noErr;
}

#endif
