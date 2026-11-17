# 独立错误页

用途：展示请求错误、访问限制、系统故障和浏览器升级提示。统一采用已确认的 404 布局及主题 SVG。

[预览全部页面](http://192.168.1.21:3000/error-pages.html)。

| 页面 | 用途与触发位置 |
| --- | --- |
| `/400.html` | 请求格式有误；Rails 请求解析 |
| `/403.html` | 没有访问权限；权限检查 |
| `/404.html` | 页面或记录不存在；Rails 路由、记录查找 |
| `/409.html` | 数据或预约状态冲突；并发检查、业务判断 |
| `/413.html` | 内容过大；上传限制、网关 |
| `/422.html` | 请求无法处理；Rails 安全校验等 |
| `/429.html` | 操作频繁；限流规则 |
| `/500.html` | 系统内部出错；Rails 未处理异常 |
| `/502.html` | 网关连接后端失败；网关 |
| `/503.html` | 维护或服务不可用；服务端、网关 |
| `/504.html` | 后端响应超时；网关 |
| `/406-unsupported-browser.html` | 浏览器过旧；现有 `allow_browser` 检查，区别于普通 406 |

- 公共模板：[shared/error_page](../../app/views/admins/shared/_error_page.html.erb)。状态文案和按钮集中在 [build_error_pages.rb](../../script/build_error_pages.rb) 中。
- 品牌标识与导航共用 [brand_mark](../../app/views/layouts/admins/_brand_mark.html.erb)。修改公共模板、品牌组件或 [SVG 素材](error-illustrations.md) 后，在项目根目录运行 `ruby script/build_error_pages.rb`，统一输出上述静态页及预览目录，无需启动 Rails。
- 后续复用已验证的 SVG 时，只检查新增文案、按钮和页面访问；新增或改动 SVG 后再检查图形及主题适配。
- `/xxx.html` 是展示预览；实际异常应由 Rails、权限及限流逻辑返回相应 HTTP 状态。网关产生的 502、503、504 需在部署时映射到对应静态文件及 `error-assets/`。
