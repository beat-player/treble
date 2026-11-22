## Vendored decoders

These decoders are vendored on build time by downloading the source tarball and compiling:

- dr_mp3 and dr_flac: <https://github.com/mackron/dr_libs>
- libogg: <https://github.com/xiph/ogg>
- libopus: <https://github.com/xiph/opus>
- libopusfile: <https://github.com/xiph/opusfile>
- Fraunhofer FDK AAC (FDK-AAC): <https://github.com/mstorsjo/fdk-aac>

FDK-AAC is compiled from the decoder half of the source tree only. It is
distributed under the Fraunhofer FDK AAC Codec Library license, whose full text
ships as `MODULE_LICENSE_FRAUNHOFER` in the source tarball. That license grants
no patent rights, so using AAC, including this decoder, may require patent
licenses from the relevant holders.
