/******************************************************************************
 *
 * Copyright (C) 2026
 *
 * SPDX-License-Identifier: MIT
 *
 ******************************************************************************/

#include <string.h>

#include "xaxidma.h"
#include "xil_cache.h"
#ifndef SDT
#include "xil_exception.h"
#endif
#include "xil_printf.h"
#include "xparameters.h"
#ifndef SDT
#include "xscugic.h"
#else
#include "xinterrupt_wrap.h"
#endif
#include "xstatus.h"
#include "xusbps.h"
#include "xusbps_ch9.h"

#ifdef SDT
#define DMA_CONFIG_PARAM XPAR_XAXIDMA_0_BASEADDR
#define USB_CONFIG_PARAM XPAR_XUSBPS_0_BASEADDR
#elif defined(XPAR_AXIDMA_0_DEVICE_ID)
#define DMA_CONFIG_PARAM XPAR_AXIDMA_0_DEVICE_ID
#else
#error "AXI DMA is not present in xparameters.h"
#endif

#ifndef SDT
#if defined(XPAR_XUSBPS_0_DEVICE_ID)
#define USB_CONFIG_PARAM XPAR_XUSBPS_0_DEVICE_ID
#define USB_INTR_ID XPAR_XUSBPS_0_INTR
#elif defined(XPAR_PS7_USB_0_DEVICE_ID)
#define USB_CONFIG_PARAM XPAR_PS7_USB_0_DEVICE_ID
#define USB_INTR_ID XPAR_PS7_USB_0_INTR
#else
#error "USB0 is not present in xparameters.h"
#endif

#if defined(XPAR_SCUGIC_SINGLE_DEVICE_ID)
#define INTC_DEVICE_ID XPAR_SCUGIC_SINGLE_DEVICE_ID
#else
#error "SCUGIC device ID is not present in xparameters.h"
#endif
#endif

#if defined(XPAR_XAXIDMA_0_SG_INCLUDE_STSCNTRL_STRM)
#define DMA_HAS_STS_CTRL_STREAM XPAR_XAXIDMA_0_SG_INCLUDE_STSCNTRL_STRM
#elif defined(XPAR_AXIDMA_0_SG_INCLUDE_STSCNTRL_STRM)
#define DMA_HAS_STS_CTRL_STREAM XPAR_AXIDMA_0_SG_INCLUDE_STSCNTRL_STRM
#else
#define DMA_HAS_STS_CTRL_STREAM 0
#endif

#ifdef XPAR_AXI_7SDDR_0_S_AXI_BASEADDR
#define DDR_BASE_ADDR XPAR_AXI_7SDDR_0_S_AXI_BASEADDR
#elif defined(XPAR_MIG7SERIES_0_BASEADDR)
#define DDR_BASE_ADDR XPAR_MIG7SERIES_0_BASEADDR
#elif defined(XPAR_MIG_0_BASEADDR)
#define DDR_BASE_ADDR XPAR_MIG_0_BASEADDR
#elif defined(XPAR_PSU_DDR_0_S_AXI_BASEADDR)
#define DDR_BASE_ADDR XPAR_PSU_DDR_0_S_AXI_BASEADDR
#elif defined(XPAR_PS7_DDR_0_BASEADDRESS)
#define DDR_BASE_ADDR XPAR_PS7_DDR_0_BASEADDRESS
#endif

#ifndef DDR_BASE_ADDR
#warning CHECK FOR THE VALID DDR ADDRESS IN XPARAMETERS.H, DEFAULT SET TO 0x01000000
#define MEM_BASE_ADDR 0x01000000U
#else
#define MEM_BASE_ADDR (DDR_BASE_ADDR + 0x01000000U)
#endif

#define TX_BD_SPACE_BASE MEM_BASE_ADDR
#define TX_BD_SPACE_HIGH (MEM_BASE_ADDR + 0x00000FFFU)
#define RX_BD_SPACE_BASE (MEM_BASE_ADDR + 0x00001000U)
#define RX_BD_SPACE_HIGH (MEM_BASE_ADDR + 0x00001FFFU)
#define TX_BUFFER_BASE (MEM_BASE_ADDR + 0x00100000U)
#define RX_BUFFER_BASE (MEM_BASE_ADDR + 0x00300000U)

