/******************************************************************************
 *
 * Minimal USB chapter 9 handler for the ZedBoard USB DMA bridge.
 *
 * SPDX-License-Identifier: MIT
 *
 ******************************************************************************/

#include "xusbps_ch9.h"

#include "xil_cache.h"

extern u32 XUsbPs_Ch9SetupDevDescReply(u8 *BufPtr, u32 BufLen);
extern u32 XUsbPs_Ch9SetupCfgDescReply(u8 *BufPtr, u32 BufLen);
extern u32 XUsbPs_Ch9SetupStrDescReply(u8 *BufPtr, u32 BufLen, u8 Index);
extern void XUsbPs_SetConfiguration(XUsbPs *InstancePtr, int ConfigIdx);
extern void XUsbPs_SetConfigurationApp(XUsbPs *InstancePtr,
				       XUsbPs_SetupData *SetupData);
extern void XUsbPs_SetInterfaceHandler(XUsbPs *InstancePtr,
				       XUsbPs_SetupData *SetupData);

static u8 CurrentConfig;

static void StallEp0(XUsbPs *InstancePtr)
{
	XUsbPs_EpStall(InstancePtr, 0U, XUSBPS_EP_DIRECTION_IN |
				    XUSBPS_EP_DIRECTION_OUT);
}

static int SendEp0Reply(XUsbPs *InstancePtr, const u8 *BufferPtr,
			u32 BufferLen, u32 RequestedLen)
{
	u32 TransferLen;

	TransferLen = BufferLen;
	if (TransferLen > RequestedLen) {
		TransferLen = RequestedLen;
	}

	return XUsbPs_EpBufferSend(InstancePtr, 0U, BufferPtr, TransferLen);
}

static void HandleDescriptorRequest(XUsbPs *InstancePtr,
				      XUsbPs_SetupData *SetupData)
{
	int Status;
	u8 DescriptorType;

#ifdef __ICCARM__
#pragma data_alignment = 32
	static u8 Reply[XUSBPS_REQ_REPLY_LEN];
	static u8 DeviceQualifier[10];
#else
	static u8 Reply[XUSBPS_REQ_REPLY_LEN] ALIGNMENT_CACHELINE;
	static u8 DeviceQualifier[10] ALIGNMENT_CACHELINE;
#endif
	u32 ReplyLen;

	DescriptorType = (u8)((SetupData->wValue >> 8) & 0xFFU);

	switch (DescriptorType) {
	case XUSBPS_TYPE_DEVICE_DESC:
		ReplyLen = XUsbPs_Ch9SetupDevDescReply(Reply, sizeof(Reply));
		break;

	case XUSBPS_TYPE_CONFIG_DESC:
		ReplyLen = XUsbPs_Ch9SetupCfgDescReply(Reply, sizeof(Reply));
		break;

	case XUSBPS_TYPE_STRING_DESC:
		ReplyLen = XUsbPs_Ch9SetupStrDescReply(Reply, sizeof(Reply),
						      (u8)(SetupData->wValue & 0xFFU));
		break;

	case XUSBPS_TYPE_DEVICE_QUALIFIER:
		DeviceQualifier[0] = 10U;
		DeviceQualifier[1] = XUSBPS_TYPE_DEVICE_QUALIFIER;
		DeviceQualifier[2] = 0x00U;
		DeviceQualifier[3] = 0x02U;
		DeviceQualifier[4] = 0x00U;
		DeviceQualifier[5] = 0x00U;
		DeviceQualifier[6] = 0x00U;
		DeviceQualifier[7] = 64U;
		DeviceQualifier[8] = 0x01U;
		DeviceQualifier[9] = 0x00U;
		ReplyLen = sizeof(DeviceQualifier);
		Xil_DCacheFlushRange((UINTPTR)DeviceQualifier, ReplyLen);
		Status = SendEp0Reply(InstancePtr, DeviceQualifier, ReplyLen,
				      SetupData->wLength);
		if (Status != XST_SUCCESS) {
			StallEp0(InstancePtr);
		}
		return;

	default:
		StallEp0(InstancePtr);
		return;
	}

	if (ReplyLen == 0U) {
		StallEp0(InstancePtr);
		return;
	}

	Xil_DCacheFlushRange((UINTPTR)Reply, ReplyLen);
	Status = SendEp0Reply(InstancePtr, Reply, ReplyLen, SetupData->wLength);
	if (Status != XST_SUCCESS) {
		StallEp0(InstancePtr);
	}
}

