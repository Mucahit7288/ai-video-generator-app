"""
Hikaye-Video Üreticisi — Flask Backend
=======================================
Kullanıcıdan gelen fikri sırasıyla şu aşamalardan geçirir:
  1. YZ Hikaye Üretimi  → Gemini ile Türkçe kısa hikaye
  2. YZ Görsel Üretimi  → Pollinations.ai ile 3 sahne görseli
  3. YZ Ses Üretimi     → gTTS ile Türkçe MP3 seslendirme
  4. Video Birleştirme  → MoviePy ile output.mp4
"""

import os
import re
import uuid
import logging
import requests

from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS
from gtts import gTTS
import google.generativeai as genai
from moviepy import ImageClip, AudioFileClip, concatenate_videoclips

# ─────────────────────────────────────────────
# YAPILANDIRMA
# ─────────────────────────────────────────────

# Buraya Google AI Studio'dan aldığınız yeni Gemini API anahtarını girin.
# Flutter tarafı bu anahtarı hiç görmez; tüm YZ çağrıları sunucu üzerinden yapılır.
GEMINI_API_KEY = "BURAYA_KENDI_API_ANAHTARINIZI_GIRIN"

# Üretilen geçici dosyalar ve nihai video bu klasöre kaydedilir.
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
os.makedirs(STATIC_DIR, exist_ok=True)

# Görseller için geçici çalışma klasörü
TEMP_DIR = os.path.join(os.path.dirname(__file__), "temp")
os.makedirs(TEMP_DIR, exist_ok=True)

# Video çözünürlüğü (16:9)
VIDEO_WIDTH = 1280
VIDEO_HEIGHT = 720

# Pollinations görsel boyutları
IMG_WIDTH = 1280
IMG_HEIGHT = 720

# ─────────────────────────────────────────────
# UYGULAMA BAŞLATMA
# ─────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

app = Flask(__name__, static_folder=STATIC_DIR)
CORS(app)  # Flutter'dan gelen çapraz kaynak isteklerine izin ver

genai.configure(api_key=GEMINI_API_KEY)


# ─────────────────────────────────────────────
# YARDIMCI FONKSİYONLAR
# ─────────────────────────────────────────────

def _yz_hikaye_uret(kullanici_fikri: str) -> dict[str, str]:
    """
    Gemini kullanarak kullanıcının fikrini Türkçe kısa bir hikayeye dönüştürür.
    Döndürür: {'baslik': str, 'hikaye': str}
    """
    log.info("Aşama 1 → YZ hikaye üretimi başlıyor…")

    sistem_talimati = (
        "Sen yaratıcı bir Türkçe hikaye yazarısın. "
        "Kullanıcının verdiği fikirden yola çıkarak kısa, etkileyici ve görsel açıdan zengin bir hikaye yaz.\n\n"
        "ÇIKTI FORMATI — Bu kurallara kesinlikle uy:\n"
        "1. İlk satır: BAŞLIK: [hikayenin başlığı]\n"
        "2. İkinci satır: HİKAYE: [hikayenin tamamı]\n"
        "3. Hikaye en az 3, en fazla 6 paragraf olsun.\n"
        "4. Her paragrafı net bir sahne gibi yaz; görsel açıdan tasvir edilebilir olsun.\n"
        "5. Bu iki satırın dışında hiçbir açıklama, selamlama veya ek metin yazma.\n\n"
        "ÖRNEK:\n"
        "BAŞLIK: Yıldızların Altında\n"
        "HİKAYE: O gece gökyüzü hiç bu kadar net olmamıştı…"
    )

    model = genai.GenerativeModel(
        model_name="gemini-2.5-flash",
        system_instruction=sistem_talimati,
    )

    yanit = model.generate_content(kullanici_fikri)
    ham_metin = yanit.text.strip()

    log.info("Gemini yanıtı alındı, ayrıştırılıyor…")
    return _yaniti_ayristir(ham_metin)


