# VSpider
## ZX Spectrum Pentagon Clone

A modern reimplementation of the classic **Pentagon** architecture.
---

## Hardware Features

- ULA implemented using an **Altera CPLD** (EPM3256)
- **512 KB RAM**
- **128 KB ROM**
- **DivMMC**
- **Z-Controller**
- **YM2149F TurboSound** sound system with true stereo output
- **Kempston-compatible** joystick interface
- Video outputs:
  - RGB
  - Composite
  - S-Video
- EAR/MIC
- Audio out
- Power supply input supports **either polarity**
- PCB fully optimized for **through-hole assembly**

---

## Operating Modes

**A.** Pentagon 128 KB + DivMMC  
**B.** Pentagon 512 KB + GLUK Service, Z-Controller, TR-DOS virtual 384 KB disk drive

---

## EPROM contents

| Bank | Address (HEX) | Content |
|------|---------------|---------|
| 0 | 00000h – 03FFFh | esxDOS |
| 1 | 04000h – 07FFFh | esxDOS |
| 2 | 08000h – 0BFFFh | BASIC 128 |
| 3 | 0C000h – 0FFFFh | BASIC 48 |
| 4 | 10000h – 13FFFh | GLUK or FATALL |
| 5 | 14000h – 17FFFh | TR-DOS |
| 6 | 18000h – 1BFFFh | BASIC 128 |
| 7 | 1C000h – 1FFFFh | BASIC 48 |

---

## Known Fixes & Notes

### Tape Loading Issue

If tape loading does not work, check transistor **Q1 (BC517)**.

⚠️ **Important:**  
BC517 transistors are available with **different pinouts**, depending on the manufacturer.

Pin numbering when viewed from the left side:

- **1. Collector / 2. Base / 3. Emitter**  
  → Solder exactly as shown on the PCB silkscreen

- **1. Emitter / 2. Base / 3. Collector**  
  → Solder the transistor rotated **180°**

Incorrect orientation will prevent tape loading from working.

---

## VSpider Photo

![VSpider](/photos/vspider_06.jpg)

![VSpider Board](/photos/vspider_01.jpg)


### Look at YouTube:
[![YouTube link](https://img.youtube.com/vi/_SU3fSY0keU/0.jpg)](https://www.youtube.com/watch?v=_SU3fSY0keU)
