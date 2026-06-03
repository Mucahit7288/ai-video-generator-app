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
import edge_tts # type: ignore
import os
import re
import uuid
import logging
import requests # type: ignore
import random
import shutil
import time
import urllib.parse
import urllib3
urllib3.disable_warnings()  # HuggingFace verify=False SSL uyarılarını konsölde gizle
from dotenv import load_dotenv # type: ignore

load_dotenv()

from flask import Flask, jsonify, request, send_from_directory # pyright: ignore[reportMissingImports]
from flask_cors import CORS # type: ignore
from gtts import gTTS # type: ignore
import google.generativeai as genai # type: ignore
from moviepy import ImageClip, AudioFileClip, concatenate_videoclips # type: ignore
from moviepy.video.fx import CrossFadeIn, CrossFadeOut # type: ignore
from huggingface_hub import InferenceClient # type: ignore

# ─────────────────────────────────────────────
# YAPILANDIRMA
# ─────────────────────────────────────────────

# Buraya Google AI Studio'dan aldığınız yeni Gemini API anahtarını girin.
# Flutter tarafı bu anahtarı hiç görmez; tüm YZ çağrıları sunucu üzerinden yapılır.
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")

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

# Canlı Durum Takibi (Frontend /status endpoint'i için)
current_status = {"durum": "Hazır", "aşama": 0, "toplam": 5}


# ─────────────────────────────────────────────
# YARDIMCI FONKSİYONLAR
# ─────────────────────────────────────────────

def _yz_hikaye_uret(kullanici_fikri: str) -> dict:
    """
    Gemini kullanarak tek bir istekte Türkçe kısa hikaye üretir ve 
    bu hikayenin dinamik sahne tasvirlerini oluşturur.
    Döndürür: {'baslik': str, 'hikaye': str, 'tasvirler': list[str]}
    """
    log.info("Aşama 1 & 2 → YZ hikaye ve dinamik sahne üretimi tek adımda başlıyor…")
    current_status["durum"] = "🧠 Yapay zeka hikayeyi kurguluyor..."
    current_status["aşama"] = 1

    sistem_talimati = (
        "Sen yaratıcı bir Türkçe hikaye yazarısın ve görsel bir sanat yönetmenisin. "
        "Kullanıcının verdiği fikirden yola çıkarak kısa, etkileyici ve görsel açıdan zengin bir hikaye yaz. "
        "Gelen hikaye ne kadar uzun olursa olsun, hikayeyi tam olarak 3 ana sahneye (görsel tasvirine) böleceksin. Ne 1 eksik ne 1 fazla, KESİNLİKLE TAM 3 ADET SAHNE OLACAK. "
        "Her sahnenin görsel promptunu kesinlikle en fazla 5-6 kelimelik, İngilizce ve çok net nesne tasvirleri olarak yaz. (Örnek: Black cat with amber eyes).\n\n"
        "ÇIKTI FORMATI — Bu kurallara kesinlikle uy:\n"
        "YALNIZCA aşağıdaki JSON formatında cevap ver, Markdown (```json) etiketleri veya ek metin kullanma:\n"
        "{\n"
        '  "baslik": "Hikayenin Başlığı",\n'
        '  "hikaye": "Hikayenin tamamı...",\n'
        '  "tasvirler": [\n'
        '    "sahne 1 ingilizce prompt",\n'
        '    "sahne 2 ingilizce prompt"\n'
        "  ]\n"
        "}"
    )

    model = genai.GenerativeModel(
        model_name="gemini-2.5-flash",
        system_instruction=sistem_talimati,
    )

    yanit = model.generate_content(kullanici_fikri)
    ham_metin = yanit.text.strip()

    # Eğer markdown varsa temizle
    if ham_metin.startswith("```"):
        ham_metin = re.sub(r"^```(?:json)?\n", "", ham_metin)
        ham_metin = re.sub(r"\n```$", "", ham_metin)

    import json
    try:
        sonuc = json.loads(ham_metin)
        # Güvenlik için en fazla 6 sahne
        if "tasvirler" in sonuc and isinstance(sonuc["tasvirler"], list):
            sonuc["tasvirler"] = [str(t) for t in sonuc["tasvirler"][:3]]
        return sonuc
    except json.JSONDecodeError as e:
        log.error(f"Gemini yanıtı ayrıştırılamadı: {e}. Ham metin: {ham_metin}")
        return {
            "baslik": "İsimsiz Hikaye",
            "hikaye": kullanici_fikri,
            "tasvirler": ["space landscape", "nature landscape", "city landscape"]
        }


