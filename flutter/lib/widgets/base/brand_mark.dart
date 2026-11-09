/// Ayla 图形标识（mark-5 body）—— Flutter 端实现。
///
/// ## 事实源
/// `Ayla/design/brand/logo-max.svg`（1390.6 最大裁剪、透明底、直角方图），
/// web 副本 `web/public/brand/logo-max.svg`。规范见 `Ayla/docs/design.md` §6.1：
/// **默认统一用透明底**，只有明确要求时才用粉底 `logo-on-pink.svg`。
///
/// ## 为什么不用图片资源 / flutter_svg
/// 本工程没有 `flutter_svg` 依赖（见 pubspec 的图标段注释），且 `assets/` 目前只有字体
/// ——图标体系的做法是**把 web 的 path 数据移植成 Dart**（`theme/app_icons.dart` 同此路径）。
/// 标识同样处理：5 条 path 全是 M/L/Z 的直线多边形，直接换算成归一化点列，
/// 用 `Canvas.drawPath` 实心填充，矢量无损、任意尺寸清晰，且不需要新增依赖或图片资源。
/// 与 web 的差异：web 加载 SVG 由浏览器光栅化，这里逐帧重建 Path —— 因此把 Path
/// 缓存在 Widget 实例上，只在边长变化时重建。
///
/// ## 数据来源与不可手改
/// 下方 5 组多边形由 `logo-max.svg` 逐坐标换算（相对 viewBox 原点归一化到 0..1），
/// **禁止手改**：标识变了就重新生成，而不是在这里调点位。
///
/// ## 公开面
/// `AylaBrandMark` · `AylaBrandLogoRow` · `AylaBrandWordmark`
library;

import 'package:flutter/material.dart';

import '../../theme/css_gradient.dart';
import '../../theme/tokens.dart';

