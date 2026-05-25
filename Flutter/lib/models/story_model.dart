import 'package:hive/hive.dart';

part 'story_model.g.dart';

@HiveType(typeId: 0)
class StoryModel extends HiveObject {
  @HiveField(0)
  final String title;

  @HiveField(1)
  final String content;

  @HiveField(2)
  final DateTime createdAt;

  @HiveField(3)
  final List<String> imageUrls;

  @HiveField(4)
  final String? videoUrl;

  StoryModel({
    required this.title,
    required this.content,
    required this.createdAt,
    required this.imageUrls,
    this.videoUrl,
  });
}