def _yaniti_ayristir(ham_metin: str) -> dict[str, str]:
    """
    Gemini'den gelen ham metni BAŞLIK / HİKAYE bölümlerine ayırır.
    Format ne kadar esnek olursa olsun güvenli şekilde çalışır.
    """
    baslik_eslesmesi = re.search(
        r"BAŞLIK\s*:\s*(.+?)(?=\nHİKAYE\s*:|\r\nHİKAYE\s*:)",
        ham_metin,
        re.DOTALL | re.IGNORECASE,
    )
    hikaye_eslesmesi = re.search(
        r"HİKAYE\s*:\s*([\s\S]+)",
        ham_metin,
        re.IGNORECASE,
    )

    if baslik_eslesmesi and hikaye_eslesmesi:
        baslik = baslik_eslesmesi.group(1).strip()
        hikaye = hikaye_eslesmesi.group(1).strip()
    else:
        # Etiket yoksa: ilk satır → başlık, geri kalan → hikaye
        satirlar = [s.strip() for s in ham_metin.split("\n") if s.strip()]
        baslik = _kisalt_baslik(satirlar[0]) if satirlar else "İsimsiz Hikaye"
        hikaye = "\n\n".join(satirlar[1:]) if len(satirlar) > 1 else ham_metin

    return {
        "baslik": baslik or "İsimsiz Hikaye",
        "hikaye": hikaye or ham_metin,
    }


def _kisalt_baslik(metin: str, maks_kelime: int = 5) -> str:
    """Başlığı en fazla maks_kelime kelimeyle kırpar."""
    kelimeler = metin.split()
    if len(kelimeler) <= maks_kelime:
        return metin
    return " ".join(kelimeler[:maks_kelime]) + "…"


def _sahne_tasvirleri_cikar(hikaye_metni: str) -> list[str]:
    """
    Hikaye metnini paragraflara bölerek her paragraftan
    Pollinations API için İngilizce görsel tasviri üretir.
    Gemini bu dönüşümü de yapar; 3 tasvir döndürür.
    """
    log.info("Aşama 2a → Sahne tasvirleri çıkarılıyor…")

    sistem = (
        "You are a visual art director. "
        "Given a Turkish story, extract exactly 3 scene descriptions in English "
        "suitable as image generation prompts. "
        "Each description must be vivid, cinematic, and 10–20 words long. "
        "Respond ONLY with a JSON array of 3 strings, nothing else. "
        'Example: ["A lone astronaut floating in deep space, stars glowing", '
        '"An ancient forest bathed in golden light", '
        '"A futuristic city at night, neon reflections on wet streets"]'
    )

    model = genai.GenerativeModel(
        model_name="gemini-2.5-flash",
        system_instruction=sistem,
    )

    yanit = model.generate_content(hikaye_metni)
    ham = yanit.text.strip()

    # JSON dizisini güvenle ayrıştır
    json_eslesmesi = re.search(r"\[.*?\]", ham, re.DOTALL)
    if json_eslesmesi:
        import json
        try:
            tasvirler = json.loads(json_eslesmesi.group())
            if isinstance(tasvirler, list) and len(tasvirler) >= 3:
                return [str(t) for t in tasvirler[:3]]
        except json.JSONDecodeError:
            pass

    # Yedek: metni satırlara böl
    log.warning("JSON ayrıştırma başarısız, satır bazlı yedek kullanılıyor.")
    satirlar = [s.strip().strip('"') for s in ham.split("\n") if s.strip()]
    tasvirler = satirlar[:3]
    while len(tasvirler) < 3:
        tasvirler.append("Beautiful cinematic landscape with warm natural lighting")
    return tasvirler


def _gorsel_indir(tasvir: str, dosya_yolu: str) -> bool:
    """
    Pollinations.ai API'sinden bir görsel indirir.
    Başarılıysa True, değilse False döndürür.
    """
    # Tasviri URL güvenli hale getir
    temiz_tasvir = re.sub(r"[^a-zA-Z0-9 ,._-]", "", tasvir)
    temiz_tasvir = temiz_tasvir.replace(" ", "%20")

    url = (
        f"https://image.pollinations.ai/prompt/{temiz_tasvir}"
        f"?width={IMG_WIDTH}&height={IMG_HEIGHT}&nologo=true&model=flux"
    )

    try:
        log.info(f"  Görsel indiriliyor: {url[:80]}…")
        yanit = requests.get(url, timeout=60)
        yanit.raise_for_status()

        with open(dosya_yolu, "wb") as f:
            f.write(yanit.content)

        dosya_boyutu = os.path.getsize(dosya_yolu)
        log.info(f"  ✓ Görsel kaydedildi ({dosya_boyutu // 1024} KB): {dosya_yolu}")
        return True

    except requests.RequestException as e:
        log.error(f"  ✗ Görsel indirme hatası: {e}")
        return False


def _ses_uret(hikaye_metni: str, ses_yolu: str) -> None:
    """
    gTTS ile hikaye metnini Türkçe MP3 ses dosyasına dönüştürür.
    """
    log.info("Aşama 3 → YZ ses seslendirmesi üretiliyor…")
    tts = gTTS(text=hikaye_metni, lang="tr", slow=False)
    tts.save(ses_yolu)
    log.info(f"  ✓ Ses dosyası kaydedildi: {ses_yolu}")


