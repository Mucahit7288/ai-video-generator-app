import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/story_model.dart';

class StoryDetailScreen extends StatefulWidget {
  const StoryDetailScreen({super.key, required this.story});

  final StoryModel story;

  @override
  State<StoryDetailScreen> createState() => _StoryDetailScreenState();
}

class _StoryDetailScreenState extends State<StoryDetailScreen>
    with TickerProviderStateMixin {
  bool _isVideoLoading = false;
  bool _isVideoPlaying = false;

  VideoPlayerController? _videoController;

  late final AnimationController _shimmerController;
  late final AnimationController _pulseController;
  late final AnimationController _starsController;

  late final Animation<double> _shimmerAnimation;
  late final Animation<double> _pulseAnimation;
  late final Animation<double> _starsAnimation;

  // Yüklenme simülasyonu için yüzde
  double _loadingProgress = 0.0;
  bool _isDisposed = false;

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
  }

  @override
  void dispose() {
    _isDisposed = true;
    _videoController?.dispose(); // Sayfa kapatıldığında belleği temizler
    _shimmerController.dispose();
    _pulseController.dispose();
    _starsController.dispose();
    super.dispose();
  }

  // Video arabelleğe (buffer) alınırken progress bar'ı hareket ettirir
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
    if (_isVideoLoading || _isVideoPlaying) return;

    // Eğer video daha önceden yüklenmişse tekrar başlat, akışı bozma
    if (_videoController != null && _videoController!.value.isInitialized) {
      await _videoController!.play();
      setState(() {
        _isVideoPlaying = true;
      });
      return;
    }

    setState(() {
      _isVideoLoading = true;
      _loadingProgress = 0.0;
    });

    _simulateProgress();

    try {
      // HomeScreen'de video URL'ini imageUrls listesinin ilk elemanına kaydetmiştik.
      // Eğer kendi StoryModel'inize 'videoUrl' alanı eklediyseniz burayı güncelleyebilirsiniz.
      final videoUrl = widget.story.imageUrls.isNotEmpty
          ? widget.story.imageUrls.first
          : '';

      if (videoUrl.isEmpty) {
        throw Exception("Bu hikayeye ait video bağlantısı bulunamadı.");
      }

      // Doğrudan web uyumlu VideoPlayerController ağ akışı
      _videoController = VideoPlayerController.networkUrl(Uri.parse(videoUrl));

      await _videoController!.initialize();
      await _videoController!.setLooping(true); // Döngüsel oynat
      await _videoController!.play(); // Sesli ve görüntülü oynatmaya başla

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

  @override
  Widget build(BuildContext context) {
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
            // ignore: deprecated_member_use
            border: Border.all(color: Colors.white.withOpacity(0.08)),
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
              // --- Uzay temalı arka plan (her zaman altta kalsın) ---
              _buildSpaceBackground(),

              // --- Yıldız parıltıları ---
              AnimatedBuilder(
                animation: _starsAnimation,
                builder: (context, _) => CustomPaint(
                  painter: _StarfieldPainter(_starsAnimation.value),
                ),
              ),

              // --- Degrade overlay ---
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

              // --- GERÇEK VİDEO OYNATICI ---
              if (_videoController != null &&
                  _videoController!.value.isInitialized &&
                  _isVideoPlaying)
                Positioned.fill(child: VideoPlayer(_videoController!)),

              // --- Oynatma durumuna göre ara yüz ---
              if (!_isVideoPlaying)
                SizedBox(
                  height: 100,
                  child: Center(
                    child: _isVideoLoading
                        ? _buildLoadingState()
                        : _buildIdleState(),
                  ),
                ),

              // Video oynarken üzerinde görünecek (Durdur butonu vb.)
              if (_isVideoPlaying) _buildPlayingOverlay(),
            ],
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
          bottom: 14,
          right: 14,
          child: GestureDetector(
            onTap: () {
              _videoController?.pause();
              setState(() => _isVideoPlaying = false);
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              ),
              child: const Icon(
                Icons.stop_rounded,
                color: Colors.white70,
                size: 18,
              ),
            ),
          ),
        ),
      ],
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