#define USB_DEVICE_MEMORY_SIZE (64U * 1024U)
#define USB_BULK_MAX_PACKET 512U
#define DMA_BUFFER_SIZE 1024U
#define DMA_POLL_LIMIT 10000000U

#define NN_CMD_RUN_BATCH 0xA5U
#define NN_FLAG_RESET 0x01U
#define NN_HEADER_SIZE 4U
#define NN_INPUT_BYTES_PER_STEP 9U
#define NN_OUTPUT_BYTES_PER_STEP 13U
#define NN_MAX_STEPS_PER_BATCH ((USB_BULK_MAX_PACKET - NN_HEADER_SIZE) / \
				NN_INPUT_BYTES_PER_STEP)

typedef struct {
	volatile int RxReady;
	volatile int TxBusy;
	volatile u32 RxLength;
	volatile u32 RxHandle;
	volatile u32 DroppedPackets;
	u8 *RxBuffer;
} UsbBridgeState;

static XAxiDma AxiDma;
static XUsbPs UsbInstance;
#ifndef SDT
static XScuGic IntcInstance;
#endif
static UsbBridgeState BridgeState;
static struct Usb_DevData UsbAppData;

#ifdef __ICCARM__
#pragma data_alignment = 32
static u8 UsbDeviceMemory[USB_DEVICE_MEMORY_SIZE];
#pragma data_alignment = 32
static u8 UsbInBuffer[DMA_BUFFER_SIZE];
#else
static u8 UsbDeviceMemory[USB_DEVICE_MEMORY_SIZE] ALIGNMENT_CACHELINE;
static u8 UsbInBuffer[DMA_BUFFER_SIZE] ALIGNMENT_CACHELINE;
#endif

static u8 *const DmaTxBuffer = (u8 *)TX_BUFFER_BASE;
static u8 *const DmaRxBuffer = (u8 *)RX_BUFFER_BASE;

static int InitDma(void);
static int InitUsb(void);
static int SetupRxRing(XAxiDma *AxiDmaInstPtr);
static int SetupTxRing(XAxiDma *AxiDmaInstPtr);
static int SetupUsbInterrupts(XUsbPs *UsbInstancePtr,
			      const XUsbPs_Config *UsbConfigPtr);
static void DisableUsbInterrupts(const XUsbPs_Config *UsbConfigPtr);
static int QueueRxTransfer(XAxiDma *AxiDmaInstPtr, u32 Length);
static int QueueTxTransfer(XAxiDma *AxiDmaInstPtr, u32 Length);
static int WaitForTransferCompletion(XAxiDma *AxiDmaInstPtr, u32 RxLength);
static int DecodeBatchCommand(const u8 *Command, u32 CommandLength,
			      u32 *ResponseLength);
static int RunDmaExchange(u32 TxLength, u32 RxLength, u8 *OutputBuffer);
static void ProcessReceivedUsbPacket(void);
static void UsbIntrHandler(void *CallBackRef, u32 Mask);
static void UsbEp0EventHandler(void *CallBackRef, u8 EpNum, u8 EventType,
			       void *Data);
static void UsbEp1OutEventHandler(void *CallBackRef, u8 EpNum, u8 EventType,
				  void *Data);
static void UsbEp1InEventHandler(void *CallBackRef, u8 EpNum, u8 EventType,
				 void *Data);

int main(void)
{
	int Status;

	memset(&BridgeState, 0, sizeof(BridgeState));

	xil_printf("\r\n--- ZedBoard USB DMA NN bridge ---\r\n");

	Status = InitDma();
	if (Status != XST_SUCCESS) {
		xil_printf("DMA initialization failed: %d\r\n", Status);
		return XST_FAILURE;
	}

	Status = InitUsb();
	if (Status != XST_SUCCESS) {
		xil_printf("USB initialization failed: %d\r\n", Status);
		return XST_FAILURE;
	}

	xil_printf("Enumerate the OTG port as a USB device and stream NN batches to endpoint 0x01.\r\n");

	for (;;) {
		ProcessReceivedUsbPacket();
	}
}

