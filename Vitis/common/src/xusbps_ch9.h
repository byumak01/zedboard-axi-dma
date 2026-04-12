/******************************************************************************
 *
 * Minimal USB chapter 9 helper declarations for the ZedBoard USB DMA bridge.
 *
 * SPDX-License-Identifier: MIT
 *
 ******************************************************************************/

#ifndef XUSBPS_CH9_H
#define XUSBPS_CH9_H

#ifdef __cplusplus
extern "C" {
#endif

#include "xstatus.h"
#include "xusbps.h"
#include "xusbps_hw.h"

#define XUSBPS_REQ_TYPE_MASK 0x60U

#define XUSBPS_CMD_STDREQ 0x00U
#define XUSBPS_CMD_CLASSREQ 0x20U
#define XUSBPS_CMD_VENDREQ 0x40U

#define XUSBPS_REQ_GET_STATUS 0x00U
#define XUSBPS_REQ_CLEAR_FEATURE 0x01U
#define XUSBPS_REQ_SET_FEATURE 0x03U
#define XUSBPS_REQ_SET_ADDRESS 0x05U
#define XUSBPS_REQ_GET_DESCRIPTOR 0x06U
#define XUSBPS_REQ_GET_CONFIGURATION 0x08U
#define XUSBPS_REQ_SET_CONFIGURATION 0x09U
#define XUSBPS_REQ_GET_INTERFACE 0x0AU
#define XUSBPS_REQ_SET_INTERFACE 0x0BU

#define XUSBPS_TYPE_DEVICE_DESC 0x01U
#define XUSBPS_TYPE_CONFIG_DESC 0x02U
#define XUSBPS_TYPE_STRING_DESC 0x03U
#define XUSBPS_TYPE_IF_CFG_DESC 0x04U
#define XUSBPS_TYPE_ENDPOINT_CFG_DESC 0x05U
#define XUSBPS_TYPE_DEVICE_QUALIFIER 0x06U

#define XUSBPS_STATUS_MASK 0x03U
#define XUSBPS_STATUS_DEVICE 0x00U
#define XUSBPS_STATUS_INTERFACE 0x01U
#define XUSBPS_STATUS_ENDPOINT 0x02U

#define XUSBPS_ENDPOINT_HALT 0x00U
#define XUSBPS_DEVICE_REMOTE_WAKEUP 0x01U
#define XUSBPS_TEST_MODE 0x02U

#define XUSBPS_REQ_REPLY_LEN 256U

#define ALIGNMENT_CACHELINE __attribute__((aligned(32)))
#define DCACHE_INVALIDATE_SIZE(a) (((a) % 32U) != 0U ? ((((a) / 32U) * 32U) + 32U) : (a))
#define be2le(val) (u32)(val)
#define be2les(x) (u16)(x)
#define htonl(val) ((((u32)(val) & 0x000000FFU) << 24) | \
		    (((u32)(val) & 0x0000FF00U) << 8) | \
		    (((u32)(val) & 0x00FF0000U) >> 8) | \
		    (((u32)(val) & 0xFF000000U) >> 24))
#define htons(x) (u16)((((u16)(x)) << 8) | (((u16)(x)) >> 8))

int XUsbPs_Ch9HandleSetupPacket(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData);

#ifdef __cplusplus
}
#endif

#endif