/// 每个颜色的多边形组（坐标已归一化到 0..1，绘制时乘边长）。
const List<List<Offset>> _kBDD4E9 = <List<Offset>>[
    <Offset>[
      Offset(0.4835, 0.3541),
      Offset(0.3137, 0.5730),
      Offset(0.6534, 0.5730),
    ],
];
const List<List<Offset>> _kFFFAFB = <List<Offset>>[
    <Offset>[
      Offset(0.6886, 0.0693),
      Offset(0.6296, 0.0810),
      Offset(0.5736, 0.0972),
      Offset(0.5206, 0.1178),
      Offset(0.4691, 0.1429),
      Offset(0.4558, 0.1429),
      Offset(0.4367, 0.1384),
      Offset(0.3999, 0.1340),
      Offset(0.3409, 0.1325),
      Offset(0.3395, 0.1340),
      Offset(0.3130, 0.1340),
      Offset(0.3115, 0.1355),
      Offset(0.2614, 0.1399),
      Offset(0.2408, 0.1458),
      Offset(0.2313, 0.1598),
      Offset(0.2150, 0.2011),
      Offset(0.1488, 0.3527),
      Offset(0.0045, 0.5354),
      Offset(0.0000, 0.5457),
      Offset(0.0015, 0.5545),
      Offset(0.0163, 0.5780),
      Offset(0.0383, 0.6075),
      Offset(0.0803, 0.6509),
      Offset(0.1141, 0.6789),
      Offset(0.1436, 0.6981),
      Offset(0.1488, 0.7047),
      Offset(0.1517, 0.7121),
      Offset(0.1576, 0.7548),
      Offset(0.1650, 0.7798),
      Offset(0.1664, 0.7916),
      Offset(0.1709, 0.8004),
      Offset(0.1768, 0.8225),
      Offset(0.1929, 0.8623),
      Offset(0.2018, 0.8770),
      Offset(0.2062, 0.8888),
      Offset(0.2305, 0.9278),
      Offset(0.2364, 0.9307),
      Offset(0.2452, 0.9307),
      Offset(0.4971, 0.8645),
      Offset(0.5559, 0.8645),
      Offset(0.5575, 0.8660),
      Offset(0.7754, 0.8719),
      Offset(0.7828, 0.8689),
      Offset(0.7909, 0.8593),
      Offset(0.8130, 0.8093),
      Offset(0.8365, 0.7327),
      Offset(0.8468, 0.6738),
      Offset(0.8483, 0.6443),
      Offset(0.8498, 0.6429),
      Offset(0.8498, 0.6178),
      Offset(0.8542, 0.6090),
      Offset(0.9116, 0.5516),
      Offset(0.9499, 0.5029),
      Offset(0.9676, 0.4764),
      Offset(0.9897, 0.4366),
      Offset(1.0000, 0.4146),
      Offset(1.0000, 0.4043),
      Offset(0.9890, 0.3918),
      Offset(0.8667, 0.2931),
      Offset(0.8491, 0.2769),
      Offset(0.8358, 0.2680),
      Offset(0.8115, 0.2452),
      Offset(0.7158, 0.0920),
      Offset(0.7003, 0.0722),
      Offset(0.6886, 0.0693),
    ],
    <Offset>[
      Offset(0.6532, 0.1281),
      Offset(0.6120, 0.1384),
      Offset(0.5722, 0.1517),
      Offset(0.5545, 0.1591),
      Offset(0.5508, 0.1627),
      Offset(0.5508, 0.1672),
      Offset(0.5707, 0.1782),
      Offset(0.6046, 0.1929),
      Offset(0.6694, 0.2341),
      Offset(0.6856, 0.2341),
      Offset(0.7047, 0.2298),
      Offset(0.7136, 0.2298),
      Offset(0.7195, 0.2268),
      Offset(0.7202, 0.2187),
      Offset(0.7158, 0.2098),
      Offset(0.6701, 0.1362),
      Offset(0.6635, 0.1296),
      Offset(0.6532, 0.1281),
    ],
    <Offset>[
      Offset(0.3086, 0.1856),
      Offset(0.2835, 0.1886),
      Offset(0.2754, 0.1952),
      Offset(0.2372, 0.2850),
      Offset(0.2342, 0.2982),
      Offset(0.2379, 0.3019),
      Offset(0.2806, 0.2961),
      Offset(0.3041, 0.2961),
      Offset(0.3056, 0.2945),
      Offset(0.3527, 0.2961),
      Offset(0.4102, 0.3063),
      Offset(0.4632, 0.3255),
      Offset(0.4912, 0.3402),
      Offset(0.5309, 0.3682),
      Offset(0.5773, 0.4161),
      Offset(0.6038, 0.4573),
      Offset(0.6068, 0.4647),
      Offset(0.6134, 0.4698),
      Offset(0.6179, 0.4698),
      Offset(0.6266, 0.4654),
      Offset(0.6694, 0.4345),
      Offset(0.6952, 0.4087),
      Offset(0.7143, 0.3852),
      Offset(0.7143, 0.3763),
      Offset(0.7099, 0.3675),
      Offset(0.6893, 0.3395),
      Offset(0.6414, 0.2902),
      Offset(0.5987, 0.2577),
      Offset(0.5545, 0.2327),
      Offset(0.5177, 0.2165),
      Offset(0.4882, 0.2062),
      Offset(0.4279, 0.1914),
      Offset(0.3793, 0.1856),
      Offset(0.3086, 0.1856),
    ],
    <Offset>[
      Offset(0.7371, 0.2828),
      Offset(0.7305, 0.2864),
      Offset(0.7305, 0.2909),
      Offset(0.7334, 0.2953),
      Offset(0.7474, 0.3107),
      Offset(0.7504, 0.3122),
      Offset(0.7563, 0.3107),
      Offset(0.7629, 0.2953),
      Offset(0.7629, 0.2879),
      Offset(0.7563, 0.2828),
      Offset(0.7371, 0.2828),
    ],
    <Offset>[
      Offset(0.8166, 0.3373),
      Offset(0.8115, 0.3424),
      Offset(0.7953, 0.3763),
      Offset(0.7835, 0.3954),
      Offset(0.7452, 0.4441),
      Offset(0.7003, 0.4860),
      Offset(0.6606, 0.5140),
      Offset(0.6325, 0.5302),
      Offset(0.6016, 0.5449),
      Offset(0.5472, 0.5641),
      Offset(0.4927, 0.5759),
      Offset(0.4661, 0.5773),
      Offset(0.4647, 0.5788),
      Offset(0.4175, 0.5788),
      Offset(0.4131, 0.5803),
      Offset(0.4080, 0.5869),
      Offset(0.4095, 0.6399),
      Offset(0.4213, 0.6870),
      Offset(0.4271, 0.7018),
      Offset(0.4352, 0.7084),
      Offset(0.4647, 0.7084),
      Offset(0.4661, 0.7069),
      Offset(0.5104, 0.7040),
      Offset(0.5722, 0.6907),
      Offset(0.6311, 0.6716),
      Offset(0.6782, 0.6509),
      Offset(0.7342, 0.6200),
      Offset(0.7828, 0.5861),
      Offset(0.8284, 0.5464),
      Offset(0.8616, 0.5118),
      Offset(0.8940, 0.4705),
      Offset(0.9190, 0.4293),
      Offset(0.9190, 0.4190),
      Offset(0.9050, 0.4050),
      Offset(0.8314, 0.3432),
      Offset(0.8225, 0.3373),
      Offset(0.8166, 0.3373),
    ],
    <Offset>[
      Offset(0.3115, 0.3505),
      Offset(0.3004, 0.3586),
      Offset(0.2769, 0.3954),
      Offset(0.2518, 0.4441),
      Offset(0.2416, 0.4691),
      Offset(0.2298, 0.5029),
      Offset(0.2195, 0.5427),
      Offset(0.2121, 0.5972),
      Offset(0.2106, 0.6723),
      Offset(0.2209, 0.7400),
      Offset(0.2372, 0.7931),
      Offset(0.2504, 0.8211),
      Offset(0.2533, 0.8314),
      Offset(0.2622, 0.8475),
      Offset(0.2688, 0.8542),
      Offset(0.2732, 0.8557),
      Offset(0.4013, 0.8232),
      Offset(0.4087, 0.8203),
      Offset(0.4124, 0.8152),
      Offset(0.4095, 0.8063),
      Offset(0.3844, 0.7695),
      Offset(0.3682, 0.7371),
      Offset(0.3579, 0.7091),
      Offset(0.3461, 0.6561),
      Offset(0.3447, 0.6222),
      Offset(0.3432, 0.6207),
      Offset(0.3432, 0.5913),
      Offset(0.3491, 0.5457),
      Offset(0.3550, 0.5206),
      Offset(0.3667, 0.4853),
      Offset(0.3888, 0.4382),
      Offset(0.4095, 0.4057),
      Offset(0.4256, 0.3852),
      Offset(0.4271, 0.3793),
      Offset(0.4234, 0.3741),
      Offset(0.4116, 0.3682),
      Offset(0.3660, 0.3550),
      Offset(0.3365, 0.3505),
      Offset(0.3115, 0.3505),
    ],
    <Offset>[
      Offset(0.2158, 0.3623),
      Offset(0.2055, 0.3667),
      Offset(0.2003, 0.3734),
      Offset(0.2047, 0.3866),
      Offset(0.2099, 0.3918),
      Offset(0.2180, 0.3881),
      Offset(0.2283, 0.3704),
      Offset(0.2283, 0.3645),
      Offset(0.2261, 0.3623),
      Offset(0.2158, 0.3623),
    ],
    <Offset>[
      Offset(0.4794, 0.4123),
      Offset(0.4698, 0.4205),
      Offset(0.4610, 0.4323),
      Offset(0.4404, 0.4661),
      Offset(0.4241, 0.5029),
      Offset(0.4227, 0.5132),
      Offset(0.4249, 0.5170),
      Offset(0.4338, 0.5199),
      Offset(0.4573, 0.5199),
      Offset(0.5045, 0.5140),
      Offset(0.5413, 0.5037),
      Offset(0.5464, 0.4986),
      Offset(0.5464, 0.4897),
      Offset(0.5346, 0.4676),
      Offset(0.5214, 0.4484),
      Offset(0.4941, 0.4197),
      Offset(0.4838, 0.4123),
      Offset(0.4794, 0.4123),
    ],
    <Offset>[
      Offset(0.1525, 0.4359),
      Offset(0.1414, 0.4470),
      Offset(0.0795, 0.5265),
      Offset(0.0722, 0.5398),
      Offset(0.0751, 0.5501),
      Offset(0.0913, 0.5707),
      Offset(0.1289, 0.6082),
      Offset(0.1422, 0.6171),
      Offset(0.1458, 0.6164),
      Offset(0.1502, 0.6090),
      Offset(0.1532, 0.5751),
      Offset(0.1635, 0.5221),
      Offset(0.1782, 0.4764),
      Offset(0.1782, 0.4647),
      Offset(0.1738, 0.4558),
      Offset(0.1583, 0.4359),
      Offset(0.1525, 0.4359),
    ],
    <Offset>[
      Offset(0.7666, 0.6745),
      Offset(0.7371, 0.6922),
      Offset(0.6929, 0.7143),
      Offset(0.6384, 0.7364),
      Offset(0.6179, 0.7423),
      Offset(0.6105, 0.7467),
      Offset(0.6054, 0.7533),
      Offset(0.5877, 0.7887),
      Offset(0.5877, 0.7961),
      Offset(0.5957, 0.7997),
      Offset(0.6384, 0.7997),
      Offset(0.6399, 0.8012),
      Offset(0.7313, 0.8027),
      Offset(0.7386, 0.7997),
      Offset(0.7423, 0.7961),
      Offset(0.7511, 0.7754),
      Offset(0.7629, 0.7400),
      Offset(0.7718, 0.7047),
      Offset(0.7747, 0.6900),
      Offset(0.7747, 0.6782),
      Offset(0.7725, 0.6745),
      Offset(0.7666, 0.6745),
    ],
    <Offset>[
      Offset(0.5045, 0.7673),
      Offset(0.4838, 0.7702),
      Offset(0.4772, 0.7739),
      Offset(0.4772, 0.7798),
      Offset(0.4802, 0.7843),
      Offset(0.4912, 0.7953),
      Offset(0.4971, 0.7982),
      Offset(0.5052, 0.7945),
      Offset(0.5184, 0.7754),
      Offset(0.5184, 0.7710),
      Offset(0.5162, 0.7688),
      Offset(0.5045, 0.7673),
    ],
];
const List<List<Offset>> _kF9B0FF = <List<Offset>>[
    <Offset>[
      Offset(0.3513, 0.1561),
      Offset(0.3498, 0.1576),
      Offset(0.3041, 0.1576),
      Offset(0.3027, 0.1591),
      Offset(0.2776, 0.1605),
      Offset(0.2629, 0.1635),
      Offset(0.2533, 0.1716),
      Offset(0.1886, 0.3232),
      Offset(0.1856, 0.3380),
      Offset(0.1907, 0.3432),
      Offset(0.1996, 0.3432),
      Offset(0.2408, 0.3314),
      Offset(0.2820, 0.3255),
      Offset(0.3557, 0.3270),
      Offset(0.3881, 0.3329),
      Offset(0.4220, 0.3432),
      Offset(0.4661, 0.3638),
      Offset(0.4956, 0.3829),
      Offset(0.5118, 0.3962),
      Offset(0.5464, 0.4337),
      Offset(0.5685, 0.4661),
      Offset(0.5759, 0.4823),
      Offset(0.5825, 0.4889),
      Offset(0.5928, 0.4889),
      Offset(0.6193, 0.4757),
      Offset(0.6664, 0.4433),
      Offset(0.7099, 0.3998),
      Offset(0.7334, 0.3689),
      Offset(0.7379, 0.3601),
      Offset(0.7379, 0.3498),
      Offset(0.7334, 0.3409),
      Offset(0.6937, 0.2938),
      Offset(0.6679, 0.2695),
      Offset(0.6355, 0.2445),
      Offset(0.5943, 0.2180),
      Offset(0.5530, 0.1973),
      Offset(0.4853, 0.1738),
      Offset(0.4205, 0.1605),
      Offset(0.3513, 0.1561),
    ],
    <Offset>[
      Offset(0.8049, 0.6436),
      Offset(0.7474, 0.6804),
      Offset(0.6974, 0.7069),
      Offset(0.6355, 0.7320),
      Offset(0.5722, 0.7511),
      Offset(0.5611, 0.7621),
      Offset(0.5523, 0.7798),
      Offset(0.5258, 0.8166),
      Offset(0.5229, 0.8225),
      Offset(0.5229, 0.8284),
      Offset(0.5309, 0.8336),
      Offset(0.5589, 0.8336),
      Offset(0.5604, 0.8350),
      Offset(0.7224, 0.8380),
      Offset(0.7239, 0.8395),
      Offset(0.7563, 0.8395),
      Offset(0.7607, 0.8380),
      Offset(0.7688, 0.8299),
      Offset(0.7820, 0.7989),
      Offset(0.7938, 0.7651),
      Offset(0.8056, 0.7224),
      Offset(0.8130, 0.6856),
      Offset(0.8159, 0.6502),
      Offset(0.8107, 0.6436),
      Offset(0.8049, 0.6436),
    ],
];
const List<List<Offset>> _kFCD8FF = <List<Offset>>[
    <Offset>[
      Offset(0.6709, 0.0957),
      Offset(0.6252, 0.1061),
      Offset(0.5559, 0.1281),
      Offset(0.5133, 0.1473),
      Offset(0.5096, 0.1509),
      Offset(0.5096, 0.1568),
      Offset(0.5191, 0.1635),
      Offset(0.5589, 0.1768),
      Offset(0.6075, 0.2003),
      Offset(0.6606, 0.2341),
      Offset(0.6841, 0.2548),
      Offset(0.6944, 0.2607),
      Offset(0.7121, 0.2607),
      Offset(0.7268, 0.2577),
      Offset(0.7518, 0.2577),
      Offset(0.7739, 0.2548),
      Offset(0.7761, 0.2511),
      Offset(0.7761, 0.2452),
      Offset(0.7702, 0.2334),
      Offset(0.7055, 0.1318),
      Offset(0.6937, 0.1097),
      Offset(0.6827, 0.0972),
      Offset(0.6709, 0.0957),
    ],
    <Offset>[
      Offset(0.2879, 0.3446),
      Offset(0.2732, 0.3491),
      Offset(0.2636, 0.3601),
      Offset(0.2372, 0.4043),
      Offset(0.2180, 0.4441),
      Offset(0.1944, 0.5103),
      Offset(0.1944, 0.5162),
      Offset(0.1827, 0.5618),
      Offset(0.1768, 0.6120),
      Offset(0.1782, 0.6959),
      Offset(0.1900, 0.7607),
      Offset(0.1944, 0.7710),
      Offset(0.1974, 0.7872),
      Offset(0.2136, 0.8314),
      Offset(0.2386, 0.8814),
      Offset(0.2526, 0.8954),
      Offset(0.2629, 0.8954),
      Offset(0.3365, 0.8748),
      Offset(0.4043, 0.8586),
      Offset(0.4264, 0.8513),
      Offset(0.4602, 0.8439),
      Offset(0.4706, 0.8395),
      Offset(0.4757, 0.8343),
      Offset(0.4743, 0.8240),
      Offset(0.4551, 0.8048),
      Offset(0.4359, 0.7813),
      Offset(0.4213, 0.7592),
      Offset(0.4036, 0.7253),
      Offset(0.3859, 0.6782),
      Offset(0.3785, 0.6281),
      Offset(0.3800, 0.5648),
      Offset(0.3932, 0.5073),
      Offset(0.4168, 0.4529),
      Offset(0.4359, 0.4220),
      Offset(0.4536, 0.3998),
      Offset(0.4551, 0.3881),
      Offset(0.4499, 0.3814),
      Offset(0.4249, 0.3682),
      Offset(0.3881, 0.3550),
      Offset(0.3616, 0.3491),
      Offset(0.3277, 0.3446),
      Offset(0.2879, 0.3446),
    ],
];
const List<List<Offset>> _kF17EB3 = <List<Offset>>[
    <Offset>[
      Offset(0.8004, 0.2828),
      Offset(0.7938, 0.2894),
      Offset(0.7865, 0.3159),
      Offset(0.7643, 0.3630),
      Offset(0.7452, 0.3925),
      Offset(0.7290, 0.4131),
      Offset(0.6900, 0.4521),
      Offset(0.6517, 0.4816),
      Offset(0.5987, 0.5111),
      Offset(0.5398, 0.5332),
      Offset(0.4912, 0.5434),
      Offset(0.4676, 0.5464),
      Offset(0.4161, 0.5464),
      Offset(0.4095, 0.5501),
      Offset(0.4050, 0.5589),
      Offset(0.4021, 0.5825),
      Offset(0.4036, 0.6355),
      Offset(0.4183, 0.6944),
      Offset(0.4315, 0.7253),
      Offset(0.4411, 0.7393),
      Offset(0.4455, 0.7423),
      Offset(0.4750, 0.7423),
      Offset(0.5221, 0.7364),
      Offset(0.5663, 0.7275),
      Offset(0.6458, 0.7025),
      Offset(0.6988, 0.6789),
      Offset(0.7518, 0.6495),
      Offset(0.8152, 0.6038),
      Offset(0.8343, 0.5877),
      Offset(0.8822, 0.5398),
      Offset(0.9072, 0.5103),
      Offset(0.9338, 0.4735),
      Offset(0.9470, 0.4514),
      Offset(0.9617, 0.4234),
      Offset(0.9632, 0.4131),
      Offset(0.9536, 0.4006),
      Offset(0.8181, 0.2887),
      Offset(0.8093, 0.2828),
      Offset(0.8004, 0.2828),
    ],
    <Offset>[
      Offset(0.1598, 0.3785),
      Offset(0.0501, 0.5162),
      Offset(0.0339, 0.5398),
      Offset(0.0339, 0.5501),
      Offset(0.0368, 0.5559),
      Offset(0.0677, 0.5957),
      Offset(0.1024, 0.6304),
      Offset(0.1392, 0.6583),
      Offset(0.1480, 0.6583),
      Offset(0.1517, 0.6532),
      Offset(0.1576, 0.5810),
      Offset(0.1679, 0.5250),
      Offset(0.1841, 0.4720),
      Offset(0.1974, 0.4382),
      Offset(0.1959, 0.4293),
      Offset(0.1856, 0.4131),
      Offset(0.1709, 0.3807),
      Offset(0.1672, 0.3785),
      Offset(0.1598, 0.3785),
    ],
];