static int InitDma(void)
{
	int Status;
	XAxiDma_Config *Config;

	Config = XAxiDma_LookupConfig(DMA_CONFIG_PARAM);
	if (Config == NULL) {
		return XST_FAILURE;
	}

	Status = XAxiDma_CfgInitialize(&AxiDma, Config);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	if (!XAxiDma_HasSg(&AxiDma)) {
		xil_printf("AXI DMA is configured in simple mode; this app expects SG mode.\r\n");
		return XST_FAILURE;
	}

	Status = SetupTxRing(&AxiDma);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	return SetupRxRing(&AxiDma);
}

static int InitUsb(void)
{
	int Status;
	XUsbPs_Config *UsbConfigPtr;
	XUsbPs_DeviceConfig DeviceConfig;

	memset(&DeviceConfig, 0, sizeof(DeviceConfig));

	UsbConfigPtr = XUsbPs_LookupConfig(USB_CONFIG_PARAM);
	if (UsbConfigPtr == NULL) {
		return XST_FAILURE;
	}

	Status = XUsbPs_CfgInitialize(&UsbInstance, UsbConfigPtr,
				      UsbConfigPtr->BaseAddress);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	Status = SetupUsbInterrupts(&UsbInstance, UsbConfigPtr);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	DeviceConfig.EpCfg[0].Out.Type = XUSBPS_EP_TYPE_CONTROL;
	DeviceConfig.EpCfg[0].Out.NumBufs = 2U;
	DeviceConfig.EpCfg[0].Out.BufSize = 64U;
	DeviceConfig.EpCfg[0].Out.MaxPacketSize = 64U;
	DeviceConfig.EpCfg[0].In.Type = XUSBPS_EP_TYPE_CONTROL;
	DeviceConfig.EpCfg[0].In.NumBufs = 2U;
	DeviceConfig.EpCfg[0].In.MaxPacketSize = 64U;

	DeviceConfig.EpCfg[1].Out.Type = XUSBPS_EP_TYPE_BULK;
	DeviceConfig.EpCfg[1].Out.NumBufs = 16U;
	DeviceConfig.EpCfg[1].Out.BufSize = USB_BULK_MAX_PACKET;
	DeviceConfig.EpCfg[1].Out.MaxPacketSize = USB_BULK_MAX_PACKET;
	DeviceConfig.EpCfg[1].In.Type = XUSBPS_EP_TYPE_BULK;
	DeviceConfig.EpCfg[1].In.NumBufs = 16U;
	DeviceConfig.EpCfg[1].In.MaxPacketSize = USB_BULK_MAX_PACKET;
	DeviceConfig.NumEndpoints = 2U;

	memset(UsbDeviceMemory, 0, sizeof(UsbDeviceMemory));
	Xil_DCacheFlushRange((UINTPTR)UsbDeviceMemory, sizeof(UsbDeviceMemory));
	DeviceConfig.DMAMemPhys = (u32)(UINTPTR)UsbDeviceMemory;

	Status = XUsbPs_ConfigureDevice(&UsbInstance, &DeviceConfig);
	if (Status != XST_SUCCESS) {
		DisableUsbInterrupts(UsbConfigPtr);
		return Status;
	}

	memset(&UsbAppData, 0, sizeof(UsbAppData));
	UsbAppData.PrivateData = &BridgeState;
	UsbAppData.State = XUSBPS_STATE_DEFAULT;
	UsbInstance.AppData = &UsbAppData;

	Status = XUsbPs_IntrSetHandler(&UsbInstance, UsbIntrHandler, NULL,
				       XUSBPS_IXR_UE_MASK);
	if (Status != XST_SUCCESS) {
		DisableUsbInterrupts(UsbConfigPtr);
		return Status;
	}

	Status = XUsbPs_EpSetHandler(&UsbInstance, 0U,
				     XUSBPS_EP_DIRECTION_OUT,
				     UsbEp0EventHandler, &UsbInstance);
	if (Status != XST_SUCCESS) {
		DisableUsbInterrupts(UsbConfigPtr);
		return Status;
	}

	Status = XUsbPs_EpSetHandler(&UsbInstance, 1U,
				     XUSBPS_EP_DIRECTION_OUT,
				     UsbEp1OutEventHandler, &UsbInstance);
	if (Status != XST_SUCCESS) {
		DisableUsbInterrupts(UsbConfigPtr);
		return Status;
	}

	Status = XUsbPs_EpSetHandler(&UsbInstance, 1U,
				     XUSBPS_EP_DIRECTION_IN,
				     UsbEp1InEventHandler, &UsbInstance);
	if (Status != XST_SUCCESS) {
		DisableUsbInterrupts(UsbConfigPtr);
		return Status;
	}

	XUsbPs_IntrEnable(&UsbInstance, XUSBPS_IXR_UR_MASK | XUSBPS_IXR_UI_MASK);
	XUsbPs_Start(&UsbInstance);

	return XST_SUCCESS;
}

