# LumaRoute 原创猫形菜单图标

生成日期：2026-10-15。工具：Codex 内置 `imagegen`，文字生成，无参考图输入。原始结果保存为 `LumaRoute-cat-source.png`，保留真实透明通道。

`LumaRoute-menu-cat.png`（18×18）和 `LumaRoute-menu-cat@2x.png`（36×36）由主图裁去透明留白、等比例缩放生成；没有用代码重画猫形。重新生成尺寸：

```sh
swift script/build_menu_icon.swift
```

菜单使用 macOS template image 机制，依据 alpha 自动适配深浅色外观。当前图标不是 ClashX / ClashX.Meta 素材；历史素材来源声明保留在 [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)。

LumaRoute 自有素材可授权的权利按根目录 MIT 提供，署名 onlyone1019。生成工具不构成对全球所有现有标志均无相似性的保证。

## 完整生成提示

```text
Use case: logo-brand. Asset type: original macOS menu bar template PNG icon for LumaRoute, a native proxy manager. Generate a single original, distinctive CAT HEAD pictogram, designed from scratch without reference images. Solid pure black silhouette with genuinely transparent background, including transparent negative-space facial cutouts. Front-facing compact cat head, two clear triangular ears with subtly unequal angles, gently squared rounded cheeks, calm small eyes made of two short broad slanted cutouts and a very small geometric nose cutout. Strong simple shape, readable at 18x18 points, thick geometry, extremely restrained details, no whisker hairlines, no circles enclosing it, no body, no text or letters, no numbers, no gradient, no shadows, no outlines outside silhouette, no color except black. Contemporary friendly precise native macOS utility feel. Center the ONE icon on a square canvas with approximately 12 percent empty padding. This is an original new graphic; do not imitate existing software logos, ClashX, famous cat mascots, GitHub or any branded cat icon. Production asset, not a mockup or presentation sheet. Alpha transparency must be real; no checkerboard painted into the image.
```
