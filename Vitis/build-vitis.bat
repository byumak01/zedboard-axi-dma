@ECHO OFF
setlocal

IF "%XILINX_VITIS%"=="" SET XILINX_VITIS=C:\Xilinx\Vitis\2025.2
CALL "%XILINX_VITIS%\cli\examples\customer_python_utils\setup_vitis_env.bat"
"%XILINX_VITIS%\bin\vitis.bat" -s build-vitis.py
pause