def _gorsel_indir(tasvir: str, dosya_yolu: str) -> None:
    """
    Çift Motorlu Görsel Üretim Sistemi (Güncel Öncelik Sırası):
      1. Motor → Hugging Face SDXL SDK  (InferenceClient — kalite, bağlam uyumu)
      2. Motor → Pollinations.ai Fallback (Chrome header, 3 deneme — kurşun geçirmez yedek)
    Her iki motor da başarısız olursa Exception fırlatır.
    """
    # ── Prompt Filtresi ──────────────────────────────────────────────────────
    # Sadece ASCII harf + boşluk bırak; özel karakter 402/hata riskini artırır.
    temiz_tasvir = re.sub(r'[^a-zA-Z\s]', '', tasvir)
    temiz_tasvir = " ".join(temiz_tasvir.split()[:4]).strip()

    # ── 1. Motor: Resmi Hugging Face SDK (InferenceClient) ───────────────────
    # SDK tüm SSL/TLS/header işini kendi içinde çözer; en kaliteli ve bağlama uyumlu motor.
    log.info(f"  [HuggingFace SDK] 1. Motor başlatılıyor: '{temiz_tasvir}'")
    current_status["durum"] = f"🎨 AI görseli üretiliyor (HuggingFace): '{temiz_tasvir[:25]}…'"

    try:
        hf_token = os.environ.get("HF_TOKEN")
        client = InferenceClient(
            model="stabilityai/stable-diffusion-xl-base-1.0",
            token=hf_token,
        )

        log.info(f"  [HuggingFace SDK] text_to_image çağrılıyor: '{temiz_tasvir}'")
        # SDK dönüş tipini otomatik olarak PIL.Image nesnesine çevirir.
        image = client.text_to_image(temiz_tasvir)

        # PIL Image nesnesini doğrudan JPEG olarak kaydet
        image.save(dosya_yolu, "JPEG")

        hf_boyut = os.path.getsize(dosya_yolu)
        if hf_boyut < 5000:
            raise Exception("HuggingFace SDK geçersiz/bozuk görsel üretti (çok küçük dosya)")

        log.info(f"  ✓ [HuggingFace SDK] Görsel kaydedildi ({hf_boyut // 1024} KB): {dosya_yolu}")
        return  # ✅ Başarılı — yedek motora gerek yok

    except Exception as hf_e:
        log.warning(f"  ⚠️ HuggingFace yoğun veya limit doldu, Yedek Motor (Pollinations) devreye giriyor... Hata: {hf_e}")
        current_status["durum"] = f"🔄 Yedek motor (Pollinations) devreye girdi: '{temiz_tasvir[:25]}…'"

    # ── 2. Motor: Pollinations Fallback (Kurşun Geçirmez Yedek) ─────────────
    # HuggingFace başarısız olduysa, Chrome User-Agent ile 3 deneme hakkı.
    pollinations_url = f"https://image.pollinations.ai/prompt/{temiz_tasvir}"
    browser_headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/124.0.0.0 Safari/537.36"
        )
    }

    for deneme in range(3):
        log.info(f"  [Pollinations] İstek öncesi 3 sn bekleniyor… (Deneme {deneme+1}/3)")
        time.sleep(3)

        try:
            log.info(f"  [Pollinations] Görsel üretiliyor: '{temiz_tasvir}'")
            current_status["durum"] = f"🎨 Sahne görseli çiziliyor (Pollinations): '{temiz_tasvir[:25]}…'"
            yanit = requests.get(pollinations_url, headers=browser_headers, timeout=60)
            yanit.raise_for_status()

            with open(dosya_yolu, "wb") as f:
                f.write(yanit.content)

            dosya_boyutu = os.path.getsize(dosya_yolu)
            if dosya_boyutu < 5000:
                raise Exception("Pollinations geçersiz/bozuk görsel döndürdü (çok küçük dosya)")

            log.info(f"  ✓ [Pollinations] Görsel kaydedildi ({dosya_boyutu // 1024} KB): {dosya_yolu}")
            return  # ✅ Başarılı

        except Exception as pol_e:
            log.error(f"  ✗ [Pollinations] Hata (Deneme {deneme+1}/3): {pol_e}")

    # Her iki motor da çöktü
    raise Exception(
        "Her iki motor da başarısız oldu.\n"
        "  HuggingFace SDK: limit/yoğunluk hatası\n"
        "  Pollinations   : 3/3 deneme başarısız"
    )



