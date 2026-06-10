/*
 * libultrahdr/mayhem/harnesses/roundtrip_test.cpp
 *
 * Self-contained known-answer round-trip test for libultrahdr's public C API.
 *
 * It synthesizes a deterministic 1280x720 10-bit P010 HDR image in memory, encodes it to an
 * UltraHDR (JPEG_R) stream via uhdr_encode(), then decodes that stream back through
 * uhdr_decode() and ASSERTS the real codec produced:
 *   - encode succeeded and emitted a non-trivial JPEG stream (SOI marker 0xFF 0xD8),
 *   - the stream is recognized as an UltraHDR image (is_uhdr_image),
 *   - the decoded base-image dimensions equal the known 1280x720 input,
 *   - a gain map of non-zero dimensions is present (the defining UltraHDR feature),
 *   - the decoded RGBA output buffer is the expected width/height.
 *
 * No bundled data file is required, so the test is hermetic. Built with NORMAL flags (no
 * sanitizers / no libFuzzer) by mayhem/build.sh; mayhem/test.sh only RUNS it. A no-op / exit(0) /
 * "always succeed without encoding" patch cannot produce the correct dimensions or a valid gain
 * map, so it fails this oracle.
 */
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "ultrahdr_api.h"

static constexpr unsigned int kW = 1280;
static constexpr unsigned int kH = 720;

#define CHECK(cond, msg)                            \
  do {                                              \
    if (!(cond)) {                                  \
      fprintf(stderr, "FAIL: %s\n", (msg));         \
      return 1;                                     \
    }                                               \
  } while (0)

#define CHECK_OK(call, msg)                                                   \
  do {                                                                        \
    uhdr_error_info_t s_ = (call);                                            \
    if (s_.error_code != UHDR_CODEC_OK) {                                     \
      fprintf(stderr, "FAIL: %s (code %d: %s)\n", (msg), (int)s_.error_code,  \
              s_.has_detail ? s_.detail : "");                                \
      return 1;                                                               \
    }                                                                         \
  } while (0)

int main() {
  // ── Build a synthetic P010 HDR image (10-bit 4:2:0 semiplanar, 16 bits/sample). ──
  // Luma plane: kW*kH uint16; interleaved CbCr plane: (kW/2)*(kH/2) pairs => kW*(kH/2) uint16.
  std::vector<uint16_t> luma(kW * kH);
  std::vector<uint16_t> chroma(kW * (kH / 2));  // interleaved U/V, half res both axes
  for (unsigned int y = 0; y < kH; ++y) {
    for (unsigned int x = 0; x < kW; ++x) {
      // a smooth 10-bit gradient (values stored in the 10 MSBs)
      uint16_t v = (uint16_t)(((x + y) & 0x3FF) << 6);
      luma[y * kW + x] = v;
    }
  }
  for (size_t i = 0; i < chroma.size(); ++i) chroma[i] = (uint16_t)(512 << 6);  // neutral chroma

  uhdr_raw_image_t hdr{};
  hdr.fmt = UHDR_IMG_FMT_24bppYCbCrP010;
  hdr.cg = UHDR_CG_BT_2100;
  hdr.ct = UHDR_CT_HLG;
  hdr.range = UHDR_CR_FULL_RANGE;
  hdr.w = kW;
  hdr.h = kH;
  hdr.planes[UHDR_PLANE_Y] = luma.data();
  hdr.planes[UHDR_PLANE_UV] = chroma.data();
  hdr.planes[UHDR_PLANE_V] = nullptr;
  hdr.stride[UHDR_PLANE_Y] = kW;
  hdr.stride[UHDR_PLANE_UV] = kW;
  hdr.stride[UHDR_PLANE_V] = 0;

  // ── Encode HDR -> UltraHDR (JPEG_R). ──
  uhdr_codec_private_t* enc = uhdr_create_encoder();
  CHECK(enc != nullptr, "uhdr_create_encoder returned null");
  CHECK_OK(uhdr_enc_set_raw_image(enc, &hdr, UHDR_HDR_IMG), "uhdr_enc_set_raw_image");
  CHECK_OK(uhdr_enc_set_quality(enc, 95, UHDR_BASE_IMG), "uhdr_enc_set_quality(base)");
  CHECK_OK(uhdr_enc_set_quality(enc, 95, UHDR_GAIN_MAP_IMG), "uhdr_enc_set_quality(gainmap)");
  CHECK_OK(uhdr_encode(enc), "uhdr_encode");

  uhdr_compressed_image_t* stream = uhdr_get_encoded_stream(enc);
  CHECK(stream != nullptr && stream->data != nullptr, "uhdr_get_encoded_stream null");
  CHECK(stream->data_sz > 1000, "encoded stream implausibly small");
  const uint8_t* sb = (const uint8_t*)stream->data;
  CHECK(sb[0] == 0xFF && sb[1] == 0xD8, "encoded stream is not a JPEG (no SOI marker)");

  // Copy the stream out before releasing the encoder.
  std::vector<uint8_t> jpegr(sb, sb + stream->data_sz);
  uhdr_release_encoder(enc);

  CHECK(is_uhdr_image(jpegr.data(), (int)jpegr.size()) != 0,
        "encoded stream not recognized as an UltraHDR image");

  // ── Decode the UltraHDR stream and verify dimensions + gain map. ──
  uhdr_compressed_image_t in{};
  in.data = jpegr.data();
  in.data_sz = jpegr.size();
  in.capacity = jpegr.size();
  in.cg = UHDR_CG_UNSPECIFIED;
  in.ct = UHDR_CT_UNSPECIFIED;
  in.range = UHDR_CR_UNSPECIFIED;

  uhdr_codec_private_t* dec = uhdr_create_decoder();
  CHECK(dec != nullptr, "uhdr_create_decoder returned null");
  CHECK_OK(uhdr_dec_set_image(dec, &in), "uhdr_dec_set_image");
  CHECK_OK(uhdr_dec_set_out_color_transfer(dec, UHDR_CT_SRGB), "uhdr_dec_set_out_color_transfer");
  CHECK_OK(uhdr_dec_set_out_img_format(dec, UHDR_IMG_FMT_32bppRGBA8888),
           "uhdr_dec_set_out_img_format");
  CHECK_OK(uhdr_dec_probe(dec), "uhdr_dec_probe");

  int w = uhdr_dec_get_image_width(dec);
  int h = uhdr_dec_get_image_height(dec);
  int gw = uhdr_dec_get_gainmap_width(dec);
  int gh = uhdr_dec_get_gainmap_height(dec);
  fprintf(stderr, "decoded base %dx%d, gainmap %dx%d\n", w, h, gw, gh);
  CHECK((unsigned)w == kW, "decoded base width != 1280");
  CHECK((unsigned)h == kH, "decoded base height != 720");
  CHECK(gw > 0 && gh > 0, "gain map absent or zero-sized (not an UltraHDR image)");

  CHECK_OK(uhdr_decode(dec), "uhdr_decode");
  uhdr_raw_image_t* out = uhdr_get_decoded_image(dec);
  CHECK(out != nullptr, "uhdr_get_decoded_image null");
  CHECK(out->w == kW && out->h == kH, "decoded RGBA image dimensions mismatch");
  CHECK(out->planes[UHDR_PLANE_PACKED] != nullptr, "decoded RGBA plane null");

  uhdr_release_decoder(dec);

  printf("roundtrip OK: base=%dx%d gainmap=%dx%d\n", w, h, gw, gh);
  return 0;
}