/// 每个多边形组的填充色（与 logo-max.svg 的 fill 一一对应）。
const List<({Color color, List<List<Offset>> polygons})> _kBrandLayers =
    <({Color color, List<List<Offset>> polygons})>[
  (color: Color(0xFFBDD4E9), polygons: _kBDD4E9),
  (color: Color(0xFFFFFAFB), polygons: _kFFFAFB),
  (color: Color(0xFFF9B0FF), polygons: _kF9B0FF),
  (color: Color(0xFFFCD8FF), polygons: _kFCD8FF),
  (color: Color(0xFFF17EB3), polygons: _kF17EB3),
];

/// Ayla 图形标识。
///
/// 方形、无圆角（圆角由容器/系统决定，见 design.md §6.1）；
/// 尺寸即边长，内部按归一化坐标缩放，任意大小都不失真。
///
/// 用于：
/// - **页内标识**：放在 `Ayla` 字标**前面**横向并排 —— 直接用 [AylaBrandRow]；
/// - **加载界面**：字标**居中上方**单独一行 —— [AylaBrandMark] + [AylaBrandWordmark] 竖排。
class AylaBrandMark extends StatelessWidget {
  const AylaBrandMark({super.key, this.size = 24, this.semanticLabel});

  /// 边长（px）。与 web 的 `<BrandMark size>` 同名同义。最小建议 32
  /// （更小时互锁缝隙会糊成一团，见 design.md §6.1）。
  final double size;