static void HandleGetStatusRequest(XUsbPs *InstancePtr,
				   XUsbPs_SetupData *SetupData)
{
#ifdef __ICCARM__
#pragma data_alignment = 32
	static u8 Reply[2];
#else
	static u8 Reply[2] ALIGNMENT_CACHELINE;
#endif
	u32 EndpointStatus;
	u8 Endpoint;

	Reply[0] = 0U;
	Reply[1] = 0U;

	switch (SetupData->bmRequestType & XUSBPS_STATUS_MASK) {
	case XUSBPS_STATUS_DEVICE:
		Reply[0] = 0x01U;
		break;

	case XUSBPS_STATUS_INTERFACE:
		break;

	case XUSBPS_STATUS_ENDPOINT:
		Endpoint = (u8)(SetupData->wIndex & 0x0FU);
		EndpointStatus = XUsbPs_ReadReg(InstancePtr->Config.BaseAddress,
						XUSBPS_EPCRn_OFFSET(Endpoint));
		if ((SetupData->wIndex & 0x80U) != 0U) {
			if ((EndpointStatus & XUSBPS_EPCR_TXS_MASK) != 0U) {
				Reply[0] = 0x01U;
			}
		} else if ((EndpointStatus & XUSBPS_EPCR_RXS_MASK) != 0U) {
			Reply[0] = 0x01U;
		}
		break;

	default:
		StallEp0(InstancePtr);
		return;
	}

	Xil_DCacheFlushRange((UINTPTR)Reply, sizeof(Reply));
	if (XUsbPs_EpBufferSend(InstancePtr, 0U, Reply, 2U) != XST_SUCCESS) {
		StallEp0(InstancePtr);
	}
}

static void HandleFeatureRequest(XUsbPs *InstancePtr,
				 XUsbPs_SetupData *SetupData, int SetFeature)
{
	u8 Endpoint;

	switch (SetupData->bmRequestType & XUSBPS_STATUS_MASK) {
	case XUSBPS_STATUS_ENDPOINT:
		if (SetupData->wValue != XUSBPS_ENDPOINT_HALT) {
			StallEp0(InstancePtr);
			return;
		}

		Endpoint = (u8)(SetupData->wIndex & 0x0FU);
		if ((SetupData->wIndex & 0x80U) != 0U) {
			if (SetFeature != 0) {
				XUsbPs_SetBits(InstancePtr, XUSBPS_EPCRn_OFFSET(Endpoint),
					       XUSBPS_EPCR_TXS_MASK);
			} else {
				XUsbPs_ClrBits(InstancePtr, XUSBPS_EPCRn_OFFSET(Endpoint),
					       XUSBPS_EPCR_TXS_MASK);
			}
		} else if (SetFeature != 0) {
			XUsbPs_SetBits(InstancePtr, XUSBPS_EPCRn_OFFSET(Endpoint),
				       XUSBPS_EPCR_RXS_MASK);
		} else {
			XUsbPs_ClrBits(InstancePtr, XUSBPS_EPCRn_OFFSET(Endpoint),
				       XUSBPS_EPCR_RXS_MASK);
		}
		break;

	case XUSBPS_STATUS_DEVICE:
		if ((SetupData->wValue != XUSBPS_DEVICE_REMOTE_WAKEUP) &&
		    (SetupData->wValue != XUSBPS_TEST_MODE)) {
			StallEp0(InstancePtr);
			return;
		}
		break;

	default:
		StallEp0(InstancePtr);
		return;
	}

	if (XUsbPs_EpBufferSend(InstancePtr, 0U, NULL, 0U) != XST_SUCCESS) {
		StallEp0(InstancePtr);
	}
}

