import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import 'package:ai_video_frontend/models/story_model.dart';

// ─────────────────────────────────────────────
// WebVTT Ayrıştırıcı (Parser)
// ─────────────────────────────────────────────

class SubtitleEntry {
  final Duration start;
  final Duration end;
  final String text;
  SubtitleEntry({required this.start, required this.end, required this.text});
}

List<SubtitleEntry> _parseVtt(String vttContent) {
  final entries = <SubtitleEntry>[];
  final lines = vttContent.split('\n');
  int i = 0;

  // WEBVTT başlığını atla
  while (i < lines.length && !lines[i].contains('-->')) {
    i++;
  }

  while (i < lines.length) {
    final line = lines[i].trim();
    if (line.contains('-->')) {
      final parts = line.split('-->');
      if (parts.length == 2) {
        final start = _parseVttTime(parts[0].trim());
        final end = _parseVttTime(parts[1].trim());
        i++;
        final textLines = <String>[];
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          textLines.add(lines[i].trim());
          i++;
        }
        if (textLines.isNotEmpty) {
          entries.add(SubtitleEntry(
            start: start,
            end: end,
            text: textLines.join(' '),
          ));
        }
      }
    }
    i++;
  }
  return entries;
}

Duration _parseVttTime(String time) {
  // Format: HH:MM:SS.mmm
  final parts = time.split(':');
  if (parts.length == 3) {
    final hours = int.tryParse(parts[0]) ?? 0;
    final minutes = int.tryParse(parts[1]) ?? 0;
    final secParts = parts[2].split('.');
    final seconds = int.tryParse(secParts[0]) ?? 0;
    final millis = secParts.length > 1 ? int.tryParse(secParts[1]) ?? 0 : 0;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: millis,
    );
  }
  return Duration.zero;
}

// ─────────────────────────────────────────────
// Hikaye Detay Ekranı
// ─────────────────────────────────────────────

class StoryDetailScreen extends StatefulWidget {
  const StoryDetailScreen({
    super.key,
    required this.story,
    this.subtitleUrl,
  });

  final StoryModel story;
  final String? subtitleUrl;

  @override
  State<StoryDetailScreen> createState() => _StoryDetailScreenState();
}

