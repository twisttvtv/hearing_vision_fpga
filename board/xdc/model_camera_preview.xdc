# Only import when the BD wrapper exports the optional test image UART.
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports uart_txd]