  /// 可访问性标签。默认 null（装饰用）：标识紧邻字标时读屏不必重复念品牌名。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget mark = CustomPaint(
      size: Size.square(size),
      painter: _AylaBrandMarkPainter(),
    );
    if (semanticLabel == null) {
      return ExcludeSemantics(child: mark);
    }
    return Semantics(label: semanticLabel, image: true, child: mark);
  }
}

/// Ayla 渐变字标（web `.top-nav-logo` / `.auth-brand` / `.fullscreen-loader-brand`
/// 共用的 `linear-gradient(120deg, indigo-700, grape-700)` + `background-clip: text`）。
///
/// 与 `_GradientText`（login_page.dart 私有）同配方，抽成公开件供标识组合复用。
class AylaBrandWordmark extends StatelessWidget {
  const AylaBrandWordmark(
    this.text, {
    super.key,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    // 白描边：对齐 web 的 `-webkit-text-stroke: 0.35px` + `paint-order: stroke fill`。
    //
    // Flutter 没有 text-stroke。等价做法是「描边字形 + 渐变填充字形」两层叠加：
    // 描边宽度取 2×（描边居中跨在字形轮廓上，一半在里一半在外；后画的填充层盖住
    // 内侧，视觉上只剩外侧 0.35px）。
    //
    // 描边层**不能是第二个 Text**：`find.text()` 按 widget 树里的 Text.data 匹配，
    // 两层 Text 会让同一个字标命中 2 个 widget（2026-11-09 品牌基线红）。因此描边
    // 改由 [_BrandStrokePainter] 用 Canvas 绘制，整棵子树只保留一个 Text。
    final TextStyle strokeStyle = style.copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * _kBrandStrokePx
        ..strokeJoin = StrokeJoin.round
        ..color = AylaColors.brandStroke,
    );
    final TextPainter strokePainter = TextPainter(
      text: TextSpan(text: text, style: strokeStyle),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    return Stack(
      children: <Widget>[
        // ① 描边层：纯 Canvas 绘制，不产生第二个 Text widget。
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _BrandStrokePainter(strokePainter)),
          ),
        ),
        // ② 渐变填充层（盖住描边内侧，只留外侧细边）
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (Rect bounds) => cssLinearGradient(
            angleDeg: 120, // linear-gradient(120deg, --brand-blue, --brand-mid, --brand-pink)
            colors: AylaGradients.brand,
            stops: AylaGradients.brandStops,
            aspectRatio: bounds.width / (bounds.height == 0 ? 1 : bounds.height),
          ).createShader(bounds),
          child: Text(text, style: style),
        ),
      ],
    );
  }
}

