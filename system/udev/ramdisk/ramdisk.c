// Copyright 2017 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <ddk/device.h>
#include <ddk/driver.h>
#include <ddk/binding.h>
#include <ddk/protocol/block.h>
#include <ddk/protocol/ramdisk.h>
#include <sync/completion.h>

#include <magenta/process.h>
#include <magenta/syscalls.h>
#include <magenta/types.h>
#include <magenta/listnode.h>
#include <sys/param.h>
#include <assert.h>
#include <inttypes.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <threads.h>

mx_driver_t _driver_ramdisk;
static mx_device_t* ramdisk_ctl_dev;

typedef struct ramdisk_device {
    mx_device_t device;
    uint64_t blk_size;
    uint64_t blk_count;
    mx_handle_t vmo;
    uintptr_t mapped_addr;
    block_callbacks_t* cb;
    char name[NAME_MAX];
} ramdisk_device_t;

typedef struct ramctl_instance {
    mx_device_t device;
} ramctl_instance_t;

#define get_ramdisk(dev) containerof(dev, ramdisk_device_t, device)
#define get_ramctl_instance(dev) containerof(dev, ramctl_instance_t, device)

static uint64_t sizebytes(ramdisk_device_t* rdev) {
    return rdev->blk_size * rdev->blk_count;
}

static mx_status_t constrain_args(ramdisk_device_t* ramdev,
                                  mx_off_t* offset, mx_off_t* length) {
    // Offset must be aligned
    if (*offset % ramdev->blk_size != 0) {
        return ERR_INVALID_ARGS;
    }

    // Constrain to device capacity
    *length = MIN(*length, sizebytes(ramdev) - *offset);

    // Length must be aligned
    if (*length % ramdev->blk_size != 0) {
        return ERR_INVALID_ARGS;
    }

    return NO_ERROR;
}

static void ramdisk_fifo_set_callbacks(mx_device_t* dev, block_callbacks_t* cb) {
    ramdisk_device_t* rdev = get_ramdisk(dev);
    rdev->cb = cb;
}

static void ramdisk_fifo_read(mx_device_t* dev, mx_handle_t vmo, uint64_t length,
                              uint64_t vmo_offset, uint64_t dev_offset, void* cookie) {
    ramdisk_device_t* rdev = get_ramdisk(dev);
    mx_off_t len = length;
    mx_status_t status = constrain_args(rdev, &dev_offset, &len);
    if (status != NO_ERROR) {
        rdev->cb->complete(cookie, status);
        return;
    }

    size_t actual;
    // Reading from disk --> Write to file VMO
    status = mx_vmo_write(vmo, (void*)rdev->mapped_addr + dev_offset, vmo_offset, len, &actual);
    rdev->cb->complete(cookie, status);
}

static void ramdisk_fifo_write(mx_device_t* dev, mx_handle_t vmo, uint64_t length,
                               uint64_t vmo_offset, uint64_t dev_offset, void* cookie) {
    ramdisk_device_t* rdev = get_ramdisk(dev);
    mx_off_t len = length;
    mx_status_t status = constrain_args(rdev, &dev_offset, &len);
    if (status != NO_ERROR) {
        rdev->cb->complete(cookie, status);
        return;
    }

    size_t actual = 0;
    // Writing to disk --> Read from file VMO
    status = mx_vmo_read(vmo, (void*)rdev->mapped_addr + dev_offset, vmo_offset, len, &actual);
    rdev->cb->complete(cookie, status);
}

static block_ops_t ramdisk_block_ops = {
    .set_callbacks = ramdisk_fifo_set_callbacks,
    .read = ramdisk_fifo_read,
    .write = ramdisk_fifo_write,
};

// implement device protocol:

static ssize_t ramdisk_ioctl(mx_device_t* dev, uint32_t op, const void* cmd,
                             size_t cmdlen, void* reply, size_t max) {
    ramdisk_device_t* ramdev = get_ramdisk(dev);

    switch (op) {
    case IOCTL_RAMDISK_UNLINK: {
        device_remove(dev);
        return NO_ERROR;
    }
    // Block Protocol
    case IOCTL_BLOCK_GET_NAME: {
        char* name = reply;
        memset(name, 0, max);
        strncpy(name, ramdev->name, max);
        return strnlen(name, max);
    }
    case IOCTL_BLOCK_GET_INFO: {
        block_info_t* info = reply;
        if (max < sizeof(*info))
            return ERR_BUFFER_TOO_SMALL;
        memset(info, 0, sizeof(*info));
        info->block_size = ramdev->blk_size;
        info->block_count = sizebytes(ramdev) / ramdev->blk_size;
        return sizeof(*info);
    }
    case IOCTL_BLOCK_RR_PART: {
        return device_rebind(dev);
    }
    case IOCTL_DEVICE_SYNC: {
        // Wow, we sync so quickly!
        return NO_ERROR;
    }
    default:
        return ERR_NOT_SUPPORTED;
    }
}

static void ramdisk_iotxn_queue(mx_device_t* dev, iotxn_t* txn) {
    ramdisk_device_t* ramdev = get_ramdisk(dev);

    mx_status_t status = constrain_args(ramdev, &txn->offset, &txn->length);
    if (status != NO_ERROR) {
        iotxn_complete(txn, status, 0);
        return;
    }

    switch (txn->opcode) {
        case IOTXN_OP_READ: {
            iotxn_copyto(txn, (void*) ramdev->mapped_addr + txn->offset, txn->length, 0);
            iotxn_complete(txn, NO_ERROR, txn->length);
            return;
        }
        case IOTXN_OP_WRITE: {
            iotxn_copyfrom(txn, (void*) ramdev->mapped_addr + txn->offset, txn->length, 0);
            iotxn_complete(txn, NO_ERROR, txn->length);
            return;
        }
        default: {
            iotxn_complete(txn, ERR_INVALID_ARGS, 0);
            return;
        }
    }
}

