# johorstudio-class-processor

App Mac (Apple Silicon, macOS 14+) untuk proses gambar kelas. Stail dan cara build sama dengan [johorstudio-custom-booth](https://github.com/RafieRosliputra/johorstudio-custom-booth). Ditulis dalam Swift + SwiftUI. Teks nama kelas dikemas kini melalui **Adobe Photoshop 2026**, dan WebP untuk phone dibuat guna libwebp (dah di-bundle).

## Cara build

Sama macam app booth. Sekali sahaja: `xcode-select --install`.

```bash
cd ~/Desktop
git clone https://github.com/RafieRosliputra/johorstudio-class-processor.git
cd johorstudio-class-processor
./scripts/build_app.sh
```
Atau double-click **`build.command`** dalam Finder. App siap ada dalam folder `build`: **`JohorStudio-Class-Processor.app`**.
Untuk update: `git pull`, kemudian build semula.

## Struktur folder (root)

Letak app dalam folder event. Folder tu dikira **root**.

```
Desktop/2026 SMK Kulai Besar Class Photo/     ← root
  JohorStudio-Class-Processor.app
  settings.json          ← semua setting, termasuk saiz & kedudukan foto (auto)
  adb-sent.json          ← nama fail yang dah dihantar ke phone (auto)
  LIVEFOLDER/            ← JPG dari kamera (Directory boleh tukar)
    DONE/                ← fail asal lepas PROCESS: "TINGKATAN 1C - 1.jpg"…
    WEBP/                ← WebP saiz penuh (quality 50) yang dihantar ke phone
  PRINTS/                ← hasil 1800×1200 JPG: "TINGKATAN 1C - 1.jpg"…
  log/2026-10-19.log     ← semua log
  cache/classname.png    ← teks nama kelas dari Photoshop
```

## Tab PRINT

- **Directory**: pilih LIVEFOLDER (default `root/LIVEFOLDER`).
- **HOTFOLDER**: folder hotfolder printer. Disimpan dalam settings.
- **Load Photo**: pilih gambar pertama. App ambil 5 gambar seterusnya ikut **nama fail**. Kalau tak cukup 6, tiada apa yang di-load.
  - Gambar besar = gambar 1 (main). Kotak kecil = gambar 2–6.
  - Preview guna snapshot ~2000px supaya laju. PROCESS guna fail asal 42MP.
- **Master File (overlay)**: pilih `xxxx1.webp`. App cari sendiri `xxxx2…xxxx5.webp` dalam folder sama, dan senarai yang di-load ditulis bawah butang. Kawasan foto diambil automatik dari bahagian transparent master1.
  - Ikon ⚙︎: X/Y/W/H kedudukan teks nama kelas atas master 1800×1200. Default 0/1024/1800/74, ikut `masterSort.psd`.
- **CLASS NAME**: pilih `textLayer.psb`. Kotak bawahnya untuk taip nama kelas (auto huruf besar).
  - Setiap kali app dibuka, dan setiap kali RESET, kotak dan text layer jadi **XXX** (PROCESS tak jalan dengan XXX).
  - Sebelah kotak: **saiz teks %** dan anak panah ← ↑ ↓ → untuk gerakkan teks (5px; option = 1px, shift = 20px).
  - Butang **refresh** (⟳): Photoshop tukar isi text layer sahaja, save PSB, dan export PNG transparent. Butang jadi **oren** bila teks dalam kotak belum di-refresh.
  - Kali pertama, macOS akan tanya *"JohorStudio-Class-Processor wants to control Adobe Photoshop 2026"*. Tekan **Allow**.
- **Preview besar**: **drag** untuk ubah kedudukan, **scroll** untuk ubah saiz. **scroll size %** = berapa % setiap satu scroll. **Fill** = kembali 100%, di tengah.
  - Saiz & kedudukan disimpan dalam `settings.json` dan dipakai untuk **semua** gambar masa process, termasuk set gambar seterusnya.
- **Right-click** kotak kecil: jadi **merah** = buang (tak diproses). Right-click lagi sekali untuk batal.
- **Klik** kotak kecil atau gambar besar (klik pendek, tanpa drag): buka dalam Quick Look (macam Space dalam Finder). Klik lagi / Esc untuk tutup.
  - Master ikut susunan gambar yang tak merah. Contoh: gambar 4 merah → 1, 2, 3 guna master1–3, gambar 5 guna master4, gambar 6 guna master5.
  - Kalau 6 gambar semua tak merah, PROCESS tak jalan (master cuma 5).
  - Kalau tinggal 3, proses 3 sahaja.
- **PROCESS FILES**: export JPG 1800×1200, Q95, 300 DPI, sRGB ke `PRINTS/`. Nama ikut isi text layer dan nombor master, tanpa tarikh: `TINGKATAN 1C - 1.jpg` … `- 5.jpg`. Gambar kekal dalam app.
- **Refresh nama** (bila 6 gambar loaded): 6 gambar terus dijadikan WebP bernama `TINGKATAN 1C - 1.webp` … `- 6.webp` (ikut kedudukan) dan **dihantar ke phone**. Fail kamera dalam LIVEFOLDER tak diusik. (PROCESS pun hantar kalau set tu belum dihantar dengan nama tu.)
  - Kalau fail dah ada dalam PRINTS, ia tak dieksport semula dan ditulis dalam log.
  - Kalau teks belum di-refresh, app refresh dulu secara automatik.
- **PRINT SAMPLES**: sama macam PROCESS, ditambah salin fail PRINTS ke HOTFOLDER. Tiada overwrite: kalau fail dah ada, ia dilangkau.
- **📁**: buka folder PRINTS.
- **RESET PHOTO**: kosongkan preview, tulis "no photo loaded", kotak nama kelas dan text layer jadi `XXX`.
  - Lepas refresh nama / PROCESS, butang jadi hijau (**RESET & RENAME**): fail kamera dinamakan semula `TINGKATAN 1C - 1…5.jpg` (ikut master, yang tak merah) dan yang merah `TINGKATAN 1C - xx.jpg`, kemudian dipindah ke `LIVEFOLDER/DONE/`. Isi fail tak diubah.
  - Load Photo set baru tanpa reset pun akan buat langkah ni untuk set sebelumnya dulu.
- **PURGE PRINTER** (merah): popup amaran dulu, lepas tu buang semua job dalam queue printer default (`cancel -a -x`). **Right-click** = buka queue printer (Print Center).
- Kanan atas: status adb (hijau/merah) dan jumlah JPG dalam LIVEFOLDER.

## Tab ADB

Bahagian ADB dari app *JohorStudio LiveFolder* lama. adb: `/opt/homebrew/bin/adb` (`brew install android-platform-tools`).

- **RESET SERVER**: `adb kill-server` + `adb start-server`. Turut berjalan masa app dibuka.
- **Device**: pilih phone (dari `adb devices`, disemak setiap 2 saat), **Refresh**, atau **Wireless ADB IP** + **Connect**.
  - Kalau status tulis *"press Allow on the phone"*: buka phone dan tekan **Allow USB debugging**.
  - Arahan ADB (swipe, restart gallery…) tak perlu tunggu batch WebP yang sedang dihantar.
- **START SENDING**: setiap JPG baru dalam LIVEFOLDER → WebP saiz penuh quality 50 dalam `LIVEFOLDER/WEBP/` → `adb push` ke `/sdcard/Downloads/`, **10 fail sekali**, kemudian swipe untuk refresh gallery.
  - Fail yang dah dihantar dilangkau, ikut rekod dalam `adb-sent.json`.
  - Simple Gallery Pro di-restart **setiap 2 minit** (boleh ubah).
  - **Tether mode**: buka fail terakhir dalam Simple Gallery Pro, tanpa auto restart.
- **PULL DOWN REFRESH**, **RESTART GALLERY**, **SCRCPY**.
- **FORGET SENT RECORD**: hantar semula semua.
- **CLEAR PHONE FOLDER** (merah): padam isi folder phone.

Semua pergerakan fail ditulis dalam kotak log dan dalam `root/log/`.