static int SetupTxRing(XAxiDma *AxiDmaInstPtr)
{
	int Status;
	int Delay = 0;
	int Coalesce = 1;
	u32 BdCount;
	XAxiDma_BdRing *TxRingPtr;
	XAxiDma_Bd BdTemplate;

	TxRingPtr = XAxiDma_GetTxRing(AxiDmaInstPtr);

	XAxiDma_BdRingIntDisable(TxRingPtr, XAXIDMA_IRQ_ALL_MASK);
	XAxiDma_BdRingSetCoalesce(TxRingPtr, Coalesce, Delay);

	BdCount = XAxiDma_BdRingCntCalc(XAXIDMA_BD_MINIMUM_ALIGNMENT,
					TX_BD_SPACE_HIGH - TX_BD_SPACE_BASE + 1U);
	Status = XAxiDma_BdRingCreate(TxRingPtr, TX_BD_SPACE_BASE,
				      TX_BD_SPACE_BASE,
				      XAXIDMA_BD_MINIMUM_ALIGNMENT, BdCount);
	if (Status != XST_SUCCESS) {
		xil_printf("TX BD ring create failed: %d\r\n", Status);
		return Status;
	}

	XAxiDma_BdClear(&BdTemplate);
	Status = XAxiDma_BdRingClone(TxRingPtr, &BdTemplate);
	if (Status != XST_SUCCESS) {
		xil_printf("TX BD ring clone failed: %d\r\n", Status);
		return Status;
	}

	Status = XAxiDma_BdRingStart(TxRingPtr);
	if (Status != XST_SUCCESS) {
		xil_printf("TX ring start failed: %d\r\n", Status);
	}

	return Status;
}

static int SetupRxRing(XAxiDma *AxiDmaInstPtr)
{
	int Status;
	int Delay = 0;
	int Coalesce = 1;
	u32 BdCount;
	XAxiDma_BdRing *RxRingPtr;
	XAxiDma_Bd BdTemplate;

	RxRingPtr = XAxiDma_GetRxRing(AxiDmaInstPtr);

	XAxiDma_BdRingIntDisable(RxRingPtr, XAXIDMA_IRQ_ALL_MASK);
	XAxiDma_BdRingSetCoalesce(RxRingPtr, Coalesce, Delay);

	BdCount = XAxiDma_BdRingCntCalc(XAXIDMA_BD_MINIMUM_ALIGNMENT,
					RX_BD_SPACE_HIGH - RX_BD_SPACE_BASE + 1U);
	Status = XAxiDma_BdRingCreate(RxRingPtr, RX_BD_SPACE_BASE,
				      RX_BD_SPACE_BASE,
				      XAXIDMA_BD_MINIMUM_ALIGNMENT, BdCount);
	if (Status != XST_SUCCESS) {
		xil_printf("RX BD ring create failed: %d\r\n", Status);
		return Status;
	}

	XAxiDma_BdClear(&BdTemplate);
	Status = XAxiDma_BdRingClone(RxRingPtr, &BdTemplate);
	if (Status != XST_SUCCESS) {
		xil_printf("RX BD ring clone failed: %d\r\n", Status);
		return Status;
	}

	Status = XAxiDma_BdRingStart(RxRingPtr);
	if (Status != XST_SUCCESS) {
		xil_printf("RX ring start failed: %d\r\n", Status);
	}

	return Status;
}

