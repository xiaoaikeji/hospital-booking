# 错误页插画

404 使用“寻找预约日历中的空白日期”场景。布局与按钮使用原生 Tabler；插画由已选 AI 原图矢量描摹而来，保留人物姿势，并修整嘴巴、眉毛和日历虚线。

- 当前素材：[浅色 SVG](../../public/error-assets/booking-calendar.svg)、[深色 SVG](../../public/error-assets/booking-calendar-dark.svg)，可编辑路径，透明背景。
- 复用 [公共片段](../../app/views/admins/shared/_booking_calendar_illustration.html.erb)；静态错误页预先内联同一份 SVG。修改素材后运行 `ruby script/build_error_pages.rb`，统一更新全部错误页。
- 必须内联使用，主题变量才能从页面继承；通过 `<img src="…svg">` 引用无法继承外部页面的主题色。
- 蓝色区域引用 `--tblr-primary`，使用相对 OKLCH 保留明暗层次；肤色保持自然。原生 `hide-theme-dark` / `hide-theme-light` 切换明暗素材，无额外切换脚本。
- SVG 宽度封顶 520px，使用 `img-fluid` 缩小以适应窄屏，避免宽屏矮窗口将图片等比例放得过高。
- 描摹使用 [VTracer](https://pypi.org/project/vtracer/1.0.0a4/) 离线生成静态路径，不是项目运行依赖；过滤小色块后手工补细节。参考位图与原始提示词保留在下方。
- 公共 SVG 完成主题及细节检查后，新增页面直接复用；只有新增或修改 SVG 时才重新检查插画，不逐页重复检查。

参考位图：[浅色 WebP](../../public/error-assets/booking-404-light.webp)、[深色 WebP](../../public/error-assets/booking-404-dark.webp)，均由内置 `image_gen` 生成，1600 × 1200，4:3，透明背景；当前页面使用上面的 SVG。

## 浅色图提示词

```text
Use case: illustration-story. Asset type: transparent hero illustration for a booking-system 404 webpage, not a mockup of the webpage. Create one polished flat vector-style illustration on a genuinely transparent background, canvas exactly 1600×1200 pixels (4:3). Subject: a large appointment wall calendar with a clean grid of date cells, one cell conspicuously empty with a dashed outline and a small question-mark symbol. A single friendly adult character in blue clothes holds a magnifying glass and searches that empty calendar cell. A few small floating calendar cards and simple clock icons support the booking theme. Clean modern SaaS illustration, close to Tabler's official flat illustrations: rounded geometric shapes, restrained details, crisp edges, generous negative space around the complete scene. Light-theme palette: primary blue #066fd1, soft blue-gray #e9ecf2, skin tone #ffcb9d, subtle white highlights, a few pale blue decorative shapes local to the objects, and a very subtle soft ground shadow. Calendar and character form one balanced centered composition; keep the entire artwork comfortably inside the canvas with transparent margins. No opaque backdrop, no full-canvas color block, no UI screenshot, no border frame, no logo, no words, no letters, no numbers, no watermark. The one small question-mark symbol is allowed. Deliver a true alpha-transparent PNG.
```

## 深色图编辑提示词

```text
Use case: precise-object-edit. Asset type: dark-theme version of the supplied transparent illustration for a booking-system 404 webpage. Input image 1 is the EDIT TARGET, the completed light-theme master. Change ONLY its color palette for dark UI. Preserve the exact same composition, canvas aspect ratio 4:3, camera/crop, calendar grid geometry, empty dashed calendar cell and its one question-mark symbol, the friendly character's identity and pose, magnifying glass, floating calendar cards, clocks, decorative shapes, ground silhouette, and transparent margins. Do not add, remove, relocate, resize, or redesign objects. Maintain crisp clean flat vector-like SaaS illustration quality. Replace the large white/light-blue calendar and cards with deeper blues #1a2030 / #232b41, use blue-gray #33445f for date cells, and slightly brighter accent blue #4299e1 for key details and clothing. Keep warm skin #ffcb9d readable. Use subtle medium-blue edge highlights so objects are readable on a dark webpage. No pure white, no heavy black shadows, no opaque backdrop and no full-canvas rectangle. Preserve genuine alpha transparency. No words, no letters, no numbers, no watermark; preserve the one small question-mark symbol. Final export target: 1600×1200 transparent PNG, same framing as input.
```