def _video_birlestir(
    gorsel_yollari: list[str],
    ses_yolu: str,
    cikti_yolu: str,
) -> None:
    """
    3 görseli ses dosyasının toplam süresi boyunca eşit aralıklarla
    sırayla göstererek MP4 video dosyası oluşturur.
    """
    log.info("Aşama 4 → Video birleştirme başlıyor…")

    ses_klibi = AudioFileClip(ses_yolu)
    toplam_sure = ses_klibi.duration
    gorsel_sure = toplam_sure / len(gorsel_yollari)

    log.info(
        f"  Ses süresi: {toplam_sure:.1f}s | "
        f"Görsel başına süre: {gorsel_sure:.1f}s"
    )

    klip_listesi = []
    for i, gorsel_yolu in enumerate(gorsel_yollari):
        # Yeni MoviePy v2.x sürümüyle uyumlu yapı
        gorsel_klibi = (
            ImageClip(gorsel_yolu)
            .with_duration(gorsel_sure)
            .resized((VIDEO_WIDTH, VIDEO_HEIGHT))
        )
        klip_listesi.append(gorsel_klibi)
        log.info(f"  Görsel {i + 1} klibe eklendi: {gorsel_yolu}")

    birlesik_video = concatenate_videoclips(klip_listesi, method="compose")
    birlesik_video = birlesik_video.with_audio(ses_klibi)

    birlesik_video.write_videofile(
        cikti_yolu,
        fps=24,
        codec="libx264",
        audio_codec="aac",
        temp_audiofile=os.path.join(TEMP_DIR, "temp_audio.m4a"),
        remove_temp=True,
        logger=None,  # MoviePy'nin kendi loglarını sustur
    )

    # Belleği serbest bırak
    ses_klibi.close()
    birlesik_video.close()

    log.info(f"  ✓ Video oluşturuldu: {cikti_yolu}")


def _gecici_dosyalari_temizle(*dosya_yollari: str) -> None:
    """Geçici ses ve görsel dosyalarını siler."""
    for yol in dosya_yollari:
        try:
            if os.path.exists(yol):
                os.remove(yol)
        except OSError as e:
            log.warning(f"Geçici dosya silinemedi ({yol}): {e}")


# ─────────────────────────────────────────────
# ENDPOINT'LER
# ─────────────────────────────────────────────

@app.route("/generate-video", methods=["POST"])
def generate_video():
    """
    Ana üretim endpoint'i.

    İstek gövdesi (JSON):
        { "user_prompt": "Uzayda kaybolan bir astronot" }

    Başarılı yanıt (JSON):
        {
            "success": true,
            "baslik":  "Hikaeynin Başlığı",
            "hikaye":  "Hikayenin tam metni…",
            "video_url": "http://localhost:5000/static/output_<uuid>.mp4"
        }
    """
    # ── İstek doğrulama ──────────────────────────────────────
    veri = request.get_json(silent=True)
    if not veri or not veri.get("user_prompt", "").strip():
        return jsonify({
            "success": False,
            "hata": "Lütfen 'user_prompt' alanını doldurun.",
        }), 400

    kullanici_fikri = veri["user_prompt"].strip()
    log.info(f"Yeni istek alındı → '{kullanici_fikri[:60]}…'")

    # Her istek için benzersiz ID; paralel isteklerde çakışmayı önler
    istek_id = uuid.uuid4().hex[:8]

    gorsel_yollari = []
    ses_yolu = os.path.join(TEMP_DIR, f"ses_{istek_id}.mp3")
    video_adi = f"output_{istek_id}.mp4"
    video_yolu = os.path.join(STATIC_DIR, video_adi)

    try:
        # ── Aşama 1: YZ Hikaye Üretimi ───────────────────────
        sonuc = _yz_hikaye_uret(kullanici_fikri)
        baslik = sonuc["baslik"]
        hikaye = sonuc["hikaye"]
        log.info(f"  Başlık: '{baslik}'")

        # ── Aşama 2: YZ Görsel Üretimi ───────────────────────
        log.info("Aşama 2 → YZ görsel üretimi başlıyor…")
        tasvirler = _sahne_tasvirleri_cikar(hikaye)

        for i, tasvir in enumerate(tasvirler):
            gorsel_yolu = os.path.join(TEMP_DIR, f"gorsel_{istek_id}_{i}.jpg")
            gorsel_yollari.append(gorsel_yolu)
            basarili = _gorsel_indir(tasvir, gorsel_yolu)
            if not basarili:
                # İndirme başarısız olursa tek renkli yedek görsel oluştur
                log.warning(f"  Görsel {i + 1} indirilemedi; yedek görsel oluşturuluyor.")
                _yedek_gorsel_olustur(gorsel_yolu)

        # ── Aşama 3: YZ Ses Üretimi ──────────────────────────
        _ses_uret(hikaye, ses_yolu)

        # ── Aşama 4: Video Birleştirme ────────────────────────
        _video_birlestir(gorsel_yollari, ses_yolu, video_yolu)

        # ── Yanıt ────────────────────────────────────────────
        video_url = f"{request.host_url}static/{video_adi}"
        log.info(f"✓ Tüm aşamalar tamamlandı. Video URL: {video_url}")

        return jsonify({
            "success": True,
            "baslik": baslik,
            "hikaye": hikaye,
            "video_url": video_url,
        })

    except Exception as e:
        log.exception(f"✗ Kritik hata: {e}")
        return jsonify({
            "success": False,
            "hata": f"Sunucu tarafında bir hata oluştu: {str(e)}",
        }), 500

    finally:
        # Geçici dosyaları her durumda temizle
        _gecici_dosyalari_temizle(ses_yolu, *gorsel_yollari)


