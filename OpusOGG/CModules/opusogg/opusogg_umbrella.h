//
//  opusogg_umbrella.h
//  Clang module "opusogg" — replaces a Swift bridging header so xcframework consumers never scan OpusOGG-Bridging-Header.h.
//

#ifndef OPUSOGG_UMBRELLA_H
#define OPUSOGG_UMBRELLA_H

#include "opus/opus.h"
#include "ogg/ogg.h"

int opusogg_encoder_set_bitrate(OpusEncoder *_Nonnull enc, opus_int32 bitrate);

#endif
