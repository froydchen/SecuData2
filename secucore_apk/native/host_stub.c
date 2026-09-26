#include <stdint.h>

#if defined(_WIN32)
#define GDE_EXPORT __declspec(dllexport)
#else
#define GDE_EXPORT __attribute__((visibility("default")))
#endif

typedef uint8_t GDExtensionBool;
typedef void *GDExtensionClassLibraryPtr;

typedef enum {
    GDEXTENSION_INITIALIZATION_CORE = 0,
    GDEXTENSION_INITIALIZATION_SERVERS = 1,
    GDEXTENSION_INITIALIZATION_SCENE = 2,
    GDEXTENSION_INITIALIZATION_EDITOR = 3,
    GDEXTENSION_MAX_INITIALIZATION_LEVEL = 4
} GDExtensionInitializationLevel;

typedef void (*GDExtensionInitializeCallback)(void *, GDExtensionInitializationLevel);
typedef void (*GDExtensionDeinitializeCallback)(void *, GDExtensionInitializationLevel);
typedef void (*GDExtensionInterfaceFunctionPtr)(void);
typedef GDExtensionInterfaceFunctionPtr (*GDExtensionInterfaceGetProcAddress)(const char *);

typedef struct {
    GDExtensionInitializationLevel minimum_initialization_level;
    void *userdata;
    GDExtensionInitializeCallback initialize;
    GDExtensionDeinitializeCallback deinitialize;
} GDExtensionInitialization;

static void stub_initialize(void *userdata, GDExtensionInitializationLevel level) {
    (void)userdata;
    (void)level;
}

static void stub_deinitialize(void *userdata, GDExtensionInitializationLevel level) {
    (void)userdata;
    (void)level;
}

GDExtensionBool GDE_EXPORT secucore_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization
) {
    (void)get_proc_address;
    (void)library;

    if (!initialization) {
        return 0;
    }

    initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
    initialization->userdata = 0;
    initialization->initialize = stub_initialize;
    initialization->deinitialize = stub_deinitialize;
    return 1;
}
