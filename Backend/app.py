"""
Hikaye-Video Üreticisi — Flask Backend
=======================================
Kullanıcıdan gelen fikri sırasıyla şu aşamalardan geçirir:
  1. YZ Hikaye Üretimi  → Gemini ile Türkçe kısa hikaye
  2. YZ Görsel Üretimi  → Pollinations.ai ile 3 sahne görseli
  3. YZ Ses Üretimi     → gTTS ile Türkçe MP3 seslendirme
  4. Video Birleştirme  → MoviePy ile output.mp4
"""
import asyncio
import edge_tts
import os
import re
import uuid
import logging
import requests
import random
import shutil

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
GEMINI_API_KEY = "BURAYA-API-KEY-GELECEK"

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
    Sade ve stabil Pollinations API'sinden bir görsel indirir.
    Premium filtrelere takılmamak için prompt temizlenir ve 120 karaktere kırpılır.
    Seed kullanılarak timeout riski azaltılır.
    Başarılıysa True, değilse False döner.
    """
    # Noktalama işaretlerini ve özel karakterleri temizle (sadece harf, rakam ve boşluk kalsın)
    temiz_tasvir = re.sub(r"[^\w\s]", "", tasvir)
    
    # Maksimum 120 karaktere kırp
    temiz_tasvir = temiz_tasvir[:120].strip()
    temiz_tasvir = temiz_tasvir.replace(" ", "%20")
    
    seed = random.randint(1, 1000)
    url = f"https://image.pollinations.ai/prompt/{temiz_tasvir}?width={IMG_WIDTH}&height={IMG_HEIGHT}&nologo=true&seed={seed}"

    try:
        log.info(f"  Görsel indiriliyor: {url[:80]}…")
        yanit = requests.get(url, timeout=45)
        yanit.raise_for_status()

        with open(dosya_yolu, "wb") as f:
            f.write(yanit.content)

        dosya_boyutu = os.path.getsize(dosya_yolu)
        if dosya_boyutu < 10000: # 10 KB altındaysa muhtemelen hatalı/bozuk görseldir
            log.warning("  Dosya boyutu çok küçük, görsel bozuk olabilir.")
            return False
            
        log.info(f"  ✓ Görsel kaydedildi ({dosya_boyutu // 1024} KB): {dosya_yolu}")
        return True

    except Exception as e:
        log.error(f"  ✗ Görsel indirme hatası: {e}")
        return False


def _ses_uret(hikaye_metni: str, ses_yolu: str) -> None:
    """edge-tts kullanarak insan sesi kalitesinde Türkçe seslendirir."""
    log.info("Aşama 3 → YZ ses seslendirmesi üretiliyor...")
    
    async def _ureti_asenkron():
        # tr-TR-AhmetNeural (Erkek) veya tr-TR-EmelNeural (Kadın)
        communicate = edge_tts.Communicate(hikaye_metni, "tr-TR-AhmetNeural")
        await communicate.save(ses_yolu)
        
    # Asenkron akışı senkron Flask fonksiyonu içine güvenle bağlıyoruz
    asyncio.run(_ureti_asenkron())
    log.info(f"    ✓ Ses dosyası kaydedildi: {ses_yolu}")


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

        basarili_gorsel_referansi = None

        for i, tasvir in enumerate(tasvirler):
            gorsel_yolu = os.path.join(TEMP_DIR, f"gorsel_{istek_id}_{i}.jpg")
            gorsel_yollari.append(gorsel_yolu)
            
            basarili = False
            # İlk görselse hata alırsak sistemi kurtarmak için 3 kez farklı seed ile deneyelim
            deneme_sayisi = 3 if i == 0 else 1
            
            for deneme in range(deneme_sayisi):
                if _gorsel_indir(tasvir, gorsel_yolu):
                    basarili = True
                    basarili_gorsel_referansi = gorsel_yolu
                    break
                elif deneme < deneme_sayisi - 1:
                    log.warning(f"  Görsel {i} indirilemedi, farklı seed ile tekrar deneniyor...")

            # Eğer görsel indirilemediyse önceki başarılı YZ görselini klonlayarak boşluğu doldur
            if not basarili:
                if basarili_gorsel_referansi and os.path.exists(basarili_gorsel_referansi):
                    shutil.copy(basarili_gorsel_referansi, gorsel_yolu)
                    log.warning(f"  Görsel {i} başarısız oldu. Mor ekran yerine önceki YZ görseli kopyalandı.")
                else:
                    raise Exception("İlk görsel hiçbir şekilde indirilemedi (Pollinations API hatası).")

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
# GİRİŞ NOKTASI
# ─────────────────────────────────────────────

if __name__ == "__main__":
    log.info("=" * 55)
    log.info("  YZ Video Üreticisi — Flask Sunucusu Başlatılıyor")
    log.info("  Sağlık kontrolü: http://localhost:5000/saglik")
    log.info("  Video endpoint : POST http://localhost:5000/generate-video")
    log.info("=" * 55)
    app.run(host="0.0.0.0", port=5000, debug=False)