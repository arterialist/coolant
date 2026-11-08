#ifndef CSMC_H
#define CSMC_H
#include <stdint.h>
#include <IOKit/IOKitLib.h>

io_connect_t csmc_open(void);
void csmc_close(io_connect_t conn);
int csmc_info(io_connect_t conn, uint32_t key, uint32_t *size, uint32_t *type, uint8_t *attr);
int csmc_read(io_connect_t conn, uint32_t key, uint32_t size, uint8_t *out);
int csmc_write(io_connect_t conn, uint32_t key, uint32_t size, const uint8_t *in);
int csmc_key_at(io_connect_t conn, uint32_t index, uint32_t *key);

typedef struct {
    char name[64];
    double value;
} csmc_hid_temp;

/* Reads Apple Silicon HID temperature services. Returns the number written. */
int csmc_hid_temps(csmc_hid_temp *out, int capacity);
#endif
