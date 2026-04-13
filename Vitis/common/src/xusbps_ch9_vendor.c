/******************************************************************************
 *
 * Vendor-specific descriptors for the ZedBoard USB DMA bridge.
 *
 * SPDX-License-Identifier: MIT
 *
 ******************************************************************************/

#include <string.h>

#include "xusbps_ch9.h"

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u16 bcdUSB;
	u8 bDeviceClass;
	u8 bDeviceSubClass;
	u8 bDeviceProtocol;
	u8 bMaxPacketSize0;
	u16 idVendor;
	u16 idProduct;
	u16 bcdDevice;
	u8 iManufacturer;
	u8 iProduct;
	u8 iSerialNumber;
	u8 bNumConfigurations;
#ifdef __ICCARM__
} USB_STD_DEV_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_DEV_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u16 wTotalLength;
	u8 bNumInterfaces;
	u8 bConfigurationValue;
	u8 iConfiguration;
	u8 bmAttributes;
	u8 bMaxPower;
#ifdef __ICCARM__
} USB_STD_CFG_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_CFG_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u8 bInterfaceNumber;
	u8 bAlternateSetting;
	u8 bNumEndPoints;
	u8 bInterfaceClass;
	u8 bInterfaceSubClass;
	u8 bInterfaceProtocol;
	u8 iInterface;
#ifdef __ICCARM__
} USB_STD_IF_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_IF_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u8 bEndpointAddress;
	u8 bmAttributes;
	u16 wMaxPacketSize;
	u8 bInterval;
#ifdef __ICCARM__
} USB_STD_EP_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_EP_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u16 wLANGID[1];
#ifdef __ICCARM__
} USB_STD_STRING_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_STRING_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	USB_STD_CFG_DESC StdCfg;
	USB_STD_IF_DESC IfCfg;
	USB_STD_EP_DESC BulkOutEp;
	USB_STD_EP_DESC BulkInEp;
#ifdef __ICCARM__
} USB_CONFIG_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_CONFIG_DESC;
#endif

#define USB_ENDPOINT0_MAX_PACKET 64U
#define USB_BULK_ENDPOINT 1U
#define USB_BULK_MAX_PACKET 512U

u32 XUsbPs_Ch9SetupDevDescReply(u8 *BufPtr, u32 BufLen)
{
	USB_STD_DEV_DESC DeviceDesc = {
		sizeof(USB_STD_DEV_DESC),
		XUSBPS_TYPE_DEVICE_DESC,
		be2les(0x0200),
		0x00U,
		0x00U,
		0x00U,
		USB_ENDPOINT0_MAX_PACKET,
		be2les(0x0D7DU),
		be2les(0x0200U),
		be2les(0x0100U),
		0x01U,
		0x02U,
		0x03U,
		0x01U,
	};

	if ((BufPtr == NULL) || (BufLen < sizeof(DeviceDesc))) {
		return 0U;
	}

	memcpy(BufPtr, &DeviceDesc, sizeof(DeviceDesc));
	return sizeof(DeviceDesc);
}

u32 XUsbPs_Ch9SetupCfgDescReply(u8 *BufPtr, u32 BufLen)
{
	USB_CONFIG_DESC ConfigDesc = {
		{
			sizeof(USB_STD_CFG_DESC),
			XUSBPS_TYPE_CONFIG_DESC,
			be2les(sizeof(USB_CONFIG_DESC)),
			0x01U,
			0x01U,
			0x04U,
			0xC0U,
			0x00U,
		},
		{
			sizeof(USB_STD_IF_DESC),
			XUSBPS_TYPE_IF_CFG_DESC,
			0x00U,
			0x00U,
			0x02U,
			0xFFU,
			0x00U,
			0x00U,
			0x05U,
		},
		{
			sizeof(USB_STD_EP_DESC),
			XUSBPS_TYPE_ENDPOINT_CFG_DESC,
			USB_BULK_ENDPOINT,
			0x02U,
			be2les(USB_BULK_MAX_PACKET),
			0x00U,
		},
		{
			sizeof(USB_STD_EP_DESC),
			XUSBPS_TYPE_ENDPOINT_CFG_DESC,
			(u8)(0x80U | USB_BULK_ENDPOINT),
			0x02U,
			be2les(USB_BULK_MAX_PACKET),
			0x00U,
		},
	};

	if ((BufPtr == NULL) || (BufLen < sizeof(ConfigDesc))) {
		return 0U;
	}

	memcpy(BufPtr, &ConfigDesc, sizeof(ConfigDesc));
	return sizeof(ConfigDesc);
}

u32 XUsbPs_Ch9SetupStrDescReply(u8 *BufPtr, u32 BufLen, u8 Index)
{
	u32 DescLen;
	u32 StringLen;
	u32 Index32;
	const char *String;
	u8 TmpBuf[128];
	USB_STD_STRING_DESC *StringDesc;

	static const char *StringList[] = {
		"UNUSED",
		"AMD Xilinx Demo",
		"ZedBoard USB DMA NN Bridge",
		"00000001",
		"Neural Network Config",
		"Vendor Bulk NN Bridge",
	};

	if ((BufPtr == NULL) || (Index >= (sizeof(StringList) / sizeof(StringList[0])))) {
		return 0U;
	}

	StringDesc = (USB_STD_STRING_DESC *)TmpBuf;
	if (Index == 0U) {
		StringDesc->bLength = 4U;
		StringDesc->bDescriptorType = XUSBPS_TYPE_STRING_DESC;
		StringDesc->wLANGID[0] = be2les(0x0409U);
		DescLen = StringDesc->bLength;
	} else {
		String = StringList[Index];
		StringLen = strlen(String);
		StringDesc->bLength = (u8)(StringLen * 2U + 2U);
		StringDesc->bDescriptorType = XUSBPS_TYPE_STRING_DESC;
		for (Index32 = 0U; Index32 < StringLen; Index32++) {
			StringDesc->wLANGID[Index32] = be2les((u16)String[Index32]);
		}
		DescLen = StringDesc->bLength;
	}

	if (DescLen > BufLen) {
		return 0U;
	}

	memcpy(BufPtr, StringDesc, DescLen);
	return DescLen;
}

void XUsbPs_SetConfiguration(XUsbPs *InstancePtr, int ConfigIdx)
{
	Xil_AssertVoid(InstancePtr != NULL);

	if (ConfigIdx != 1) {
		return;
	}

	XUsbPs_EpEnable(InstancePtr, USB_BULK_ENDPOINT, XUSBPS_EP_DIRECTION_OUT);
	XUsbPs_EpEnable(InstancePtr, USB_BULK_ENDPOINT, XUSBPS_EP_DIRECTION_IN);

	XUsbPs_SetBits(InstancePtr, XUSBPS_EPCR1_OFFSET,
		       XUSBPS_EPCR_TXT_BULK_MASK |
		       XUSBPS_EPCR_RXT_BULK_MASK |
		       XUSBPS_EPCR_TXR_MASK |
		       XUSBPS_EPCR_RXR_MASK);

	XUsbPs_EpPrime(InstancePtr, USB_BULK_ENDPOINT, XUSBPS_EP_DIRECTION_OUT);
}

void XUsbPs_SetConfigurationApp(XUsbPs *InstancePtr,
				XUsbPs_SetupData *SetupData)
{
	(void)InstancePtr;
	(void)SetupData;
}

void XUsbPs_SetInterfaceHandler(XUsbPs *InstancePtr,
				XUsbPs_SetupData *SetupData)
{
	(void)InstancePtr;
	(void)SetupData;
}
