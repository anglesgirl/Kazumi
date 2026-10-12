// PoC: TMDB 数据源适配器
// 原理: 把 TMDB 的返回映射成 BangumiItem / EpisodeInfo, UI 层零改动
// 难度评估: 低 —— 只需新增这一个文件 + 设置页加个数据源开关

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/utils/date_time.dart';

class TmdbApi {
  static const String _baseUrl = 'https://api.themoviedb.org/3';
  static const String _imageBase = 'https://image.tmdb.org/t/p/w500';

  static String get _apiKey =>
      GStorage.getSetting(SettingsKeys.tmdbApiKey).trim();

  static final Dio _dio = Dio(BaseOptions(
    baseUrl: _baseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  static Future<dynamic> _get(String path,
      {Map<String, dynamic>? params}) async {
    final res = await _dio.get(path, queryParameters: {
      'api_key': _apiKey,
      'language': 'zh-CN',
      ...?params,
    });
    return res.data;
  }

  /// 搜索: 对应 BangumiApi.bangumiSearch
  /// TMDB /search/multi 同时返回电影和电视剧
  static Future<BangumiSearchPage?> tmdbSearch(String keyword,
      {int page = 1}) async {
    try {
      final jsonData = await _get('/search/multi', params: {
        'query': keyword,
        'page': page,
        'include_adult': false,
      });
      final List<BangumiItem> items = [];
      for (final jsonItem in (jsonData['results'] as List)) {
        // 跳过人物
        if (jsonItem['media_type'] == 'person') continue;
        try {
          items.add(_mapToBangumiItem(jsonItem));
        } catch (_) {}
      }
      return BangumiSearchPage(
        items: items,
        rawCount: jsonData['total_results'] ?? items.length,
      );
    } catch (_) {
      return null;
    }
  }

  /// 详情: 对应 BangumiApi.getBangumiInfoByID
  /// id 编码规则: TMDB 电影 id 直接用; 电视剧 id 取负避免冲突
  /// (Bangumi id 都是正数, 负数天然区分数据源)
  static Future<BangumiItem?> getTmdbInfoByID(int id) async {
    try {
      final bool isTv = id < 0;
      final realId = id.abs();
      final path = isTv ? '/tv/$realId' : '/movie/$realId';
      final jsonData = await _get(path);
      jsonData['media_type'] = isTv ? 'tv' : 'movie';
      return _mapToBangumiItem(jsonData);
    } catch (_) {
      return null;
    }
  }

  /// 剧集: 对应 BangumiApi.getBangumiEpisodesByID
  /// 电影返回单集模板; 电视剧取第 1 季 (可扩展为选季)
  static Future<List<EpisodeInfo>> getTmdbEpisodesByID(int id) async {
    try {
      final bool isTv = id < 0;
      final realId = id.abs();
      if (!isTv) {
        // 电影: 单集
        return [EpisodeInfo.fromTemplate()];
      }
      // 电视剧: 拉取季列表, 默认第 1 季
      final tvData = await _get('/tv/$realId');
      final seasons = (tvData['seasons'] as List)
          .where((s) => (s['season_number'] as int) > 0)
          .toList();
      if (seasons.isEmpty) return [EpisodeInfo.fromTemplate()];
      final seasonNum = seasons.first['season_number'] as int;
      final seasonData = await _get('/tv/$realId/season/$seasonNum');
      final List<EpisodeInfo> episodes = [];
      for (final ep in (seasonData['episodes'] as List)) {
        episodes.add(EpisodeInfo(
          id: ep['id'] ?? 0,
          episode: ep['episode_number'] ?? 0,
          type: 0,
          name: ep['name'] ?? '',
          nameCn: ep['name'] ?? '',
        ));
      }
      return episodes;
    } catch (_) {
      return [EpisodeInfo.fromTemplate()];
    }
  }

  /// 核心映射: TMDB JSON -> BangumiItem
  /// UI 层只认 BangumiItem, 这里做适配, 上层不用改一行
  static BangumiItem _mapToBangumiItem(Map<String, dynamic> json) {
    final mediaType = json['media_type'] as String? ?? 'movie';
    final isTv = mediaType == 'tv';

    final title = json['title'] ?? json['name'] ?? '';
    final originalTitle =
        json['original_title'] ?? json['original_name'] ?? '';

    // id 符号区分数据源: 电影正数, 电视剧负数
    final tmdbId = (json['id'] as int? ?? 0);
    final mappedId = isTv ? -tmdbId : tmdbId;

    final posterPath = json['poster_path'] as String?;
    final backdropPath = json['backdrop_path'] as String?;

    final images = <String, String>{
      'large': posterPath != null ? '$_imageBase$posterPath' : '',
      'common': backdropPath != null ? '$_imageBase$backdropPath' : '',
      'medium': posterPath != null ? '$_imageBase$posterPath' : '',
      'small': posterPath != null ? '$_imageBase$posterPath' : '',
      'grid': posterPath != null ? '$_imageBase$posterPath' : '',
    };

    final dateStr =
        (json['release_date'] ?? json['first_air_date'] ?? '') as String;

    final voteAvg = (json['vote_average'] as num? ?? 0).toDouble();

    return BangumiItem(
      id: mappedId,
      // Bangumi type: 2=动画, 借用 1=电影, 6=电视剧 (Bangumi 原生类型, UI 不强依赖)
      type: isTv ? 6 : 1,
      name: originalTitle.isNotEmpty ? originalTitle : title,
      nameCn: title,
      summary: json['overview'] ?? '',
      airDate: dateStr,
      airWeekday: dateStringToWeekday(
          dateStr.isEmpty ? '2000-11-11' : dateStr),
      rank: 0,
      images: images,
      tags: [],
      alias: [],
      ratingScore: double.parse(voteAvg.toStringAsFixed(1)),
      votes: json['vote_count'] ?? 0,
      votesCount: [],
      info: '',
    );
  }
}