static int SetupUsbInterrupts(XUsbPs *UsbInstancePtr,
			      const XUsbPs_Config *UsbConfigPtr)
{
#ifdef SDT
	return XSetupInterruptSystem(UsbInstancePtr, &XUsbPs_IntrHandler,
				     UsbConfigPtr->IntrId,
				     UsbConfigPtr->IntrParent,
				     XINTERRUPT_DEFAULT_PRIORITY);
#else
	int Status;
	XScuGic_Config *IntcConfig;

	IntcConfig = XScuGic_LookupConfig(INTC_DEVICE_ID);
	if (IntcConfig == NULL) {
		return XST_FAILURE;
	}

	Status = XScuGic_CfgInitialize(&IntcInstance, IntcConfig,
				       IntcConfig->CpuBaseAddress);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	Xil_ExceptionInit();
	Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
				     (Xil_ExceptionHandler)XScuGic_InterruptHandler,
				     &IntcInstance);

	Status = XScuGic_Connect(&IntcInstance, UsbConfigPtr->IntrId,
				 (Xil_ExceptionHandler)XUsbPs_IntrHandler,
				 (void *)UsbInstancePtr);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	XScuGic_Enable(&IntcInstance, UsbConfigPtr->IntrId);
	Xil_ExceptionEnableMask(XIL_EXCEPTION_IRQ);

	return XST_SUCCESS;
#endif
}

static void DisableUsbInterrupts(const XUsbPs_Config *UsbConfigPtr)
{
#ifdef SDT
	XDisconnectInterruptCntrl(UsbConfigPtr->IntrId, UsbConfigPtr->IntrParent);
#else
	XScuGic_Disconnect(&IntcInstance, UsbConfigPtr->IntrId);
#endif
}

static int QueueRxTransfer(XAxiDma *AxiDmaInstPtr, u32 Length)
{
	int Status;
	XAxiDma_Bd *BdPtr;
	XAxiDma_BdRing *RxRingPtr;

	RxRingPtr = XAxiDma_GetRxRing(AxiDmaInstPtr);

	Status = XAxiDma_BdRingAlloc(RxRingPtr, 1U, &BdPtr);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	Status = XAxiDma_BdSetBufAddr(BdPtr, (UINTPTR)DmaRxBuffer);
	if (Status != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(RxRingPtr, 1U, BdPtr);
		return Status;
	}

	Status = XAxiDma_BdSetLength(BdPtr, Length, RxRingPtr->MaxTransferLen);
	if (Status != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(RxRingPtr, 1U, BdPtr);
		return Status;
	}

	XAxiDma_BdSetCtrl(BdPtr, 0U);
	XAxiDma_BdSetId(BdPtr, (UINTPTR)DmaRxBuffer);

	memset(DmaRxBuffer, 0, Length);
	Xil_DCacheFlushRange((UINTPTR)DmaRxBuffer, Length);

	Status = XAxiDma_BdRingToHw(RxRingPtr, 1U, BdPtr);
	if (Status != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(RxRingPtr, 1U, BdPtr);
	}

	return Status;
}

static int QueueTxTransfer(XAxiDma *AxiDmaInstPtr, u32 Length)
{
	int Status;
	XAxiDma_Bd *BdPtr;
	XAxiDma_BdRing *TxRingPtr;

	TxRingPtr = XAxiDma_GetTxRing(AxiDmaInstPtr);

	Status = XAxiDma_BdRingAlloc(TxRingPtr, 1U, &BdPtr);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	Status = XAxiDma_BdSetBufAddr(BdPtr, (UINTPTR)DmaTxBuffer);
	if (Status != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(TxRingPtr, 1U, BdPtr);
		return Status;
	}

	Status = XAxiDma_BdSetLength(BdPtr, Length, TxRingPtr->MaxTransferLen);
	if (Status != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(TxRingPtr, 1U, BdPtr);
		return Status;
	}

#if (DMA_HAS_STS_CTRL_STREAM == 1)
	(void)XAxiDma_BdSetAppWord(BdPtr, XAXIDMA_LAST_APPWORD, Length);
#endif

	XAxiDma_BdSetCtrl(BdPtr, XAXIDMA_BD_CTRL_TXSOF_MASK |
				 XAXIDMA_BD_CTRL_TXEOF_MASK);
	XAxiDma_BdSetId(BdPtr, (UINTPTR)DmaTxBuffer);

	Xil_DCacheFlushRange((UINTPTR)DmaTxBuffer, Length);

	Status = XAxiDma_BdRingToHw(TxRingPtr, 1U, BdPtr);
	if (Status != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(TxRingPtr, 1U, BdPtr);
	}

	return Status;
}