static void HandleStandardRequest(XUsbPs *InstancePtr,
				  XUsbPs_SetupData *SetupData)
{
#ifdef __ICCARM__
#pragma data_alignment = 32
	static u8 Reply[2];
#else
	static u8 Reply[2] ALIGNMENT_CACHELINE;
#endif

	switch (SetupData->bRequest) {
	case XUSBPS_REQ_GET_STATUS:
		HandleGetStatusRequest(InstancePtr, SetupData);
		break;

	case XUSBPS_REQ_SET_ADDRESS:
		XUsbPs_SetDeviceAddress(InstancePtr, SetupData->wValue);
		if (XUsbPs_EpBufferSend(InstancePtr, 0U, NULL, 0U) != XST_SUCCESS) {
			StallEp0(InstancePtr);
		}
		break;

	case XUSBPS_REQ_GET_DESCRIPTOR:
		HandleDescriptorRequest(InstancePtr, SetupData);
		break;

	case XUSBPS_REQ_SET_CONFIGURATION:
		if (((SetupData->wValue & 0xFFU) != 0U) &&
		    ((SetupData->wValue & 0xFFU) != 1U)) {
			StallEp0(InstancePtr);
			break;
		}

		CurrentConfig = (u8)(SetupData->wValue & 0xFFU);
		XUsbPs_SetConfiguration(InstancePtr, CurrentConfig);
		if (InstancePtr->AppData != NULL) {
			XUsbPs_SetConfigurationApp(InstancePtr, SetupData);
		}
		if (XUsbPs_EpBufferSend(InstancePtr, 0U, NULL, 0U) != XST_SUCCESS) {
			StallEp0(InstancePtr);
		}
		break;

	case XUSBPS_REQ_GET_CONFIGURATION:
		Reply[0] = CurrentConfig;
		Xil_DCacheFlushRange((UINTPTR)Reply, 1U);
		if (XUsbPs_EpBufferSend(InstancePtr, 0U, Reply, 1U) != XST_SUCCESS) {
			StallEp0(InstancePtr);
		}
		break;

	case XUSBPS_REQ_GET_INTERFACE:
		Reply[0] = (u8)InstancePtr->CurrentAltSetting;
		Xil_DCacheFlushRange((UINTPTR)Reply, 1U);
		if (XUsbPs_EpBufferSend(InstancePtr, 0U, Reply, 1U) != XST_SUCCESS) {
			StallEp0(InstancePtr);
		}
		break;

	case XUSBPS_REQ_SET_INTERFACE:
		InstancePtr->CurrentAltSetting = (u8)SetupData->wValue;
		if (InstancePtr->AppData != NULL) {
			XUsbPs_SetInterfaceHandler(InstancePtr, SetupData);
		}
		if (XUsbPs_EpBufferSend(InstancePtr, 0U, NULL, 0U) != XST_SUCCESS) {
			StallEp0(InstancePtr);
		}
		break;

	case XUSBPS_REQ_CLEAR_FEATURE:
		HandleFeatureRequest(InstancePtr, SetupData, 0);
		break;

	case XUSBPS_REQ_SET_FEATURE:
		HandleFeatureRequest(InstancePtr, SetupData, 1);
		break;

	default:
		StallEp0(InstancePtr);
		break;
	}
}

int XUsbPs_Ch9HandleSetupPacket(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData)
{
	switch (SetupData->bmRequestType & XUSBPS_REQ_TYPE_MASK) {
	case XUSBPS_CMD_STDREQ:
		HandleStandardRequest(InstancePtr, SetupData);
		return XST_SUCCESS;

	case XUSBPS_CMD_CLASSREQ:
	case XUSBPS_CMD_VENDREQ:
	default:
		StallEp0(InstancePtr);
		return XST_FAILURE;
	}
}
