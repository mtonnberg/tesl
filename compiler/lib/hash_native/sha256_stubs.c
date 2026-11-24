/* Native SHA-256 for the compiler executable (Migration_hash installs it).
   Uses the x86 SHA extensions when the CPU has them and portable C otherwise;
   both produce the same digest as the OCaml implementation (tests pin this). */
#include <stdint.h>
#include <string.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>

static const uint32_t K[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};

#define ROR(x,n) (((x) >> (n)) | ((x) << (32 - (n))))

static void blocks_portable(uint32_t s[8], const unsigned char *p, size_t n) {
  uint32_t w[64];
  while (n--) {
    for (int i = 0; i < 16; i++)
      w[i] = ((uint32_t)p[4*i] << 24) | ((uint32_t)p[4*i+1] << 16) | ((uint32_t)p[4*i+2] << 8) | p[4*i+3];
    for (int i = 16; i < 64; i++) {
      uint32_t s0 = ROR(w[i-15],7) ^ ROR(w[i-15],18) ^ (w[i-15] >> 3);
      uint32_t s1 = ROR(w[i-2],17) ^ ROR(w[i-2],19) ^ (w[i-2] >> 10);
      w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint32_t a=s[0],b=s[1],c=s[2],d=s[3],e=s[4],f=s[5],g=s[6],h=s[7];
    for (int i = 0; i < 64; i++) {
      uint32_t t1 = h + (ROR(e,6) ^ ROR(e,11) ^ ROR(e,25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
      uint32_t t2 = (ROR(a,2) ^ ROR(a,13) ^ ROR(a,22)) + ((a & b) ^ (a & c) ^ (b & c));
      h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    s[0]+=a; s[1]+=b; s[2]+=c; s[3]+=d; s[4]+=e; s[5]+=f; s[6]+=g; s[7]+=h;
    p += 64;
  }
}

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#include <immintrin.h>
#include <cpuid.h>
__attribute__((target("sha,sse4.1")))
static void blocks_shani(uint32_t s[8], const unsigned char *p, size_t n) {
  const __m128i MASK = _mm_set_epi64x(0x0c0d0e0f08090a0bULL, 0x0405060700010203ULL);
  __m128i TMP = _mm_loadu_si128((const __m128i*)&s[0]);
  __m128i STATE1 = _mm_loadu_si128((const __m128i*)&s[4]);
  TMP = _mm_shuffle_epi32(TMP, 0xB1);          /* CDAB */
  STATE1 = _mm_shuffle_epi32(STATE1, 0x1B);    /* EFGH */
  __m128i STATE0 = _mm_alignr_epi8(TMP, STATE1, 8);    /* ABEF */
  STATE1 = _mm_blend_epi16(STATE1, TMP, 0xF0);         /* CDGH */
  while (n--) {
    __m128i ABEF_SAVE = STATE0, CDGH_SAVE = STATE1, MSG, MSG0, MSG1, MSG2, MSG3;
    MSG0 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(p+0)), MASK);
    MSG1 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(p+16)), MASK);
    MSG2 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(p+32)), MASK);
    MSG3 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(p+48)), MASK);
#define K4(i) _mm_loadu_si128((const __m128i*)&K[i])
#define ROUNDS(m, i) \
    MSG = _mm_add_epi32(m, K4(i)); \
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG); \
    MSG = _mm_shuffle_epi32(MSG, 0x0E); \
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    /* rounds 0-15 */
    ROUNDS(MSG0, 0);
    ROUNDS(MSG1, 4);  MSG0 = _mm_sha256msg1_epu32(MSG0, MSG1);
    ROUNDS(MSG2, 8);  MSG1 = _mm_sha256msg1_epu32(MSG1, MSG2);
    ROUNDS(MSG3, 12);
    for (int i = 16; i < 64; i += 16) {
      /* each step: finish schedule of next message, then rounds */
      TMP = _mm_alignr_epi8(MSG3, MSG2, 4); MSG0 = _mm_add_epi32(MSG0, TMP); MSG0 = _mm_sha256msg2_epu32(MSG0, MSG3);
      MSG2 = _mm_sha256msg1_epu32(MSG2, MSG3);
      ROUNDS(MSG0, i);
      TMP = _mm_alignr_epi8(MSG0, MSG3, 4); MSG1 = _mm_add_epi32(MSG1, TMP); MSG1 = _mm_sha256msg2_epu32(MSG1, MSG0);
      MSG3 = _mm_sha256msg1_epu32(MSG3, MSG0);
      ROUNDS(MSG1, i+4);
      TMP = _mm_alignr_epi8(MSG1, MSG0, 4); MSG2 = _mm_add_epi32(MSG2, TMP); MSG2 = _mm_sha256msg2_epu32(MSG2, MSG1);
      MSG0 = _mm_sha256msg1_epu32(MSG0, MSG1);
      ROUNDS(MSG2, i+8);
      TMP = _mm_alignr_epi8(MSG2, MSG1, 4); MSG3 = _mm_add_epi32(MSG3, TMP); MSG3 = _mm_sha256msg2_epu32(MSG3, MSG2);
      MSG1 = _mm_sha256msg1_epu32(MSG1, MSG2);
      ROUNDS(MSG3, i+12);
    }