/// 绘制字标白描边。与填充层共用同一段排版结果，避免出现第二个 `Text` widget。
class _BrandStrokePainter extends CustomPainter {
  const _BrandStrokePainter(this.painter);

  final TextPainter painter;

  @override
  void paint(Canvas canvas, Size size) {
    painter.paint(canvas, Offset((size.width - painter.width) / 2, (size.height - painter.height) / 2));
  }

  @override
  bool shouldRepaint(_BrandStrokePainter oldDelegate) =>
      oldDelegate.painter.text != painter.text || oldDelegate.painter.size != painter.size;
}

/// 白描边粗细（px）：对齐 logo 自带白色分隔带的比例，同 web 的 0.35px。
const double _kBrandStrokePx = 0.35;

/// 页内标识：**标识在字标前面**横向并排。
///
/// 对应 web 的 `<h1 class="auth-brand"><BrandMark/><span>Ayla</span></h1>`。
/// [gap] 默认取 web 的 `--sp-2`（转 `.auth-brand` 与 `.top-nav-logo` 的间距刻度）。
class AylaBrandRow extends StatelessWidget {
  const AylaBrandRow({
    super.key,
    required this.markSize,
    this.gap,
    this.textStyle,
    this.text = 'Ayla',
  });

  /// 标识边长。
  final double markSize;

