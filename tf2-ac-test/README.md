# TF2 Anti-Cheat Calibration Harness

Bu paket özel TF2 sunucusunda **yalnızca fake-client botları** kullanarak anti-cheat algılama hattını test eder. Gerçek oyunculara istemci tarafı hile, DLL, injector veya VAC bypass sağlamaz.

## Bileşenler

- `scripting/tf2_ac_bot_simulator.sp` — bot-only sentetik davranış üretici.
- `scripting/tf2_ac_shadow_detector.sp` — simülatörden bağımsız shadow-mode dedektör.
- `cfg/sourcemod/*.cfg` — varsayılan test profilleri.

## Test profili

- Tepki gecikmesi: **yok**.
- Snap toplam açısı: **24–40°**.
- Snap süresi: **1–3 server tick**.
- İnsanlaştırılmış mikro düzeltme: **yok**.
- Olay aralığı: **45–90 saniye**.
- Kill sonrası hızlı hedef değişimi: açık.
- Gizli hedef takibi: **0,75 s**; bu sırada `IN_ATTACK` zorla kapatılır.
- Dedektör varsayılanı: **yalnızca botlar**.
- Gerçek ban: **yok**; yalnızca `WOULD-BAN` loglanır.

## Derleme

Repo içindeki GitHub Actions workflow'u SourceMod 1.12'nin güncel Linux paketini indirip iki `.sp` dosyasını derler ve `.smx` dosyalarını artifact olarak yayınlar.

Yerelde SourceMod scripting klasöründe de derleyebilirsin:

```bash
spcomp tf2_ac_bot_simulator.sp
spcomp tf2_ac_shadow_detector.sp
```

## Sunucuya kurulum

Derlenen dosyalar:

```text
tf/addons/sourcemod/plugins/tf2_ac_bot_simulator.smx
tf/addons/sourcemod/plugins/tf2_ac_shadow_detector.smx
```

Ayar dosyaları:

```text
tf/cfg/sourcemod/tf2_ac_bot_simulator.cfg
tf/cfg/sourcemod/tf2_ac_shadow_detector.cfg
```

Harita değiştir veya:

```text
sm plugins load tf2_ac_shadow_detector
sm plugins load tf2_ac_bot_simulator
```

## İlk test

TF2 botlarını ekledikten sonra:

```text
sm_acsimbot @bots on
sm_acsimtrigger @bots snap
sm_acsimtrigger @bots wall
sm_acsimstatus
sm_acdetstatus
```

Tüm simülasyonu kapat:

```text
sm_acsimalloff
```

Dedektör skorlarını temizle:

```text
sm_acdetreset @bots
```

## Skorlar

- `snap_hit`: +45
- `wall_lock`: +60
- `fast_switch`: +30
- `WOULD-BAN`: 100

Bir `wall_lock` + bir `snap_hit` = 105 puan. Bu yalnızca shadow kararıdır; oyuncu/bot kick veya ban edilmez.

## Loglar

Ground-truth:

```text
tf/addons/sourcemod/logs/tf2_ac_sim_groundtruth.log
```

Bağımsız dedektör:

```text
tf/addons/sourcemod/logs/tf2_ac_shadow_detector.log
```

Simülatör `synthetic=1`, dedektör `observed=1` yazar. Dedektör ground-truth dosyasını okumaz; iki log test sonrasında karşılaştırılır.

## Kalibrasyon güvenliği

Varsayılan:

```text
sm_acdet_bots_only "1"
```

Bu modda gerçek oyuncular skorlanmaz. Shadow gözlem için tüm oyuncuları geçici olarak açmak istersen:

```text
sm_acdetmode all
```

Gerçek ban yine uygulanmaz. Güvenli moda dönmek için:

```text
sm_acdetmode bots
```

## Kapsam

Bu proje VAC testi değildir. VAC banı üretmez ve VAC'e özel bir raporlama/ban API'sine bağlanmaz. Amaç, topluluk sunucusundaki davranış tabanlı tespit ve moderasyon hattını kontrollü bot telemetrisiyle kalibre etmektir.
