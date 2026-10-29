/*
 * Konfigurasi ProktorLab
 * ----------------------
 * Isi apiUrl dengan URL Aplikasi Web Google Apps Script (berakhiran /exec)
 * agar semua perangkat (HP proktor, laptop, TV layar ujian) langsung terhubung.
 *
 * Jika dibiarkan kosong, panel akan meminta URL saat pertama kali dibuka
 * dan menyimpannya di browser perangkat tersebut.
 *
 * Contoh:
 *   apiUrl: 'https://script.google.com/macros/s/AKfycbx.../exec'
 */
window.PROKTORLAB_CONFIG = {
  apiUrl: 'https://script.google.com/macros/s/AKfycby5uGjA9GbeDO7HNKObQ5VksapZ6xkYzmo2A64lhtN-q6w8MgvGjfFs7vyY5Bf6G3La/exec'
};