@app.route("/static/<path:dosya_adi>")
def statik_dosya_sun(dosya_adi: str):
    """Üretilen MP4 videoyu dışarıya sunar."""
    return send_from_directory(STATIC_DIR, dosya_adi)


@app.route("/saglik", methods=["GET"])
def saglik_kontrolu():
    """Flutter veya monitoring araçlarının sunucunun ayakta olup olmadığını kontrol etmesi için."""
    return jsonify({"durum": "çalışıyor", "mesaj": "YZ Video Üreticisi hazır."}), 200


# ─────────────────────────────────────────────
# YARDIMCI — YEDEK GÖRSEL
# ─────────────────────────────────────────────

def _yedek_gorsel_olustur(dosya_yolu: str) -> None:
    """
    Pollinations API başarısız olursa NumPy/Pillow ile koyu gradyan bir
    yedek görsel oluşturur. Pillow yoksa basit JPEG baytları yazar.
    """
    try:
        from PIL import Image, ImageDraw
        import numpy as np

        goruntu = np.zeros((VIDEO_HEIGHT, VIDEO_WIDTH, 3), dtype=np.uint8)
        # Koyu mor → lacivert gradyan
        for x in range(VIDEO_WIDTH):
            oran = x / VIDEO_WIDTH
            goruntu[:, x] = [
                int(30 * (1 - oran)),   # R
                int(10 * (1 - oran)),   # G
                int(60 + 40 * oran),    # B
            ]
        img = Image.fromarray(goruntu)
        img.save(dosya_yolu, "JPEG")
        log.info(f"  Yedek görsel oluşturuldu: {dosya_yolu}")

    except ImportError:
        # Pillow yoksa 1×1 piksel geçerli JPEG yaz (MoviePy yeniden boyutlandırır)
        log.warning("  Pillow bulunamadı; minimal JPEG yedek yazılıyor.")
        minimal_jpeg = bytes([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00,
            0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB,
            0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07,
            0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B,
            0x0B, 0x0C, 0x19, 0x12, 0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E,
            0x1D, 0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C,
            0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34,
            0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34,
            0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01,
            0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05,
            0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01,
            0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00,
            0x01, 0x7D, 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21,
            0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32,
            0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1,
            0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18,
            0x19, 0x1A, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35, 0x36,
            0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64,
            0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77,
            0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A,
            0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
            0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5,
            0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7,
            0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9,
            0xDA, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
            0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF,
            0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD3,
            0xFF, 0xD9,
        ])
        with open(dosya_yolu, "wb") as f:
            f.write(minimal_jpeg)


# ─────────────────────────────────────────────
# GİRİŞ NOKTASI
# ─────────────────────────────────────────────

if __name__ == "__main__":
    log.info("=" * 55)
    log.info("  YZ Video Üreticisi — Flask Sunucusu Başlatılıyor")
    log.info("  Sağlık kontrolü: http://localhost:5000/saglik")
    log.info("  Video endpoint : POST http://localhost:5000/generate-video")
    log.info("=" * 55)
    app.run(host="0.0.0.0", port=5000, debug=False)