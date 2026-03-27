#include "opus/opus.h"

int opusogg_encoder_set_bitrate(OpusEncoder *enc, opus_int32 bitrate) {
  return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
}
