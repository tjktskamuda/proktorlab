# ProktorLab

Panel proktor untuk lab komputer ujian: **buka dan tutup Exam Browser di semua komputer sekaligus**, tanpa mondar-mandir. Dilengkapi Wake on LAN, shutdown/restart serentak, kirim pesan ke layar siswa, dan **Layar Ujian** hitung mundur untuk TV.

| Bagian | Teknologi | Lokasi |
|---|---|---|
| Frontend (panel + layar TV) | HTML/JS statis | GitHub Pages: `https://tjktskamuda.github.io/proktorlab/` |
| Backend (API) | Google Apps Script | `apps-script/Code.gs`, `apps-script/Agen.gs` |
| Database | Google Sheets | Spreadsheet tempat Apps Script dipasang |
| Agen komputer lab | PowerShell (Windows 10/11) | `agent/` (otomatis diunduh dari backend) |

Coba dulu tanpa memasang apa pun: buka panel lalu pilih **Coba mode demo**, atau langsung `https://tjktskamuda.github.io/proktorlab/?demo=1`.

---

## Cara kerja

```
 HP/laptop proktor ──► GitHub Pages (index.html) ──► Apps Script /exec ──► Google Sheet
                                                         ▲
 TV lab ─────────────► GitHub Pages (layar.html) ────────┤
                                                         │ lapor tiap 10 detik,
 PC lab A-01 … C-07 ── agen PowerShell (SYSTEM) ─────────┘ ambil perintah antrean
```

