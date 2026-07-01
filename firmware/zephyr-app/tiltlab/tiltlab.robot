# End-to-end verification of the tilt -> hub -> bulb BLE beacon relay.
#
# Run against the shipped firmware in ../../defaults with the portable Renode:
#     cd <renode_portable>
#     ./renode-test <this-repo>/firmware/zephyr-app/tiltlab/tiltlab.robot > out.txt 2>&1
#     # read out.txt; success ends with "Tests finished successfully :)"
#
# NOTE: run WITHOUT the Zephyr Python venv active (it lacks robotframework).
# The ELF paths below are absolute for this checkout - adjust if you relocate
# the repo. See docs/13-tilt-to-light-ble-firmware.md.

*** Settings ***
Suite Teardown                Reset Emulation

*** Variables ***
${UART}                       sysbus.uart0
${FW}                         /home/purge/Desktop/fauvido/Stuff_new/multi-node-wireless/firmware/defaults
${HUB_ELF}                    @${FW}/gateway.elf
${BULB_ELF}                   @${FW}/heartrate.elf
${MOTION_ELF}                 @${FW}/motion.elf

${MOTION_PLAT}=  SEPARATOR=
...  """                                     ${\n}
...  using "platforms/cpus/nrf52840.repl"    ${\n}
...  adxl372: Sensors.ADXL372 @ spi2         ${\n}
...  gpio0:                                  ${\n}
...  ${SPACE*4}22 -> adxl372@0               ${\n}
...  """

*** Test Cases ***
Tilt Broadcast Is Relayed Through The Hub Into Bulb Brightness
    Execute Command           emulation CreateBLEMedium "wireless"

    Execute Command           mach create "gateway"
    Execute Command           machine LoadPlatformDescription @platforms/cpus/nrf52840.repl
    Execute Command           sysbus LoadELF ${HUB_ELF}
    Execute Command           connector Connect sysbus.radio wireless
    ${hub}=                   Create Terminal Tester    ${UART}    machine=gateway

    Execute Command           mach create "heartrate"
    Execute Command           machine LoadPlatformDescription @platforms/cpus/nrf52840.repl
    Execute Command           sysbus LoadELF ${BULB_ELF}
    Execute Command           connector Connect sysbus.radio wireless
    ${bulb}=                  Create Terminal Tester    ${UART}    machine=heartrate

    Execute Command           mach create "motion"
    Execute Command           machine LoadPlatformDescriptionFromString ${MOTION_PLAT}
    Execute Command           sysbus LoadELF ${MOTION_ELF}
    Execute Command           connector Connect sysbus.radio wireless
    ${motion}=                Create Terminal Tester    ${UART}    machine=motion

    Execute Command           emulation SetGlobalQuantum "0.00001"
    Execute Command           emulation SetGlobalSerialExecution True

    Execute Command           mach set "motion"
    Execute Command           sysbus.spi2.adxl372 AccelerationX 0
    Execute Command           sysbus.spi2.adxl372 AccelerationY 0
    Execute Command           sysbus.spi2.adxl372 AccelerationZ 1

    Start Emulation

    # sensor reads over SPI and broadcasts
    Wait For Line On Uart     Broadcasting tilt beacon    testerId=${motion}    timeout=30
    Wait For Line On Uart     SPI read                    testerId=${motion}    timeout=30

    # hub relay comes up and computes brightness (0% while level)
    Wait For Line On Uart     relay online                testerId=${hub}       timeout=30
    Wait For Line On Uart     brightness 0%               testerId=${hub}       timeout=30

    # bulb receives the computed intensity
    Wait For Line On Uart     Light intensity = 0%        testerId=${bulb}      timeout=30

    # knock it over -> brightness climbs -> bulb driven to full
    Execute Command           mach set "motion"
    Execute Command           sysbus.spi2.adxl372 AccelerationX 10
    Execute Command           sysbus.spi2.adxl372 AccelerationY 10
    Wait For Line On Uart     driving to full brightness  testerId=${bulb}      timeout=30

    # back to level -> intensity returns to 0 (proves sustained relaying)
    Execute Command           mach set "motion"
    Execute Command           sysbus.spi2.adxl372 AccelerationX 0
    Execute Command           sysbus.spi2.adxl372 AccelerationY 0
    Wait For Line On Uart     Light intensity = 0%        testerId=${bulb}      timeout=40
