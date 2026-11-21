#ifndef ARMONIA_RENDER_H
#define ARMONIA_RENDER_H

#if defined(__APPLE__)

#include <AudioToolbox/AudioToolbox.h>
#include "ArmoniaDSP.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AEQRenderContext AEQRenderContext;

/// inputChannels: canali di ingresso totali dell'aggregate device.
/// loopLeft/loopRight: indici (0-based) dei canali del loopback tra gli ingressi.
/// outLeft/outRight: indici (0-based) dei canali di uscita del dispositivo reale.
/// outMono: 1 se il dispositivo reale ha un solo canale (si invia L+R/2).
AEQRenderContext *_Nullable aeq_render_create(AEQEngine *_Nonnull dsp, UInt32 inputChannels, UInt32 loopLeft, UInt32 loopRight,
                                    UInt32 outLeft, UInt32 outRight, int outMono, UInt32 maxFrames);
void aeq_render_set_unit(AEQRenderContext *_Nullable context, AudioUnit _Nullable unit);
void aeq_render_destroy(AEQRenderContext *_Nullable context);
int aeq_render_error_count(AEQRenderContext *_Nullable context);

/// Firma identica ad AURenderCallback (incluse le annotazioni di nullabilità richieste da Swift).
OSStatus aeq_render_callback(void *_Nonnull inRefCon, AudioUnitRenderActionFlags *_Nonnull ioActionFlags,
                             const AudioTimeStamp *_Nonnull inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames,
                             AudioBufferList *_Nullable ioData);

#ifdef __cplusplus
}
#endif

#endif
#endif
