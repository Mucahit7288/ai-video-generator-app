// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/story_model.dart';
import '../services/gemini_service.dart';
import 'story_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _promptController = TextEditingController();
  final GeminiService _geminiService = GeminiService();
  bool _isLoading = false;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _promptController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _generateAndSaveStory() async {
    final userPrompt = _promptController.text.trim();

    if (userPrompt.isEmpty) {
      _showSnackBar(
        message: 'Lütfen bir fikir yazın!',
        icon: Icons.warning_amber_rounded,
        color: Colors.orange,
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final result = await _geminiService.generateStory(userPrompt);

      final title = result['title'] ?? 'İsimsiz Hikaye';
      final content = result['content'] ?? '';

      final story = StoryModel(
        title: title,
        content: content,
        createdAt: DateTime.now(),
        imageUrls: [],
      );

      await Hive.box<StoryModel>('stories').add(story);

      _promptController.clear();

      if (mounted) {
        _showSnackBar(
          message: '"$title" kaydedildi!',
          icon: Icons.auto_stories_rounded,
          color: Colors.deepPurpleAccent,
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          message: 'Bir hata oluştu: $e',
          icon: Icons.error_outline_rounded,
          color: Colors.redAccent,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar({
    required String message,
    required IconData icon,
    required Color color,
  }) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        backgroundColor: const Color(0xFF1E1B2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color.withValues(alpha: 0.5)),
        ),
        content: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('✦ Hikaye Üretici'),
        actions: [
          ValueListenableBuilder(
            valueListenable: Hive.box<StoryModel>('stories').listenable(),
            builder: (context, Box<StoryModel> box, _) {
              final count = box.length;
              return Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: Colors.deepPurpleAccent.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      '$count hikaye',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.deepPurpleAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildPromptSection(),
          const SizedBox(height: 8),
          _buildSectionHeader(),
          Expanded(child: _buildStoryList()),
        ],
      ),
    );
  }

  Widget _buildPromptSection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1B2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.deepPurple.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Colors.deepPurpleAccent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Yeni Hikaye Oluştur',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.deepPurpleAccent,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _promptController,
            maxLines: 3,
            minLines: 2,
            enabled: !_isLoading,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText:
                  'Hikaye fikrinizi yazın…\nÖrn: "Uzayda kaybolan bir astronot"',
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.25),
                fontSize: 14,
                height: 1.5,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              contentPadding: const EdgeInsets.all(14),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _isLoading ? _pulseAnimation.value : 1.0,
                  child: child,
                );
              },
              child: ElevatedButton(
                onPressed: _isLoading ? null : _generateAndSaveStory,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isLoading
                      ? Colors.deepPurple.withValues(alpha: 0.4)
                      : Colors.deepPurple,
                  disabledBackgroundColor: Colors.deepPurple.withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: _isLoading ? 0 : 4,
                  shadowColor: Colors.deepPurple.withValues(alpha: 0.5),
                ),
                child: _isLoading
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white70,
                            ),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Hikaye yazılıyor…',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.bolt_rounded,
                              color: Colors.yellow, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Hikaye Üret',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          const Icon(Icons.auto_stories_rounded,
              size: 16, color: Colors.white38),
          const SizedBox(width: 6),
          const Text(
            'Kayıtlı Hikayeler',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white38,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          Container(
            height: 1,
            width: 80,
            color: Colors.white.withValues(alpha: 0.07),
          ),
        ],
      ),
    );
  }

  Widget _buildStoryList() {
    return ValueListenableBuilder(
      valueListenable: Hive.box<StoryModel>('stories').listenable(),
      builder: (context, Box<StoryModel> box, _) {
        if (box.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.menu_book_rounded,
                  size: 52,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
                const SizedBox(height: 14),
                Text(
                  'Henüz hikaye yok',
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.white.withValues(alpha: 0.2),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Bir fikir yazıp ⚡ butonuna bas',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          );
        }

        final stories = box.values.toList().reversed.toList();

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          itemCount: stories.length,
          itemBuilder: (context, index) {
            final story = stories[index];
            return Dismissible(
              // Her kartın benzersiz anahtarı olarak Hive key kullanılıyor.
              // Bu sayede ters sıralama kaynaklı index karışıklığı tamamen önleniyor.
              key: ValueKey(story.key),
              direction: DismissDirection.endToStart,
              onDismissed: (_) {
                box.delete(story.key);
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    margin: const EdgeInsets.all(16),
                    backgroundColor: const Color(0xFF1E1B2E),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                          color: Colors.redAccent.withValues(alpha: 0.5)),
                    ),
                    content: Row(
                      children: [
                        const Icon(Icons.delete_sweep_rounded,
                            color: Colors.redAccent, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '"${story.title}" silindi.',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              // Kaydırma sırasında arkada görünen kırmızı zemin + çöp kutusu
              background: Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Sil',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              child: _StoryCard(story: story),
            );
          },
        );
      },
    );
  }
}

class _StoryCard extends StatelessWidget {
  const _StoryCard({required this.story});

  final StoryModel story;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StoryDetailScreen(story: story),
          ),
        ),
        child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1B2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withOpacity(0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  story.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDate(story.createdAt),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(0.3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            story.content,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withOpacity(0.55),
              height: 1.55,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.schedule_rounded,
                  size: 12, color: Colors.deepPurpleAccent.withOpacity(0.6)),
              const SizedBox(width: 4),
              Text(
                '${story.content.split(' ').length} kelime',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.deepPurpleAccent.withOpacity(0.6),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
        ), // Container
      ), // InkWell
    ); // Material
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.'
        '${date.month.toString().padLeft(2, '0')}.'
        '${date.year}';
  }
}