def _ses_uret(hikaye_metni: str, ses_yolu: str) -> None:
    """edge-tts kullanarak insan sesi kalitesinde Türkçe seslendirir."""
    log.info("Aşama 3 → YZ ses seslendirmesi üretiliyor...")
    current_status["durum"] = "🔊 Hikaye seslendiriliyor..."
    current_status["aşama"] = 4
    
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
    Görselleri ses dosyasının toplam süresi boyunca eşit aralıklarla
    sırayla gösterir. Görseller arası 1 saniyelik crossfade geçiş efekti ekler.
    """
    log.info("Aşama 4 → Video birleştirme başlıyor (Crossfade)…")
    current_status["durum"] = "🎬 Sahneler birleştiriliyor ve video oluşturuluyor..."
    current_status["aşama"] = 5

    ses_klibi = AudioFileClip(ses_yolu)
    toplam_sure = ses_klibi.duration
    gecis_suresi = 1.0  # 1 saniyelik crossfade
    gorsel_sayisi = len(gorsel_yollari)
    
    # Crossfade örtüşmeleri hesaba katarak görsel başına süreyi hesapla
    gorsel_sure = (toplam_sure + (gorsel_sayisi - 1) * gecis_suresi) / gorsel_sayisi

    log.info(
        f"  Ses süresi: {toplam_sure:.1f}s | "
        f"Görsel başına süre: {gorsel_sure:.1f}s | "
        f"Geçiş süresi: {gecis_suresi}s"
    )

    klip_listesi = []
    for i, gorsel_yolu in enumerate(gorsel_yollari):
        gorsel_klibi = (
            ImageClip(gorsel_yolu)
            .with_duration(gorsel_sure)
            .resized((VIDEO_WIDTH, VIDEO_HEIGHT))
        )

        # ── 6. Story: Crossfade Geçiş Efekti ──────────────────
        efektler = []
        if i > 0:
            efektler.append(CrossFadeIn(gecis_suresi))
        if i < gorsel_sayisi - 1:
            efektler.append(CrossFadeOut(gecis_suresi))
        
        if efektler:
            gorsel_klibi = gorsel_klibi.with_effects(efektler)

        klip_listesi.append(gorsel_klibi)
        log.info(f"  Görsel {i + 1} klibe eklendi: {gorsel_yolu}")

    birlesik_video = concatenate_videoclips(klip_listesi, method="compose", padding=-gecis_suresi)
    birlesik_video = birlesik_video.with_audio(ses_klibi)

    birlesik_video.write_videofile(
        cikti_yolu,
        fps=24,
        codec="libx264",
        audio_codec="aac",
        temp_audiofile=os.path.join(TEMP_DIR, "temp_audio.m4a"),
        remove_temp=True,
        logger=None,
    )

    ses_klibi.close()
    birlesik_video.close()

    log.info(f"  ✓ Video oluşturuldu (Crossfade): {cikti_yolu}")


def _altyazi_uret(hikaye_metni: str, toplam_sure: float, vtt_yolu: str) -> None:
    """
    7. Story: Hikaye metninden WebVTT (.vtt) formatında altyazı dosyası üretir.
    Metni 5-6 kelimelik parçalara böler ve ses süresine orantalar.
    """
    log.info("Aşama 5 → WebVTT altyazı dosyası üretiliyor…")

    kelimeler = hikaye_metni.split()
    parcalar = []
    for j in range(0, len(kelimeler), 5):
        parca = " ".join(kelimeler[j:j+5])
        parcalar.append(parca)

    if not parcalar:
        parcalar = [hikaye_metni]

    parca_suresi = toplam_sure / len(parcalar)

    # WebVTT standardı: Başlıktan sonra KESİNLİKLE iki boş satır olmalı.
    # "\n".join ile yazınca tek newline kalır, bunun önlemek için doğrudan string olarak yazıyoruz.
    with open(vtt_yolu, "w", encoding="utf-8") as f:
        # İlk satır: WEBVTT + çift boş satır (standart zorunlu)
        f.write("WEBVTT\n\n")
        for idx, parca in enumerate(parcalar):
            baslangic = idx * parca_suresi
            bitis = min((idx + 1) * parca_suresi, toplam_sure)
            # Her cue: index, zaman damgası (NOKTA ayrıcı), metin, boş satır
            f.write(f"{idx + 1}\n")
            f.write(f"{_format_vtt_zaman(baslangic)} --> {_format_vtt_zaman(bitis)}\n")
            f.write(f"{parca}\n")
            f.write("\n")

    log.info(f"  ✓ Altyazı dosyası kaydedildi ({len(parcalar)} parça): {vtt_yolu}")


def _format_vtt_zaman(saniye: float) -> str:
    """Saniyeyi HH:MM:SS.mmm formatına çevirir."""
    saat = int(saniye // 3600)
    dakika = int((saniye % 3600) // 60)
    sn = int(saniye % 60)
    ms = int((saniye % 1) * 1000)
    return f"{saat:02d}:{dakika:02d}:{sn:02d}.{ms:03d}"


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
    current_status["durum"] = "🚀 Video üretim süreci başladı..."
    current_status["aşama"] = 0

    # Her istek için benzersiz ID; paralel isteklerde çakışmayı önler
    istek_id = uuid.uuid4().hex[:8]

    gorsel_yollari = []
    ses_yolu = os.path.join(TEMP_DIR, f"ses_{istek_id}.mp3")
    video_adi = f"output_{istek_id}.mp4"
    video_yolu = os.path.join(STATIC_DIR, video_adi)

    try:
        # ── Aşama 1 & 2: YZ Hikaye ve Sahne Üretimi ──────────
        sonuc = _yz_hikaye_uret(kullanici_fikri)
        baslik = sonuc.get("baslik", "İsimsiz")
        hikaye = sonuc.get("hikaye", kullanici_fikri)
        tasvirler = sonuc.get("tasvirler", ["space landscape", "nature landscape", "city landscape"])
        
        log.info(f"  Başlık: '{baslik}'")
        log.info(f"  Aşama 2 → {len(tasvirler)} adet görsel üretimi başlıyor…")
        current_status["durum"] = f"🎨 {len(tasvirler)} adet sahne görseli çiziliyor..."
        current_status["aşama"] = 2

        for i, tasvir in enumerate(tasvirler):
            gorsel_yolu = os.path.join(TEMP_DIR, f"gorsel_{istek_id}_{i}.jpg")
            gorsel_yollari.append(gorsel_yolu)
            
            try:
                current_status["durum"] = f"🎨 Sahne {i+1}/{len(tasvirler)} için görsel çiziliyor..."
                _gorsel_indir(tasvir, gorsel_yolu)
            except Exception as e:
                # Tavizsiz İptal (Hard Fail) - 400/500 JSON dönecek
                hata_mesaji = f"Sahne {i+1} için görsel üretilemedi. Lütfen hikayeyi tekrar üretin."
                log.error(f"  ✗ {hata_mesaji} Detay: {e}")
                return jsonify({
                    "success": False,
                    "hata": hata_mesaji,
                }), 400

        # ── Aşama 3: YZ Ses Üretimi ──────────────────────────
        _ses_uret(hikaye, ses_yolu)

        # ── Aşama 4: Video Birleştirme (Crossfade) ──────────────
        _video_birlestir(gorsel_yollari, ses_yolu, video_yolu)

        # ── Aşama 5: WebVTT Altyazı Üretimi ───────────────────
        ses_klibi_tmp = AudioFileClip(ses_yolu)
        toplam_ses_suresi = ses_klibi_tmp.duration
        ses_klibi_tmp.close()
        
        altyazi_adi = f"subtitle_{istek_id}.vtt"
        altyazi_yolu = os.path.join(STATIC_DIR, altyazi_adi)
        _altyazi_uret(hikaye, toplam_ses_suresi, altyazi_yolu)

        # ── Yanıt ────────────────────────────────────────────
        video_url = f"{request.host_url}static/{video_adi}"
        subtitle_url = f"{request.host_url}static/{altyazi_adi}"
        log.info(f"✓ Tüm aşamalar tamamlandı. Video URL: {video_url}")
        current_status["durum"] = "✅ Video hazır!"
        current_status["aşama"] = 5

        return jsonify({
            "success": True,
            "baslik": baslik,
            "hikaye": hikaye,
            "video_url": video_url,
            "subtitle_url": subtitle_url,
        })

    except Exception as e:
        log.exception(f"✗ Kritik hata: {e}")
        current_status["durum"] = "❌ Hata oluştu"
        return jsonify({
            "success": False,
            "hata": f"Sunucu tarafında bir hata oluştu: {str(e)}",
        }), 500

    finally:
        # Geçici dosyaları her durumda temizle
        _gecici_dosyalari_temizle(ses_yolu, *gorsel_yollari)


@app.route("/status", methods=["GET"])
def durum_sorgula():
    """Frontend'in canlı durum takibi için kullandığı endpoint."""
    return jsonify(current_status), 200


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