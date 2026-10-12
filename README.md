# Planner Nikah

Web app perencanaan pernikahan untuk dua orang: vendor (link IG & WhatsApp), tabungan bersama dengan kantong dana, daftar tamu & undangan WA, seserahan & mahar, checklist berkas KUA, dan tugas persiapan.

- Login email + password (Supabase Auth)
- Satu akun bisa mengundang satu pasangan lewat kode undangan
- Data hanya bisa dibuka oleh dua akun yang terhubung (Row Level Security)
- Perubahan tersinkron langsung antar perangkat (Supabase Realtime)

## Struktur

| File | Isi |
|---|---|
| `index.html` | Seluruh aplikasi (HTML, CSS, JS) |
| `config.js` | Alamat proyek Supabase & publishable key |
| `supabase/schema.sql` | Tabel, aturan akses, dan fungsi database |

## Hosting

Situs statis via GitHub Pages: Settings → Pages → Deploy from a branch → `main` / `(root)`.

Di Supabase → Authentication → URL Configuration, isi Site URL dan Redirect URL dengan alamat GitHub Pages (`https://<user>.github.io/planner-nikah/**`).