static mx_off_t ramdisk_getsize(mx_device_t* dev) {
    return sizebytes(get_ramdisk(dev));
}

static void ramdisk_unbind(mx_device_t* dev) {
    device_remove(dev);
}

static mx_status_t ramdisk_release(mx_device_t* dev) {
    ramdisk_device_t* ramdev = get_ramdisk(dev);
    if (ramdev->vmo != MX_HANDLE_INVALID) {
        mx_vmar_unmap(mx_vmar_root_self(), ramdev->mapped_addr, sizebytes(ramdev));
        mx_handle_close(ramdev->vmo);
    }
    free(ramdev);
    return NO_ERROR;
}

static mx_protocol_device_t ramdisk_instance_proto = {
    .ioctl = ramdisk_ioctl,
    .iotxn_queue = ramdisk_iotxn_queue,
    .get_size = ramdisk_getsize,
    .unbind = ramdisk_unbind,
    .release = ramdisk_release,
};

// implement device protocol:

static ssize_t ramctl_ioctl(mx_device_t* dev, uint32_t op, const void* cmd,
                            size_t cmdlen, void* reply, size_t max) {
    switch (op) {
    case IOCTL_RAMDISK_CONFIG: {
        if (cmdlen != sizeof(ramdisk_ioctl_config_t)) {
            return ERR_INVALID_ARGS;
        }
        ramdisk_ioctl_config_t* config = (ramdisk_ioctl_config_t*)cmd;
        config->name[NAME_MAX - 1] = '\0';
        if ((strlen(config->name) == 0) || (strchr(config->name, '/') != NULL)) {
            return ERR_INVALID_ARGS;
        }

        ramdisk_device_t* ramdev = calloc(1, sizeof(ramdisk_device_t));
        if (!ramdev) {
            return ERR_NO_MEMORY;
        }
        ramdev->blk_size = config->blk_size;
        ramdev->blk_count = config->blk_count;
        strcpy(ramdev->name, config->name);
        mx_status_t status;
        if ((status = mx_vmo_create(sizebytes(ramdev), 0, &ramdev->vmo)) != NO_ERROR) {
            free(ramdev);
            return status;
        }
        if ((status = mx_vmar_map(mx_vmar_root_self(), 0, ramdev->vmo, 0, sizebytes(ramdev),
                                  MX_VM_FLAG_PERM_READ | MX_VM_FLAG_PERM_WRITE,
                                  &ramdev->mapped_addr)) != NO_ERROR) {
            mx_handle_close(ramdev->vmo);
            free(ramdev);
            return status;
        }

        device_init(&ramdev->device, &_driver_ramdisk, config->name, &ramdisk_instance_proto);
        ramdev->device.protocol_id = MX_PROTOCOL_BLOCK_CORE;
        ramdev->device.protocol_ops = &ramdisk_block_ops;
        if ((status = device_add(&ramdev->device, ramdisk_ctl_dev)) != NO_ERROR) {
            mx_vmar_unmap(mx_vmar_root_self(), ramdev->mapped_addr, sizebytes(ramdev));
            mx_handle_close(ramdev->vmo);
            free(ramdev);
            return status;
        }
        return NO_ERROR;
    }
    default:
        return ERR_NOT_SUPPORTED;
    }
}

static void ramctl_unbind(mx_device_t* dev) {
    device_remove(dev);
}

static mx_status_t ramctl_release(mx_device_t* dev) {
    ramctl_instance_t* device = get_ramctl_instance(dev);
    free(device);
    return NO_ERROR;
}

static mx_protocol_device_t ramctl_instance_proto = {
    .ioctl = ramctl_ioctl,
    .unbind = ramctl_unbind,
    .release = ramctl_release,
};

static mx_status_t ramctl_open(mx_device_t* dev, mx_device_t** dev_out, uint32_t flags) {
    ramctl_instance_t* device = calloc(1, sizeof(ramctl_instance_t));
    if (!device) {
        return ERR_NO_MEMORY;
    }
    device_init(&device->device, &_driver_ramdisk, "ramctl-instance", &ramctl_instance_proto);
    mx_status_t status;
    if ((status = device_add_instance(&device->device, dev)) != NO_ERROR) {
        free(device);
        return status;
    }
    *dev_out = &device->device;
    return NO_ERROR;
}

static mx_protocol_device_t ramdisk_ctl_proto = {
    .open = ramctl_open,
};

static mx_status_t ramdisk_driver_bind(mx_driver_t* driver, mx_device_t* parent, void** cookie) {
    if (device_create(&ramdisk_ctl_dev, driver, "ramctl", &ramdisk_ctl_proto) == NO_ERROR) {
        mx_status_t status;
        if ((status = device_add(ramdisk_ctl_dev, parent)) < 0) {
            free(ramdisk_ctl_dev);
            return status;
        }
    }
    return NO_ERROR;
}

mx_driver_t _driver_ramdisk = {
    .ops = {
        .bind = ramdisk_driver_bind,
    },
};

MAGENTA_DRIVER_BEGIN(_driver_ramdisk, "ramdisk", "magenta", "0.1", 1)
    BI_MATCH_IF(EQ, BIND_PROTOCOL, MX_PROTOCOL_MISC_PARENT),
MAGENTA_DRIVER_END(_driver_ramdisk)