static int WaitForTransferCompletion(XAxiDma *AxiDmaInstPtr, u32 RxLength)
{
	int Status;
	u32 Timeout;
	int ProcessedBdCount;
	XAxiDma_Bd *BdPtr;
	XAxiDma_BdRing *TxRingPtr;
	XAxiDma_BdRing *RxRingPtr;

	TxRingPtr = XAxiDma_GetTxRing(AxiDmaInstPtr);
	RxRingPtr = XAxiDma_GetRxRing(AxiDmaInstPtr);

	Timeout = DMA_POLL_LIMIT;
	do {
		ProcessedBdCount = XAxiDma_BdRingFromHw(TxRingPtr, 1U, &BdPtr);
	} while ((ProcessedBdCount == 0) && (--Timeout > 0U));

	if (ProcessedBdCount == 0) {
		return XST_FAILURE;
	}

	Status = XAxiDma_BdRingFree(TxRingPtr, ProcessedBdCount, BdPtr);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	Timeout = DMA_POLL_LIMIT;
	do {
		ProcessedBdCount = XAxiDma_BdRingFromHw(RxRingPtr, 1U, &BdPtr);
	} while ((ProcessedBdCount == 0) && (--Timeout > 0U));

	if (ProcessedBdCount == 0) {
		return XST_FAILURE;
	}

	Status = XAxiDma_BdRingFree(RxRingPtr, ProcessedBdCount, BdPtr);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	Xil_DCacheInvalidateRange((UINTPTR)DmaRxBuffer, RxLength);

	return XST_SUCCESS;
}

static int DecodeBatchCommand(const u8 *Command, u32 CommandLength,
			      u32 *ResponseLength)
{
	u32 StepCount;
	u32 ExpectedLength;
	u32 ExpectedReplyLength;

	if ((Command == NULL) || (ResponseLength == NULL)) {
		return XST_INVALID_PARAM;
	}

	if ((CommandLength < NN_HEADER_SIZE) || (Command[0] != NN_CMD_RUN_BATCH)) {
		return XST_INVALID_PARAM;
	}

	StepCount = ((u32)Command[2] << 8) | (u32)Command[3];
	if ((StepCount == 0U) || (StepCount > NN_MAX_STEPS_PER_BATCH)) {
		return XST_INVALID_PARAM;
	}

	ExpectedLength = NN_HEADER_SIZE + (StepCount * NN_INPUT_BYTES_PER_STEP);
	ExpectedReplyLength = StepCount * NN_OUTPUT_BYTES_PER_STEP;

	if ((CommandLength != ExpectedLength) || (ExpectedReplyLength > DMA_BUFFER_SIZE)) {
		return XST_INVALID_PARAM;
	}

	*ResponseLength = ExpectedReplyLength;
	return XST_SUCCESS;
}

static int RunDmaExchange(u32 TxLength, u32 RxLength, u8 *OutputBuffer)
{
	int Status;

	if ((TxLength == 0U) || (TxLength > DMA_BUFFER_SIZE) ||
	    (RxLength == 0U) || (RxLength > DMA_BUFFER_SIZE)) {
		return XST_INVALID_PARAM;
	}

	Status = QueueRxTransfer(&AxiDma, RxLength);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	Status = QueueTxTransfer(&AxiDma, TxLength);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	Status = WaitForTransferCompletion(&AxiDma, RxLength);
	if (Status != XST_SUCCESS) {
		return Status;
	}

	memcpy(OutputBuffer, DmaRxBuffer, RxLength);
	return XST_SUCCESS;
}

