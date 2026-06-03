🎬AI Video Generator App (YZ Destekli Video Oluşturucu)
Bu proje, kullanıcının girdiği kısa bir metin veya fikirden yola çıkarak; yapay zeka yardımıyla özgün bir hikaye kurgulayan, bu hikayeye uygun sahneler/görseller çizen, hikayeyi seslendiren ve tüm bunları dinamik geçiş efektleri ile altyazı desteğiyle birleştirip eksiksiz bir kısa video (.mp4) üreten uçtan uca bir mobil uygulamadır.

Uygulama, Çevik (Agile) Yazılım Geliştirme metodolojilerine uygun olarak, Scrum board üzerinde Story Point (SP) tahminlemeleri yapılarak geliştirilmiştir.

🎯 Proje Story Çıktıları & Kazanımları
Proje dokümanında belirtilen tüm kullanıcı hikayeleri (user stories) eksiksiz ve tam puan alacak şekilde mimariye entegre edilmiştir:

Story (10 Puan) - LLM ile Prompt Oluşturma: Kullanıcının girdisi doğrultusunda Gemini (Google Generative AI) API'si tetiklenerek anlamlı bir hikaye ve bu hikayeye özel İngilizce görsel üretim promptları tek adımda üretilir.

Story (10 Puan) - Veri Tabanı Kaydı: Üretilen hikaye, başlık ve sahne detayları kalıcı olarak veri tabanına kaydedilir.

Story (10 Puan) - Hikaye Temelli Görsel Üretimi: Üretilen hikayeden türetilen tasvirler kullanılarak en az 3 adet özgün görsel yapay zeka (Pollinations Yapısı) aracılığıyla eş zamanlı olarak indirilir.

Story (20 Puan) - Metinden Sese Dönüştürme (TTS): Yapay zeka tarafından kurgulanan hikaye metni, doğal bir seslendirme motoru kullanılarak yüksek kaliteli bir .mp3 ses dosyasına dönüştürülür.

Story (20 Puan) - Video Birleştirme: Elde edilen özgün görseller ve üretilen ses dosyası, Python arka planında (moviepy) ses süresine tam orantılı olacak şekilde birleştirilerek nihai .mp4 videosu oluşturulur.

Story (10 Puan) - Görsel Geçiş Efektleri: Görseller düz bir şekilde değişmez; her görsel geçişinde modern ve yumuşak bir Crossfade (Eriyerek Geçiş) efekti (1.0 saniye süreli) uygulanır.

Story (10 Puan) - Dinamik Altyazı Desteği: Video üretilirken arka planda ses süresiyle tam senkronize çalışan .vtt (WebVTT) formatında profesyonel bir altyazı dosyası üretilir. Bu altyazı, ön yüzde kullanıcıya dinamik olarak sunulur.

🚀 Gelişmiş Teknik Özellikler
Güvenlik (.env Entegrasyonu): Kritik API anahtarları kaynak kodda açıkta bırakılmamış, python-dotenv kütüphanesi kullanılarak .env dosyası altında güvenli bir şekilde saklanmış ve GitHub geçmişinden temizlenmiştir.

Kurşun Geçirmez Prompt Filtresi: Görsel üretim motorunun tıkanmasını engellemek amacıyla, gelen promptlar Regex (re.sub) ile temizlenip ilk 4 kelimeye kırpılarak stabilite %100'e çıkarılmıştır.

Gelişmiş Video Oynatıcı Kontrolleri (Chewie): Flutter tarafında sıradan oynatıcılar yerine Tam Ekran (Fullscreen) modu ve altyazıları anlık olarak açıp kapatmayı sağlayan CC (Closed Captions) butonu eklenmiştir.

İşlevsel Ses Kontrolü: Uygulama içindeki özel ses slider'ı (ses çubuğu) doğrudan oynatıcı katmanına bağlanarak ses seviyesinin anlık değiştirilebilmesi sağlanmıştır.

🛠️ Teknolojik Yığın (Tech Stack)
Frontend: Flutter (Dart)

Backend: Python (Flask)

YZ / Yapay Zeka Entegrasyonları:

Metin kurgusu: Gemini API

Görsel üretimi: Pollinations AI (Hızlı Çizim Kanalı) ve Hugging Face AI

Video & Ses İşleme: MoviePy, gTTS

Video Kontrolleri: Chewie & Video Player (Flutter)

⚙️ Kurulum ve Çalıştırma
1. Backend Kurulumu
backend klasörünün içine gidin ve gerekli kütüphaneleri yükleyin:

cd backend
pip install -r requirements.txt
pip install python-dotenv

Klasörün içinde bir .env dosyası oluşturun. Gemini API Ve Hugging Face Api anahtarınızı ekleyin:

GEMINI_API_KEY=your_actual_gemini_api_key_here
HF_TOKEN=your_hf_api_key_here

Sunucuyu ayağa kaldırın:

python app.py

2. Frontend Kurulumu
flutter projenizin ana dizinine gidin, paketleri çekin ve uygulamayı başlatın:

flutter pub get
flutter run

📋 Proje Yönetimi (Scrum & Story Points)
Proje süreçleri Agile felsefesine sadık kalınarak yönetilmiştir. Toplam proje yükü hikaye puanlarına (Story Points) bölünmüş, bağımlılıklar analiz edilerek sprint planlaması yapılmıştır. Sunum esnasında güncel Scrum Board ve sprint çıktıları kurul heyetine sunulacaktır.