  /// 标识与字标的间距；null = `AylaSpacing.sp2`。
  final double? gap;

  /// 字标样式；null = 继承（调用方通常传入既有页面标题样式）。
  final TextStyle? textStyle;

  /// 字标文本。
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        AylaBrandMark(size: markSize),
        SizedBox(width: gap ?? AylaSpacing.sp2),
        AylaBrandWordmark(text, style: textStyle ?? DefaultTextStyle.of(context).style),
      ],
    );
  }
}

/// 标识绘制：逐层填充多边形（even-odd 由 `PathFillType.evenOdd` 表达，
/// 与 SVG 的 `fill-rule="evenodd"` 一致 —— 互锁环的镂空全靠这一条）。
class _AylaBrandMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..isAntiAlias = true;
    for (final ({Color color, List<List<Offset>> polygons}) layer in _kBrandLayers) {
      final Path path = Path()..fillType = PathFillType.evenOdd;
      for (final List<Offset> polygon in layer.polygons) {
        if (polygon.isEmpty) continue;
        path.moveTo(polygon.first.dx * size.width, polygon.first.dy * size.height);
        for (int i = 1; i < polygon.length; i++) {
          path.lineTo(polygon[i].dx * size.width, polygon[i].dy * size.height);
        }
        path.close();
      }
      paint.color = layer.color;
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AylaBrandMarkPainter oldDelegate) => false;
}
