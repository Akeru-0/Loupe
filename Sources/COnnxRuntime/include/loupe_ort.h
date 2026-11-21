// Loupe's thin layer over ONNX Runtime's C API (headers vendored from ONNX Runtime 1.32, MIT; see
// ONNXRUNTIME-LICENSE.txt). The runtime itself isn't linked: it is loaded at run time from a Homebrew install, so the
// app builds and runs without it and only face recognition needs it.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct LoupeOrtModel LoupeOrtModel;

/// Loads ONNX Runtime from `dylib` and the model at `model_path` (one input, one output). NULL on failure, with the
/// reason in `error`.
LoupeOrtModel *loupe_ort_open(const char *dylib, const char *model_path, char *error, size_t error_size);

/// Runs the model on one float tensor shaped 1×channels×height×width; copies the output (exactly `output_count`
/// floats) to `output`. 0 on success.
int loupe_ort_run(LoupeOrtModel *model, const float *input, int64_t channels, int64_t height, int64_t width,
                  float *output, size_t output_count, char *error, size_t error_size);

void loupe_ort_close(LoupeOrtModel *model);
