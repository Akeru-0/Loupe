#include "loupe_ort.h"
#include "onnxruntime_c_api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct LoupeOrtModel {
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory;
    char *input_name;
    char *output_name;
};

/// Reports and releases a failed status; 1 if it failed.
static int failed(const OrtApi *api, OrtStatus *status, char *error, size_t size) {
    if (status == NULL) return 0;
    snprintf(error, size, "%s", api->GetErrorMessage(status));
    api->ReleaseStatus(status);
    return 1;
}

static char *copy_name(const OrtApi *api, OrtAllocator *allocator, char *name) {
    char *copy = strdup(name);
    OrtStatus *status = api->AllocatorFree(allocator, name);
    if (status) api->ReleaseStatus(status);
    return copy;
}

LoupeOrtModel *loupe_ort_open(const char *dylib, const char *model_path, char *error, size_t size) {
    void *library = dlopen(dylib, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        snprintf(error, size, "%s", dlerror());
        return NULL;
    }
    const OrtApiBase *(*get_base)(void) = (const OrtApiBase *(*)(void))dlsym(library, "OrtGetApiBase");
    if (get_base == NULL) {
        snprintf(error, size, "%s isn't ONNX Runtime", dylib);
        return NULL;
    }
    const OrtApi *api = get_base()->GetApi(ORT_API_VERSION);
    if (api == NULL) {
        snprintf(error, size, "ONNX Runtime %s is older than Loupe needs (API %d)", get_base()->GetVersionString(),
                 ORT_API_VERSION);
        return NULL;
    }
    LoupeOrtModel *model = calloc(1, sizeof *model);
    model->api = api;
    OrtSessionOptions *options = NULL;
    OrtAllocator *allocator = NULL;
    char *name = NULL;
    if (failed(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "loupe", &model->env), error, size)) goto fail;
    if (failed(api, api->CreateSessionOptions(&options), error, size)) goto fail;
    OrtStatus *threads = api->SetIntraOpNumThreads(options, 2);  // a background job: leave the rest of the Mac alone
    if (threads) api->ReleaseStatus(threads);
    OrtStatus *status = api->CreateSession(model->env, model_path, options, &model->session);
    api->ReleaseSessionOptions(options);
    if (failed(api, status, error, size)) goto fail;
    if (failed(api, api->GetAllocatorWithDefaultOptions(&allocator), error, size)) goto fail;
    if (failed(api, api->SessionGetInputName(model->session, 0, allocator, &name), error, size)) goto fail;
    model->input_name = copy_name(api, allocator, name);
    if (failed(api, api->SessionGetOutputName(model->session, 0, allocator, &name), error, size)) goto fail;
    model->output_name = copy_name(api, allocator, name);
    if (failed(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &model->memory), error, size))
        goto fail;
    return model;
fail:
    loupe_ort_close(model);
    return NULL;
}

int loupe_ort_run(LoupeOrtModel *model, const float *input, int64_t channels, int64_t height, int64_t width,
                  float *output, size_t output_count, char *error, size_t size) {
    const OrtApi *api = model->api;
    int64_t shape[4] = {1, channels, height, width};
    size_t count = (size_t)(channels * height * width);
    OrtValue *in = NULL, *out = NULL;
    if (failed(api,
               api->CreateTensorWithDataAsOrtValue(model->memory, (void *)input, count * sizeof(float), shape, 4,
                                                   ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in),
               error, size))
        return 1;
    const char *input_names[1] = {model->input_name};
    const char *output_names[1] = {model->output_name};
    OrtStatus *status =
        api->Run(model->session, NULL, input_names, (const OrtValue *const *)&in, 1, output_names, 1, &out);
    api->ReleaseValue(in);
    if (failed(api, status, error, size)) return 1;
    OrtTensorTypeAndShapeInfo *info = NULL;
    size_t total = 0;
    float *data = NULL;
    int result = 1;
    if (failed(api, api->GetTensorTypeAndShape(out, &info), error, size)) goto done;
    status = api->GetTensorShapeElementCount(info, &total);
    api->ReleaseTensorTypeAndShapeInfo(info);
    if (failed(api, status, error, size)) goto done;
    if (total != output_count) {
        snprintf(error, size, "the model returned %zu values, not %zu", total, output_count);
        goto done;
    }
    if (failed(api, api->GetTensorMutableData(out, (void **)&data), error, size)) goto done;
    memcpy(output, data, output_count * sizeof(float));
    result = 0;
done:
    api->ReleaseValue(out);
    return result;
}

void loupe_ort_close(LoupeOrtModel *model) {
    if (model == NULL) return;
    const OrtApi *api = model->api;
    if (model->memory) api->ReleaseMemoryInfo(model->memory);
    if (model->session) api->ReleaseSession(model->session);
    if (model->env) api->ReleaseEnv(model->env);
    free(model->input_name);
    free(model->output_name);
    free(model);
}