1. Agen di tiap komputer berjalan otomatis sebagai tugas terjadwal Windows (akun SYSTEM) dan melapor ke backend setiap ±10 detik.
2. Saat proktor menjalankan skrip (misalnya **#Run ExamBrowser**), backend menaruh perintah di antrean komputer tujuan. Agen mengambilnya pada laporan berikutnya.
3. Untuk jadwal **Pada waktu tertentu**, agen menerima perintah lebih awal lalu menjalankannya tepat pada jamnya, jadi semua komputer serentak.
4. Exam Browser dibuka di akun Windows yang sedang login. Hasil tiap komputer (Berhasil / Gagal / Kedaluwarsa) tampil di menu **Riwayat**.

## Struktur repo

```
index.html            Panel proktor (frontend)
layar.html            Layar Ujian hitung mundur untuk TV
config.js             Alamat backend (opsional, lihat langkah 3)
apps-script/
  Code.gs             Backend: API panel, antrean perintah, login admin
  Agen.gs             Kode agen PowerShell dalam bentuk teks (dibuat otomatis)
  appsscript.json     Manifest Apps Script (opsional)
agent/
  agent.ps1           Sumber agen komputer lab
  install.ps1         Pemasang agen
  uninstall.ps1       Penghapus agen
tools/
  make_agen.py        Membuat ulang apps-script/Agen.gs dari folder agent/
  gasmock.js          Emulator Apps Script untuk uji coba lokal
```

---

## Pemasangan

### 1. Backend + database (Google Apps Script + Google Sheet)

1. Buka **https://sheets.new**, beri nama spreadsheet **ProktorLab**.
2. Menu **Ekstensi → Apps Script**. Ganti nama proyek menjadi **ProktorLab**.
3. Hapus isi `Code.gs`, lalu tempel isi [`apps-script/Code.gs`](apps-script/Code.gs).
4. Klik **+** di samping *File* → **Skrip** → beri nama `Agen`, lalu tempel isi [`apps-script/Agen.gs`](apps-script/Agen.gs).
   Cara cepat: buka panel → menu **Panduan & Kode** → tombol **Salin** di tiap file.
5. Simpan (Ctrl+S). Pilih fungsi **setup** di toolbar → **Jalankan** → izinkan akses (Tinjau izin → Lanjutan → Buka ProktorLab → Izinkan).
6. **Terapkan → Deployment baru** → ikon roda gigi → **Aplikasi web**:
   - *Jalankan sebagai*: **Saya**
   - *Yang memiliki akses*: **Siapa saja**
7. Klik **Terapkan**, salin **URL aplikasi web** (berakhiran `/exec`).

> Jika pilihan **Siapa saja** tidak ada (akun belajar.id atau akun sekolah yang dibatasi admin), pasang backend memakai akun Gmail pribadi. Komputer lab dan TV harus bisa menghubungi backend tanpa login Google.

Sheet `Endpoint`, `Otomasi`, dan `Hasil` dibuat otomatis di spreadsheet.

### 2. Frontend (GitHub Pages)

Sudah aktif di **https://tjktskamuda.github.io/proktorlab/**. Saat pertama dibuka, panel meminta **URL backend**: tempel URL `/exec` dari langkah 1, lalu buat **kata sandi admin**.

### 3. (Disarankan) Simpan URL backend di `config.js`

Agar HP proktor lain dan TV langsung terhubung tanpa menempel URL, edit [`config.js`](config.js) di GitHub (ikon pensil) dan isi:

```js
window.PROKTORLAB_CONFIG = {
  apiUrl: 'https://script.google.com/macros/s/AKfycb.../exec'
};
```

Commit, tunggu ±1 menit sampai GitHub Pages diperbarui.

### 4. Pasang agen di setiap komputer lab

Di panel buka menu **Pasang Agen**, pilih grup (misalnya *Lab TJKT 1*), lalu di tiap komputer:

1. Klik kanan **Start** → **Terminal (Admin)** / **Windows PowerShell (Admin)**.
2. Tempel perintah dari panel, tekan Enter, tunggu tulisan hijau **BERHASIL**.

Atau unduh **pasang-agen.bat** dari menu yang sama, simpan di flashdisk, lalu klik dua kali di tiap komputer.

Komputer muncul di menu **Endpoint** dalam ±10 detik. Pemasang juga mematikan *Fast Startup* dan mengaktifkan *Wake on Magic Packet* agar **#Power ON** bisa dipakai.

### 5. Atur lokasi Exam Browser

Menu **Pustaka Skrip → Konfigurasi Exam Browser**. Pilih preset (Safe Exam Browser, Chrome/Edge mode kiosk) atau isi sendiri:

- **Lokasi file .exe**: boleh lebih dari satu, **satu lokasi per baris**. Agen mencoba dari atas ke bawah. Cara mencari: klik kanan shortcut Exam Browser → Properties → salin isi kolom *Target*.
- **Cari otomatis** (aktif bawaan): jika semua lokasi tidak ada di sebuah komputer, agen mencari sendiri lewat registri, shortcut di Desktop/Start Menu, Program Files, folder pengguna, dan drive lain (D:, E:). Hasilnya diingat agar tidak mencari ulang.
- **Nama proses**: lihat di Task Manager → tab Details (boleh pakai `*`, pisahkan dengan koma).

**Saat Exam Browser dibuka** (bagian bawah formulir yang sama):

- **Jalankan sebagai Administrator**: Exam Browser dibuka lewat Task Scheduler dengan hak tertinggi, sehingga jendela UAC *"Do you want to allow this app from an unknown publisher…"* (misalnya untuk `runningexam.exe` di Exambrowser ANBK) tidak muncul. Akun Windows siswa harus anggota grup Administrators. Jendela UAC sengaja dibuat Windows agar tidak bisa diklik oleh program apa pun, jadi inilah cara resmi melewatinya.
- **Klik otomatis**: agen menjalankan `autopilot.ps1` di akun siswa yang memantau jendela milik Exam Browser dan mengklik tombolnya sesuai aturan, sampai aplikasi ujian terbuka. Aturan bawaan (Exambrowser ANBK):

  ```
  * > OK/Oke                      peringatan "Anda tidak memiliki akses internet… autoupdate"
  Exambrowser Client > RUN        tombol RUN di jendela DARING
  Persetujuan* > Yes/Ya           "Persetujuan Merekam Aktifitas Saat Ujian"
  ```

  Format: `Judul jendela > Tombol`, `*` = jendela Exam Browser mana saja, `/` memisahkan pilihan tombol, baris diawali `#` diabaikan. Setiap tombol diklik sekali per jendela. Hapus baris *Persetujuan* jika sekolah ingin siswa menyetujui perekaman sendiri. Log klik disimpan di `C:\ProgramData\ProktorLab\run\PL-klik-*.log` dan ikut ditampilkan di Riwayat bila pembukaan gagal.

**Cara agen membuka Exam Browser (v1.5.0):** klik otomatis disiapkan lebih dulu, lalu Exam Browser dibuka terpisah di akun siswa (folder kerja = folder Exam Browser, prioritas normal), jadi Exam Browser tetap terbuka walaupun klik otomatis bermasalah. Bila *Jalankan sebagai Administrator* aktif, file .exe dijalankan **langsung oleh Task Scheduler** dengan hak tertinggi; jika Windows menolaknya (misalnya akun bukan Administrator), agen mengulang lewat shell Windows seperti klik dua kali. Tanpa opsi itu, Exam Browser dibuka lewat shell Windows. Agen menunggu hingga 25 detik; jika Exam Browser tidak terlihat berjalan, status di Riwayat menjadi **Gagal** beserta penyebabnya (kode Windows, log klik otomatis), bukan *Berhasil* palsu.

**Saat Exam Browser ditutup** (#Close ExamBrowser):

- Agen menekan **shortcut keluar** Exam Browser di komputer siswa, sama seperti menutup manual dengan keyboard. Bawaan: `Ctrl+C+B+L`, lalu `Ctrl+C+B` (satu per baris, dicoba berurutan). Konfirmasi Yes/OK yang muncul diklik otomatis.
- Jika Exam Browser tetap terbuka, prosesnya dihentikan paksa, lalu Explorer (taskbar) dinyalakan lagi bila ikut mati.
- Status **Exam Browser: Berjalan** dihitung dari *Nama proses* **dan** semua program yang berjalan dari **folder instalasi Exam Browser** (folder file .exe yang dipakai), jadi `runningexam.exe` ikut terdeteksi walaupun Exam Browser dibuka manual oleh siswa. Detail komputer menampilkan *Proses Exam* yang sedang terdeteksi; jalankan **#Cek Proses** untuk melihat semua program yang berjalan.
- Agen **mempelajari sendiri** nama proses yang dibuat Exam Browser (misalnya `runningexam.exe` pada Exambrowser ANBK) agar status *Berjalan* dan #Close ExamBrowser tetap mengenalinya. Tombol **Pakai contoh Exambrowser ANBK** juga menambahkan `runningexam*,exambro*` ke *Nama proses*.

**Jika ada komputer yang lokasi Exam Browser-nya berbeda:**

1. Lihat kolom **Lokasi Exam** di menu **Endpoint**: *Siap*, *Siap · otomatis* (ditemukan lewat pencarian), atau **Tidak ditemukan**. Dashboard juga menampilkan peringatan berisi daftar komputer yang bermasalah.
2. Centang komputer tersebut → **Atur Endpoint → Atur lokasi Exam Browser…**, isi lokasi file .exe di komputer itu, lalu **Simpan**. Bisa juga lewat klik nama komputer → *Lokasi Exam Browser khusus komputer ini*.
3. Agen memeriksa ulang dalam beberapa detik dan statusnya berubah menjadi **Siap**.

Urutan yang dicoba agen: lokasi khusus komputer itu → daftar lokasi umum → pencarian otomatis. Lokasi khusus disimpan di kolom *Lokasi Exam Khusus* pada sheet `Endpoint`.

---

## Pemakaian

- **Dashboard → Aksi cepat ujian**: Buka/Tutup Exam Browser, Nyalakan (WOL), Matikan, untuk semua komputer atau satu grup.
- **Endpoint**: centang komputer → Buka/Tutup Exam Browser, Reboot, Jalankan Skrip, atur grup & keterangan.
- **Jalankan Skrip** (3 langkah): pilih skrip → pilih endpoint → jadwal (*Sekarang* atau *Pada waktu tertentu*) + batas waktu penyelesaian.
- **Riwayat**: status per komputer, batalkan yang belum jalan, ulangi yang gagal.
- **Layar Ujian**: atur label, nama sekolah, sesi, token, jam mulai/selesai, lalu buka layarnya di browser TV (tekan F11 untuk layar penuh). Tombol *Jadwalkan #Run ExamBrowser saat mulai* membuat Exam Browser terbuka otomatis tepat saat hitung mundur habis.

### Skrip yang tersedia

| Skrip | Fungsi |
|---|---|
| #Run ExamBrowser | Membuka Exam Browser di akun yang sedang login |
| #Close ExamBrowser | Menutup Exam Browser dengan shortcut keluarnya, cadangan: hentikan paksa |
| #Power ON (Wake On Lan) | Menyalakan komputer yang mati lewat komputer lain yang online |
| #Shutdown / #Restart | `shutdown.exe /s` atau `/r /f /t 5` |
| #Log Off / #Kunci Layar | Keluar dari akun / kunci layar |
| #Kirim Pesan | Pop-up pesan di layar siswa |
| #Buka Situs | Membuka URL di browser bawaan |
| #Perbarui Agen | Mengunduh ulang agen terbaru dari backend |
| #Cek Proses | Daftar program yang berjalan di komputer siswa; yang dikenali sebagai Exam Browser bertanda `[EXAM]` |

Demi keamanan, panel hanya bisa menjalankan skrip di atas (tidak ada skrip bebas), sehingga link panel yang bocor tidak bisa dipakai menjalankan perintah sembarangan di komputer lab.

### Wake on LAN

- Aktifkan **Wake on LAN** / *Power On by PCI-E* di BIOS tiap komputer.
- Sinyal dikirim oleh komputer lain yang sedang online di jaringan yang sama. Pasang juga agen di **PC proktor** agar selalu ada pengirim.

---

## Memperbarui

- **Frontend**: edit file di repo ini, GitHub Pages memperbarui otomatis.
- **Backend**: tempel kode baru di Apps Script, simpan, lalu **Terapkan → Kelola deployment → ikon pensil → Versi baru → Terapkan**. URL tetap sama, agen tidak perlu dipasang ulang.
- **Agen**: setelah backend diperbarui, jalankan skrip **#Perbarui Agen** ke semua endpoint. Dashboard menampilkan peringatan berisi daftar komputer yang agennya lebih lama dari agen yang tersedia di backend (`$AgentVersion` di Agen.gs). Pembaruan yang hanya mengubah backend/panel tidak memunculkan peringatan ini.
- Jika mengubah file di `agent/`, buat ulang `apps-script/Agen.gs` dengan `python3 tools/make_agen.py`.

## Mencopot agen

Jalankan perintah *Mencopot agen* dari menu **Pasang Agen** di PowerShell (Admin) komputer tersebut.

## Catatan

- Laporan rutin agen hanya membaca cache Apps Script agar hemat kuota. Jika memasang agen di banyak lab sekaligus dan muncul pesan kuota, naikkan interval di **Pengaturan** menjadi 15–20 detik.
- *Sekarang* berarti tiap komputer menjalankan perintah pada laporan berikutnya (selisih hingga ±10 detik). Pakai *Pada waktu tertentu* untuk start yang benar-benar serentak.
- Data login admin disimpan sebagai hash di Script Properties; sesi login berlaku 6 jam sejak aktivitas terakhir.
- Google Sheets berlokal Indonesia mengubah teks secara otomatis (`1.5.0` menjadi tanggal 1 Mei 2000, `192.168.100.255` menjadi angka karena titik dianggap pemisah ribuan). Karena itu kolom teks sheet `Endpoint` (A–J dan M) disimpan berformat *teks biasa*, dan data lama yang telanjur berubah diperbaiki otomatis oleh backend v1.5.1.

## Uji coba lokal

```bash
node tools/gasmock.js 8787          # backend palsu di http://127.0.0.1:8787/exec
python3 -m http.server 8790         # buka http://localhost:8790/ lalu hubungkan ke URL di atas
```