static void ProcessReceivedUsbPacket(void)
{
	int Status;
	u32 Length;
	u32 ResponseLength;
	u32 Handle;
	u8 *RxBuffer;

	if ((BridgeState.RxReady == 0) || (BridgeState.TxBusy != 0)) {
		return;
	}

	Length = BridgeState.RxLength;
	Handle = BridgeState.RxHandle;
	RxBuffer = BridgeState.RxBuffer;

	BridgeState.RxReady = 0;
	BridgeState.RxLength = 0U;
	BridgeState.RxHandle = 0U;
	BridgeState.RxBuffer = NULL;

	if ((RxBuffer == NULL) || (Length == 0U) || (Length > USB_BULK_MAX_PACKET)) {
		XUsbPs_EpBufferRelease(Handle);
		return;
	}

	Status = DecodeBatchCommand(RxBuffer, Length, &ResponseLength);
	if (Status != XST_SUCCESS) {
		xil_printf("Invalid NN batch: len=%d status=%d\r\n", (int)Length, Status);
		XUsbPs_EpBufferRelease(Handle);
		return;
	}

	memcpy(DmaTxBuffer, RxBuffer, Length);
	XUsbPs_EpBufferRelease(Handle);

	Status = RunDmaExchange(Length, ResponseLength, UsbInBuffer);
	if (Status != XST_SUCCESS) {
		xil_printf("DMA NN exchange failed for tx=%d rx=%d bytes: %d\r\n",
			   (int)Length, (int)ResponseLength, Status);
		return;
	}

	Xil_DCacheFlushRange((UINTPTR)UsbInBuffer, ResponseLength);

	BridgeState.TxBusy = 1;
	Status = XUsbPs_EpBufferSendWithZLT(&UsbInstance, 1U, UsbInBuffer,
					    ResponseLength);
	if (Status != XST_SUCCESS) {
		BridgeState.TxBusy = 0;
		xil_printf("USB IN transfer failed: %d\r\n", Status);
	}
}

static void UsbIntrHandler(void *CallBackRef, u32 Mask)
{
	(void)CallBackRef;
	(void)Mask;
}

static void UsbEp0EventHandler(void *CallBackRef, u8 EpNum, u8 EventType,
			       void *Data)
{
	int Status;
	u32 BufferLen;
	u32 Handle;
	u8 *BufferPtr;
	XUsbPs *InstancePtr;
	XUsbPs_SetupData SetupData;

	(void)Data;

	Xil_AssertVoid(CallBackRef != NULL);
	InstancePtr = (XUsbPs *)CallBackRef;

	switch (EventType) {
	case XUSBPS_EP_EVENT_SETUP_DATA_RECEIVED:
		Status = XUsbPs_EpGetSetupData(InstancePtr, EpNum, &SetupData);
		if (Status == XST_SUCCESS) {
			(void)XUsbPs_Ch9HandleSetupPacket(InstancePtr, &SetupData);
		}
		break;

	case XUSBPS_EP_EVENT_DATA_RX:
		Status = XUsbPs_EpBufferReceive(InstancePtr, EpNum, &BufferPtr,
						&BufferLen, &Handle);
		if (Status == XST_SUCCESS) {
			XUsbPs_EpBufferRelease(Handle);
		}
		break;

	default:
		break;
	}
}

static void UsbEp1OutEventHandler(void *CallBackRef, u8 EpNum, u8 EventType,
				  void *Data)
{
	int Status;
	u32 BufferLen;
	u32 Handle;
	u8 *BufferPtr;
	XUsbPs *InstancePtr;

	(void)Data;

	if (EventType != XUSBPS_EP_EVENT_DATA_RX) {
		return;
	}

	Xil_AssertVoid(CallBackRef != NULL);
	InstancePtr = (XUsbPs *)CallBackRef;

	Status = XUsbPs_EpBufferReceive(InstancePtr, EpNum, &BufferPtr,
					&BufferLen, &Handle);
	if (Status != XST_SUCCESS) {
		return;
	}

	if (BufferLen != 0U) {
		Xil_DCacheInvalidateRange((UINTPTR)BufferPtr,
					  DCACHE_INVALIDATE_SIZE(BufferLen));
	}

	if ((BridgeState.RxReady != 0) || (BufferLen == 0U) ||
	    (BufferLen > USB_BULK_MAX_PACKET)) {
		BridgeState.DroppedPackets++;
		XUsbPs_EpBufferRelease(Handle);
		return;
	}

	BridgeState.RxBuffer = BufferPtr;
	BridgeState.RxLength = BufferLen;
	BridgeState.RxHandle = Handle;
	BridgeState.RxReady = 1;
}

static void UsbEp1InEventHandler(void *CallBackRef, u8 EpNum, u8 EventType,
				 void *Data)
{
	(void)CallBackRef;
	(void)EpNum;
	(void)Data;

	if (EventType == XUSBPS_EP_EVENT_DATA_TX) {
		BridgeState.TxBusy = 0;
	}
}