#undef ROUNDS
#undef K4
    STATE0 = _mm_add_epi32(STATE0, ABEF_SAVE);
    STATE1 = _mm_add_epi32(STATE1, CDGH_SAVE);
    p += 64;
  }
  TMP = _mm_shuffle_epi32(STATE0, 0x1B);       /* FEBA */
  STATE1 = _mm_shuffle_epi32(STATE1, 0xB1);    /* DCHG */
  STATE0 = _mm_blend_epi16(TMP, STATE1, 0xF0); /* DCBA */
  STATE1 = _mm_alignr_epi8(STATE1, TMP, 8);    /* ABEF */
  _mm_storeu_si128((__m128i*)&s[0], STATE0);
  _mm_storeu_si128((__m128i*)&s[4], STATE1);
}
static int have_shani(void) {
  unsigned a, b, c, d;
  if (!__get_cpuid_max(0, 0) || __get_cpuid_max(0, 0) < 7) return 0;
  __cpuid_count(7, 0, a, b, c, d);
  int sha = (b >> 29) & 1;
  __cpuid(1, a, b, c, d);
  int sse41 = (c >> 19) & 1, ssse3 = (c >> 9) & 1;
  return sha && sse41 && ssse3;
}
#else
static int have_shani(void) { return 0; }
#endif

static int mode = -1;
static void blocks(uint32_t s[8], const unsigned char *p, size_t n) {
  if (mode < 0) mode = have_shani();
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
  if (mode == 1) { blocks_shani(s, p, n); return; }
#endif
  blocks_portable(s, p, n);
}

/* Lowercase hexadecimal SHA-256 of an OCaml string. [force_portable] selects
   the portable C rounds (tests compare both paths). */
CAMLprim value tesl_sha256_hex(value v_source, value v_portable) {
  CAMLparam2(v_source, v_portable);
  CAMLlocal1(result);
  size_t len = caml_string_length(v_source);
  uint32_t s[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  size_t full = len / 64;
  int portable = Bool_val(v_portable);
  /* The OCaml string does not move: no allocation happens until the result. */
  const unsigned char *p = (const unsigned char *)String_val(v_source);
  if (portable) blocks_portable(s, p, full); else blocks(s, p, full);
  unsigned char tail[128];
  size_t rest = len - full * 64;
  memcpy(tail, p + full * 64, rest);
  tail[rest] = 0x80;
  size_t tl = rest < 56 ? 64 : 128;
  memset(tail + rest + 1, 0, tl - rest - 1);
  uint64_t bits = (uint64_t)len * 8;
  for (int i = 0; i < 8; i++) tail[tl - 1 - i] = (unsigned char)(bits >> (8 * i));
  if (portable) blocks_portable(s, tail, tl / 64); else blocks(s, tail, tl / 64);
  static const char digits[] = "0123456789abcdef";
  result = caml_alloc_string(64);
  char *out = (char *)Bytes_val(result);
  for (int i = 0; i < 8; i++)
    for (int j = 0; j < 8; j++) out[i*8 + j] = digits[(s[i] >> (28 - 4*j)) & 15];
  CAMLreturn(result);
}