class _StoryDetailScreenState extends State<StoryDetailScreen>
    with TickerProviderStateMixin {
  bool _isVideoLoading = false;
  bool _isVideoPlaying = false;

  VideoPlayerController? _videoController;

  // Altyazı sistemi
  List<SubtitleEntry> _subtitles = [];
  String _currentSubtitle = '';
  bool _showSubtitles = true;

  // Tam ekran
  bool _isFullscreen = false;

  late final AnimationController _shimmerController;
  late final AnimationController _pulseController;
  late final AnimationController _starsController;

  late final Animation<double> _shimmerAnimation;
  late final Animation<double> _pulseAnimation;
  late final Animation<double> _starsAnimation;

  // Yüklenme simülasyonu için yüzde
  double _loadingProgress = 0.0;
  bool _isDisposed = false;

  // Altyazı zamanlayıcısı (saniyede 4 kez güncelleme)
  Timer? _subtitleTimer;

  @override
  void initState() {
    super.initState();

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _starsController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _shimmerAnimation = Tween<double>(begin: -1.5, end: 1.5).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );

    _pulseAnimation = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _starsAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _starsController, curve: Curves.linear));

    // Altyazı dosyasını ARTIK burada yüklemiyoruz.
    // Race condition'u önlemek için yükleme, video başlatmadan hemen önce yapılıyor.
    // Bkz: _onPlayPressed() içindeki await _loadSubtitles()
  }

  @override
  void dispose() {
    _isDisposed = true;
    _subtitleTimer?.cancel();
    _videoController?.dispose();
    _shimmerController.dispose();
    _pulseController.dispose();
    _starsController.dispose();
    // Tam ekrandan çıkarken ekran yönünü sıfırla
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// VTT dosyasını indirir ve parse eder.
  /// Video başlatmadan önce await ile çağrılmalıdır.
  Future<void> _loadSubtitles() async {
    final url = widget.subtitleUrl;
    if (url == null || url.isEmpty) return;

    try {
      debugPrint('[Altyazı] İndirme başlıyor: $url');
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final content = response.body;
        final parsed = _parseVtt(content);
        if (mounted) {
          setState(() {
            _subtitles = parsed;
          });
        }
        debugPrint('[Altyazı] ✓ ${parsed.length} cue yüklendi.');
      } else {
        debugPrint('[Altyazı] HTTP ${response.statusCode} — altyazı atlanıyor.');
      }
    } catch (e) {
      debugPrint('[Altyazı] ✗ İndirme hatası: $e');
    }
  }

  void _updateSubtitle() {
    if (_videoController == null || _subtitles.isEmpty || !_showSubtitles) {
      if (_currentSubtitle.isNotEmpty) {
        setState(() => _currentSubtitle = '');
      }
      return;
    }

    final position = _videoController!.value.position;
    String newSub = '';
    for (final entry in _subtitles) {
      if (position >= entry.start && position <= entry.end) {
        newSub = entry.text;
        break;
      }
    }

    if (newSub != _currentSubtitle) {
      setState(() => _currentSubtitle = newSub);
    }
  }

  void _simulateProgress() async {
    _loadingProgress = 0.0;
    while (_isVideoLoading && !_isDisposed && _loadingProgress < 0.95) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (!_isVideoLoading || _isDisposed) break;
      if (mounted) {
        setState(() {
          _loadingProgress += 0.04;
          if (_loadingProgress > 0.95) _loadingProgress = 0.95;
        });
      }
    }
  }

  Future<void> _onPlayPressed() async {
    if (_isVideoLoading) return;

    if (_videoController != null && _videoController!.value.isInitialized) {
      if (_isVideoPlaying) {
        await _videoController!.pause();
        setState(() => _isVideoPlaying = false);
      } else {
        await _videoController!.play();
        setState(() => _isVideoPlaying = true);
      }
      return;
    }

    setState(() {
      _isVideoLoading = true;
      _loadingProgress = 0.0;
    });

    _simulateProgress();

    try {
      final videoUrl = widget.story.imageUrls.isNotEmpty
          ? widget.story.imageUrls.first
          : '';

      if (videoUrl.isEmpty) {
        throw Exception("Bu hikayeye ait video bağlantısı bulunamadı.");
      }

      _videoController = VideoPlayerController.networkUrl(Uri.parse(videoUrl));

      // ⏳ Race condition önlemi: Altyazı tamamen inip parse edilmeden video BAŞLAMIYOR.
      // Bu await bitmeden bir sonraki satıra geçilmez.
      await _loadSubtitles();

      await _videoController!.initialize();
      await _videoController!.setLooping(false);
      await _videoController!.play();

      // Altyazıyı saniyede 4 kez güncelleyen hassas zamanlayıcı
      _subtitleTimer?.cancel();
      _subtitleTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) {
          if (mounted && _videoController != null && _videoController!.value.isInitialized) {
            _updateSubtitle();
          }
        },
      );

      _videoController!.addListener(() {
        if (!mounted) return;
        final isPlaying = _videoController!.value.isPlaying;
        if (isPlaying != _isVideoPlaying) {
          setState(() {
            _isVideoPlaying = isPlaying;
          });
        }
      });

      if (!mounted) return;

      setState(() {
        _loadingProgress = 1.0;
        _isVideoLoading = false;
        _isVideoPlaying = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isVideoLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Video yüklenirken hata oluştu: $e')),
      );
    }
  }

  Future<void> _seekBackward() async {
    if (_videoController == null) return;
    final position = await _videoController!.position;
    if (position != null) {
      final newPosition = position - const Duration(seconds: 10);
      await _videoController!.seekTo(newPosition < Duration.zero ? Duration.zero : newPosition);
    }
  }

  Future<void> _seekForward() async {
    if (_videoController == null) return;
    final position = await _videoController!.position;
    final duration = _videoController!.value.duration;
    if (position != null) {
      final newPosition = position + const Duration(seconds: 10);
      await _videoController!.seekTo(newPosition > duration ? duration : newPosition);
    }
  }

  void _toggleMute() {
    if (_videoController == null) return;
    final isMuted = _videoController!.value.volume == 0;
    _videoController!.setVolume(isMuted ? 1.0 : 0.0);
    setState(() {});
  }

  void _toggleSubtitles() {
    setState(() {
      _showSubtitles = !_showSubtitles;
      if (!_showSubtitles) _currentSubtitle = '';
    });
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
    });

    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isFullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildFullscreenPlayer(),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D0B1A),
      appBar: _buildAppBar(context),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_buildVideoPlayer(), _buildStorySection()],
        ),
      ),
    );
  }

  Widget _buildFullscreenPlayer() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_videoController != null && _videoController!.value.isInitialized)
          Center(
            child: AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            ),
          ),

        // Altyazı (Fullscreen) — kontrol çubuğunun üstünde kalır
        if (_currentSubtitle.isNotEmpty && _showSubtitles)
          Positioned(
            bottom: 90,
            left: 24,
            right: 24,
            child: _buildSubtitleWidget(),
          ),

        // Kontroller (Fullscreen)
        if (_videoController != null && _videoController!.value.isInitialized)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildControlsBar(),
          ),
      ],
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: const Color(0xFF0D0B1A),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        icon: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: const Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 16,
            color: Colors.white70,
          ),
        ),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        widget.story.title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 0.2,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: Colors.white.withValues(alpha: 0.05),
        ),
      ),
    );
  }

  Widget _buildVideoPlayer() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildSpaceBackground(),

              AnimatedBuilder(
                animation: _starsAnimation,
                builder: (context, _) => CustomPaint(
                  painter: _StarfieldPainter(_starsAnimation.value),
                ),
              ),

              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.55),
                    ],
                  ),
                ),
              ),

              if (_videoController != null &&
                  _videoController!.value.isInitialized)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _onPlayPressed,
                    child: VideoPlayer(_videoController!),
                  ),
                ),

              if (_videoController == null || !_videoController!.value.isInitialized)
                SizedBox(
                  height: 100,
                  child: Center(
                    child: _isVideoLoading
                        ? _buildLoadingState()
                        : _buildIdleState(),
                  ),
                ),

              // Altyazı (Normal mod) — kontrol çubuğunun üstünde kalır
              if (_currentSubtitle.isNotEmpty && _showSubtitles)
                Positioned(
                  bottom: 90,
                  left: 12,
                  right: 12,
                  child: _buildSubtitleWidget(),
                ),

              if (_videoController != null && _videoController!.value.isInitialized)
                _buildPlayingOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitleWidget() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _currentSubtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white,
            fontWeight: FontWeight.w500,
            height: 1.3,
          ),
        ),
      ),
    );
  }

  Widget _buildSpaceBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.2, -0.3),
          radius: 1.2,
          colors: [Color(0xFF1A1040), Color(0xFF0D0B1A), Color(0xFF060410)],
        ),
      ),
    );
  }

  Widget _buildIdleState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) =>
                Transform.scale(scale: _pulseAnimation.value, child: child),
            child: GestureDetector(
              onTap: _onPlayPressed,
              child: Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.deepPurpleAccent.withValues(alpha: 0.4),
                      blurRadius: 30,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.play_circle_fill_rounded,
                  size: 40,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: const Text(
              'Videoyu Oynat',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white70,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _shimmerAnimation,
            builder: (context, _) {
              return Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(
                    startAngle: 0,
                    endAngle: 6.28,
                    transform: GradientRotation(_shimmerAnimation.value * 3.14),
                    colors: const [
                      Colors.deepPurpleAccent,
                      Colors.transparent,
                      Colors.deepPurpleAccent,
                    ],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF1A1040),
                    ),
                    child: const Icon(
                      Icons.downloading_rounded,
                      color: Colors.deepPurpleAccent,
                      size: 28,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _loadingProgress,
                    minHeight: 3,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.deepPurpleAccent,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Video bağlanıyor… ${(_loadingProgress * 100).toInt()}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.45),
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayingOverlay() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _buildControlsBar(),
        ),
      ],
    );
  }

  Widget _buildControlsBar() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.85),
            Colors.transparent,
          ],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // İleri-Geri Sarma Çubuğu (VideoProgressIndicator)
          VideoProgressIndicator(
            _videoController!,
            allowScrubbing: true,
            colors: VideoProgressColors(
              playedColor: Colors.deepPurpleAccent,
              bufferedColor: Colors.white.withValues(alpha: 0.3),
              backgroundColor: Colors.white.withValues(alpha: 0.1),
            ),
            padding: const EdgeInsets.symmetric(vertical: 8),
          ),
          
          const SizedBox(height: 8),
          
          // Kontrol Butonları
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Sol taraftaki oynatma kontrolleri
              Row(
                children: [
                  // Geri 10 Saniye
                  GestureDetector(
                    onTap: _seekBackward,
                    child: const Icon(
                      Icons.replay_10_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 20),
                  
                  // Oynat / Durdur
                  GestureDetector(
                    onTap: _onPlayPressed,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        _isVideoPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  
                  // İleri 10 Saniye
                  GestureDetector(
                    onTap: _seekForward,
                    child: const Icon(
                      Icons.forward_10_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ],
              ),
              
              // Sağ taraftaki kontroller: Ses + Altyazı + Tam Ekran
              Row(
                children: [
                  // Ses kontrolü ve Slider
                  GestureDetector(
                    onTap: _toggleMute,
                    child: Icon(
                      (_videoController!.value.volume == 0)
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 2.5,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                        activeTrackColor: Colors.deepPurpleAccent,
                        inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
                        thumbColor: Colors.white,
                        overlayColor: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                      ),
                      child: Slider(
                        value: _videoController!.value.volume,
                        min: 0.0,
                        max: 1.0,
                        onChanged: (value) {
                          setState(() {
                            _videoController!.setVolume(value);
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // CC (Altyazı) Butonu
                  GestureDetector(
                    onTap: _toggleSubtitles,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: _showSubtitles
                              ? Colors.deepPurpleAccent
                              : Colors.white.withValues(alpha: 0.4),
                          width: 1.5,
                        ),
                        color: _showSubtitles
                            ? Colors.deepPurpleAccent.withValues(alpha: 0.3)
                            : Colors.transparent,
                      ),
                      child: Text(
                        'CC',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: _showSubtitles
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Tam Ekran Butonu
                  GestureDetector(
                    onTap: _toggleFullscreen,
                    child: Icon(
                      _isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStorySection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.calendar_today_rounded,
                size: 12,
                color: Colors.deepPurpleAccent.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 6),
              Text(
                _formatDate(widget.story.createdAt),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.35),
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 3,
                height: 3,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.auto_stories_rounded,
                size: 12,
                color: Colors.deepPurpleAccent.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 6),
              Text(
                '${widget.story.content.split(' ').length} kelime',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.35),
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.deepPurpleAccent.withValues(alpha: 0.5),
                  Colors.transparent,
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          Text(
            widget.story.content,
            style: TextStyle(
              fontSize: 16,
              color: Colors.white.withValues(alpha: 0.88),
              height: 1.8,
              letterSpacing: 0.15,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 32),

          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 30,
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 14,
                  color: Colors.deepPurpleAccent.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 30,
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = [
      'Ocak',
      'Şubat',
      'Mart',
      'Nisan',
      'Mayıs',
      'Haziran',
      'Temmuz',
      'Ağustos',
      'Eylül',
      'Ekim',
      'Kasım',
      'Aralık',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

class _StarfieldPainter extends CustomPainter {
  final double progress;

  _StarfieldPainter(this.progress);

  static const List<(double, double, double)> _stars = [
    (0.05, 0.12, 1.2),
    (0.14, 0.55, 0.8),
    (0.22, 0.28, 1.5),
    (0.31, 0.71, 1.0),
    (0.38, 0.09, 0.7),
    (0.47, 0.44, 1.3),
    (0.55, 0.82, 0.9),
    (0.63, 0.33, 1.6),
    (0.71, 0.61, 0.8),
    (0.80, 0.17, 1.1),
    (0.88, 0.75, 1.4),
    (0.92, 0.40, 0.6),
    (0.18, 0.88, 1.2),
    (0.42, 0.95, 0.9),
    (0.75, 0.90, 1.0),
    (0.60, 0.05, 0.8),
    (0.85, 0.52, 1.3),
    (0.10, 0.68, 0.7),
    (0.50, 0.20, 1.5),
    (0.95, 0.85, 1.1),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (final (xRatio, yRatio, baseRadius) in _stars) {
      final twinkle = 0.5 + 0.5 * _fastSin((progress + xRatio) * 6.28 * 2);
      final opacity = 0.15 + 0.65 * twinkle;
      final radius = baseRadius * (0.8 + 0.4 * twinkle);

      canvas.drawCircle(
        Offset(xRatio * size.width, yRatio * size.height),
        radius,
        Paint()..color = Colors.white.withValues(alpha: opacity),
      );
    }

    _drawNebula(canvas, size, 0.25, 0.35, Colors.deepPurple, progress);
    _drawNebula(canvas, size, 0.70, 0.60, Colors.indigo, progress * 0.7);
  }

  void _drawNebula(
    Canvas canvas,
    Size size,
    double xR,
    double yR,
    Color color,
    double prog,
  ) {
    final pulse = 0.3 + 0.2 * _fastSin(prog * 6.28);
    canvas.drawCircle(
      Offset(xR * size.width, yR * size.height),
      28,
      Paint()
        ..color = color.withValues(alpha: pulse * 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
  }

  double _fastSin(double x) {
    final normalized = x % 6.2832;
    final t = normalized - 3.1416;
    return t * (1 - t * t / 6.0);
  }

  @override
  bool shouldRepaint(_StarfieldPainter old) => old.progress != progress;
}