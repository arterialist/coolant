#include "csmc.h"
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

/* Layout the AppleSMC user client expects. */
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } vers;
    struct { uint16_t version, length; uint32_t cpu, gpu, mem; } limit;
    struct { uint32_t size, type; uint8_t attr; } info;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param;
_Static_assert(sizeof(smc_param) == 80, "AppleSMC parameter block must be 80 bytes");

enum { SEL_YPC = 2, CMD_READ = 5, CMD_WRITE = 6, CMD_INDEX = 8, CMD_INFO = 9 };

static int call(io_connect_t conn, smc_param *in, smc_param *out) {
    size_t size = sizeof(*out);
    kern_return_t kr = IOConnectCallStructMethod(conn, SEL_YPC, in, sizeof(*in), out, &size);
    if (kr != KERN_SUCCESS) return (int)kr;
    return out->result;
}

io_connect_t csmc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? conn : 0;
}

void csmc_close(io_connect_t conn) { if (conn) IOServiceClose(conn); }

int csmc_info(io_connect_t conn, uint32_t key, uint32_t *size, uint32_t *type, uint8_t *attr) {
    smc_param in = {0}, out = {0};
    in.key = key; in.data8 = CMD_INFO;
    int r = call(conn, &in, &out);
    if (r) return r;
    *size = out.info.size; *type = out.info.type; *attr = out.info.attr;
    return 0;
}

int csmc_read(io_connect_t conn, uint32_t key, uint32_t size, uint8_t *dst) {
    if (size > 32) return -1;
    smc_param in = {0}, out = {0};
    in.key = key; in.info.size = size; in.data8 = CMD_READ;
    int r = call(conn, &in, &out);
    if (r) return r;
    memcpy(dst, out.bytes, size);
    return 0;
}

int csmc_write(io_connect_t conn, uint32_t key, uint32_t size, const uint8_t *src) {
    if (size > 32) return -1;
    smc_param in = {0}, out = {0};
    in.key = key; in.info.size = size; in.data8 = CMD_WRITE;
    memcpy(in.bytes, src, size);
    return call(conn, &in, &out);
}

int csmc_key_at(io_connect_t conn, uint32_t index, uint32_t *key) {
    smc_param in = {0}, out = {0};
    in.data8 = CMD_INDEX; in.data32 = index;
    int r = call(conn, &in, &out);
    if (r) return r;
    *key = out.key;
    return 0;
}

/* Private IOHIDEventSystem API, the only route to the named Apple Silicon sensors. */
typedef const void *HIDEvent;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern HIDEvent IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(HIDEvent, int32_t);

enum { HID_TEMP_EVENT = 15, HID_TEMP_FIELD = 15 << 16 };

int csmc_hid_temps(csmc_hid_temp *dst, int capacity) {
    static IOHIDEventSystemClientRef client;
    if (!client) {
        int page = 0xff00, usage = 5;
        CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *vals[] = { p, u };
        CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (client) IOHIDEventSystemClientSetMatching(client, match);
        CFRelease(match); CFRelease(p); CFRelease(u);
        if (!client) return 0;
    }
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0;
    int n = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count && n < capacity; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (!name) continue;
        HIDEvent ev = IOHIDServiceClientCopyEvent(svc, HID_TEMP_EVENT, 0, 0);
        if (ev && CFGetTypeID(name) == CFStringGetTypeID() &&
            CFStringGetCString(name, dst[n].name, sizeof(dst[n].name), kCFStringEncodingUTF8)) {
            dst[n].value = IOHIDEventGetFloatValue(ev, HID_TEMP_FIELD);
            n++;
        }
        if (ev) CFRelease(ev);
        CFRelease(name);
    }
    CFRelease(services);
    return n;
}
