"""PIC priority vectors from the documented ordering, without RTL state or constants."""

from pathlib import Path
import random


def main():
    rng = random.Random(715)
    cases = []
    for band_config in range(256):
        configs = [(source % 4) * 2 + rng.randrange(16) * 16 for source in range(16)]
        cases.append((configs, band_config, rng.getrandbits(16), rng.getrandbits(16), rng.getrandbits(16)))
    # Every source wins, equal priorities tie on the lowest source number.
    cases += [([0] * 16, 0x1B, 0xFFFF, 1 << source, 0xFFFF) for source in range(16)]
    cases += [([0] * 16, 0x1B, 0xFFFF, 0xFFFF, 0xFFFF),
              ([0] * 16, 0x1B, 0xFFFF, 0, 0xFFFF),
              ([0] * 16, 0x1B, 0xFFFF, 0xFFFF, 0)]
    words = []
    for configs, bands, enable, mask, sources in cases:
        pending = sources & enable
        candidates = [source for source in range(16) if pending & mask & (1 << source)]

        def order(source):
            band = (configs[source] >> 1) & 3
            urgency = (bands >> (band * 2)) & 3
            priority = (configs[source] >> 4) & 15
            return -urgency, -priority, source

        ranked = sorted(candidates, key=order)
        offer = 0x10 | ranked[0] if ranked else 0
        words += configs + [bands, enable, mask, sources, offer, pending]
    root = Path(__file__).resolve().parent
    (root / "pic_reference.hex").write_text("\n".join(f"{word:08x}" for word in words) + "\n")
    (root / "pic_reference_count.vh").write_text(f"localparam PIC_CASES = {len(cases)};\n")
    print(f"PIC reference: {len(cases)} cases, all 256 band configurations")


if __name__ == "__main__":
    main()
