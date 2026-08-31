# Harta de registre — DP-SRAM (`regfile.v`)

Adresele de mai jos sunt **locale**, în interiorul spațiului propriu al modulului DP-SRAM (cuvinte 0–7 din cei 256 disponibili în total; cuvântul 8+ e memoria de date). Adresa de bază absolută în harta globală a SoC-ului rămâne de stabilit (Set 4, cu colegii).

Accesibile din **ambele porturi** (A și B). La scriere simultană pe același registru, **Port A câștigă implicit** — aceeași convenție ca la coliziunile de memorie.

## Sumar

| Offset | Cuvânt | Nume | Access | Reset |
|---|---|---|---|---|
| `0x00` | 0 | `INT_STATUS` | R/W1C | `0x00000000` |
| `0x04` | 1 | `INT_ENABLE` | R/W | `0x00000000` |
| `0x08` | 2 | `FORCE_PRIORITY` | R/W | `0x00000000` |
| `0x0C` | 3 | `BANDWIDTH_A` | RO | `0x00000000` |
| `0x10` | 4 | `BANDWIDTH_B` | RO | `0x00000000` |
| `0x14` | 5 | `COLLISION_THRESHOLD` | R/W | `0x00000004` |
| `0x18` | 6 | `COOLDOWN_CYCLES` | R/W | `0x00000004` |
| `0x1C` | 7 | *(rezervat)* | — | citește `0x0`, scrierile sunt ignorate |

---

## `0x00` — `INT_STATUS` (R/W1C)

Fiecare bit se **setează** de hardware la evenimentul corespunzător din `collision_arbiter.v`, și se **șterge** de software scriind `1` pe bitul respectiv (scrierea unui `0` nu are efect). Dacă evenimentul hardware și scrierea de software se întâmplă în același ciclu, setarea are prioritate.

| Bit | Nume | Descriere |
|---|---|---|
| `0` | `COLLISION` | s-a produs o coliziune reală (Read/Write sau Write/Write) — `collision_event` |
| `1` | `COOLDOWN` | arbitrul a intrat în `COOLDOWN` (s-a atins `COLLISION_THRESHOLD`) — `cooldown_event` |
| `31:2` | — | rezervat, citește `0` |

`irq` (ieșirea de top a modulului) e activă cât timp `INT_STATUS & INT_ENABLE != 0`.

## `0x04` — `INT_ENABLE` (R/W)

| Bit | Nume | Descriere |
|---|---|---|
| `0` | `COLLISION_EN` | `1` = bitul `COLLISION` din `INT_STATUS` poate ridica `irq` |
| `1` | `COOLDOWN_EN` | `1` = bitul `COOLDOWN` din `INT_STATUS` poate ridica `irq` |
| `31:2` | — | rezervat (scriibil, dar fără efect) |

## `0x08` — `FORCE_PRIORITY` (R/W)

| Bit | Nume | Descriere |
|---|---|---|
| `0` | `PRIORITY` | `0` = Port A câștigă implicit la coliziune Write/Write, `1` = Port B câștigă |
| `31:1` | — | rezervat; scrierile pe acești biți sunt ignorate (registrul intern reține doar 1 bit) |

Nu afectează coliziunile Read/Write — la acelea scriitorul câștigă mereu, indiferent de acest bit.

## `0x0C` — `BANDWIDTH_A` (RO)

Numărul brut de cicluri în care Port A a avut o cerere activă către memorie, în ultima fereastră de măsurare încheiată (implicit 1024 cicluri, parametrul `WINDOW_CYCLES`). Nu numără accesul la regiunea de registre, doar la memorie. Scrierile pe acest registru sunt ignorate — valoarea rămâne strict cea calculată de hardware.

⚠️ **Limită cunoscută:** valoarea maximă posibilă e `WINDOW_CYCLES − 1`, nu `WINDOW_CYCLES`, chiar și sub activitate 100% continuă — ciclul în care fereastra se încheie e mereu folosit ca prim eșantion al ferestrei *următoare*, nu ca ultim increment al celei curente. Documentat, nu corectat (decizie explicită).

## `0x10` — `BANDWIDTH_B` (RO)

Identic cu `BANDWIDTH_A`, pentru Port B — inclusiv aceeași limită de `WINDOW_CYCLES − 1`.

## `0x14` — `COLLISION_THRESHOLD` (R/W)

| Bit | Nume | Descriere |
|---|---|---|
| `7:0` | `THRESHOLD` | numărul de coliziuni reale consecutive înainte de intrarea în `COOLDOWN` |
| `31:8` | — | rezervat |

⚠️ Nu scrie `0x00` aici — pragul nu s-ar mai atinge niciodată (vezi nota din `collision_arbiter.v`).

## `0x18` — `COOLDOWN_CYCLES` (R/W)

| Bit | Nume | Descriere |
|---|---|---|
| `7:0` | `CYCLES` | numărul de cicluri cât ambele porturi rămân blocate (`stall`) în `COOLDOWN` |
| `31:8` | — | rezervat |

⚠️ Nu scrie `0x00` aici — arbitrul ar rămâne permanent în `COOLDOWN`, fără cale de ieșire.

---

## Decizii încă deschise (Set 1 / Set 4)

- Adresa de bază absolută a acestui bloc de registre în harta globală a SoC-ului
- Dacă Port B (DMA) chiar are nevoie de acces la aceste registre, sau doar Port A (CPU)
- Fereastra exactă de măsurare pentru `BANDWIDTH_A/B` (1024 cicluri e doar valoarea implicită actuală)
