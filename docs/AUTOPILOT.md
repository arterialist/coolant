# How Autopilot decides

Autopilot computes a demand from 0 to 1 for each part and drives both fans from the largest one. The limits below are engineering judgment based on the sources at the end. Apple does not publish fan or temperature targets for these parts.

| Part | Fans start rising | Full speed |
| --- | --- | --- |
| CPU hottest | 60 °C | 80 °C |
| GPU hottest | 55 °C | 75 °C |
| Battery | 32 °C, or room air + 2 °C, at most 38 °C | Start + 5 °C |
| SSD | 50 °C | 70 °C |

macOS thermal pressure sets a floor of 40%, 85% and 100% for fair, serious and critical.

Readings count rises within seconds (4 s time constant) and falls over about 45 seconds. Fans rise at 20% of their range per second and fall at 2%. The fans never stop while Autopilot is selected, because stopped fans take several seconds to accept manual control.

Autopilot is tuned to cool first and accept noise. A trigger can add cooling under Autopilot but cannot reduce it.

Fans cannot hold every workload under these limits. On the M3 Pro test machine, with all cores loaded and both fans at maximum, the hottest core read 84 to 88 °C.

## Why these limits

**Battery.** This is the part most likely to age first. Apple says ambient temperatures above 35 °C can permanently damage capacity. Calendar ageing speeds up with temperature, and the effect of charge level is strongest at the top of the range. A fan cannot cool below room air, so the target follows a hot room up to a limit.

**Chips.** Electromigration follows Black's equation, an Arrhenius curve in junction temperature. Lower is better, with no clear cliff at typical operating temperatures.

**Solder joints.** Fatigue life scales with roughly the inverse square of each temperature swing (Coffin-Manson). That is why falling temperature is followed slowly.

**Fans.** Vendor data for small cooling fans puts grease breakdown as the usual limit, and temperature as its main driver. None of those sources are laptop-specific.

**SSD.** NAND charge leaks faster when hot, but the published figures mostly describe unpowered retention. The SSD row is the weakest of the four.

## Sources

- [Apple: maximizing battery life and lifespan](https://www.apple.com/batteries/maximizing-performance/)
- [Apple: MacBook Pro 16-inch (Nov 2023) specifications](https://support.apple.com/en-us/117737)
- [Werner et al., Calendar Aging of Li-Ion Cells, Batteries 2021](https://doaj.org/article/cc60a71d6de0422d88652650040f9b00)
- [Temperature cycling and electronics fatigue](https://smtnet.com/library/files/upload/Temp-Cycling-and-Electronics-Fatigue.pdf)
- [Texas Instruments: junction temperature and lifetime](https://ti.com/de/lit/pdf/slva525)
- [Sanyo Denki: understanding fan life](https://sanyodenki.com/global/america/documents/Sanyo_Denki_America_Understanding_Fan_Life.pdf)
- [Oriental Motor: service life of cooling fans](https://www.orientalmotor.eu/uk/tech/reference/life06)
- [NAND retention and temperature](https://hal-lirmm.ccsd.cnrs.fr/lirmm-01687675v1/document)
