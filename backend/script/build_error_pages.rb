#!/usr/bin/env ruby
# Build static fallback pages without booting Rails or connecting to services.
require "erb"

ROOT = File.expand_path("..", __dir__)
HOME_ACTION = { label: "返回后台首页", href: "/admins", icon: :arrow }.freeze
LIST_ACTION = { label: "查看预约列表", href: "/admins/reservations", icon: :calendar }.freeze

ERROR_PAGES = [
  { status: 400, label: "请求格式有误", heading: [ "请求格式", "有误" ],
    description: "请求内容可能不完整或格式不正确，请重新打开页面后再操作。" },
  { status: 403, label: "没有访问权限", heading: [ "您暂无", "访问权限" ],
    description: "当前账号没有访问此内容的权限，如有需要请联系管理员。" },
  { status: 404, label: "页面不存在", heading: [ "找不到", "您要的页面" ],
    description: "链接可能有误，或对应内容已被移除。" },
  { status: 409, label: "数据或状态冲突", heading: [ "数据已", "发生变化" ],
    description: "预约可能已被其他人更新，或状态已发生变化。请返回列表查看最新信息。",
    actions: [ LIST_ACTION, HOME_ACTION ] },
  { status: 413, label: "内容超过大小限制", heading: [ "内容超过", "大小限制" ],
    description: "上传的文件或提交的内容过大，请缩小后再操作。",
    actions: [ LIST_ACTION, HOME_ACTION ] },
  { status: 422, label: "请求无法处理", heading: [ "请求无法", "处理" ],
    description: "页面可能已过期，或提交内容未通过安全校验。请重新打开页面后再操作。" },
  { status: 429, label: "操作过于频繁", heading: [ "操作有些", "频繁" ],
    description: "您在短时间内进行了较多操作，请稍后再试。" },
  { status: 500, label: "系统内部出错", heading: [ "系统内部", "出错" ],
    description: "系统遇到了一点问题，请稍后重新访问。" },
  { status: 502, label: "服务连接失败", heading: [ "服务暂时", "连接失败" ],
    description: "网关暂时无法连接后台服务，请稍后再试。" },
  { status: 503, label: "服务暂不可用", heading: [ "服务暂", "不可用" ],
    description: "系统可能正在维护或暂时繁忙，请稍后再访问。" },
  { status: 504, label: "服务响应超时", heading: [ "服务响应", "超时" ],
    description: "后台服务未能及时响应，请稍后再试。" },
  { status: 406, file: "406-unsupported-browser.html", badge: "浏览器版本过旧", label: "浏览器过旧", browser: true,
    heading: [ "请升级或", "更换浏览器" ],
    description: "当前浏览器版本较旧，请更新至最新版，或使用其他现代浏览器访问。",
    actions: [
      { label: "下载 Chrome", href: "https://www.google.com/chrome/", icon: :external, external: true },
      { label: "下载 Edge", href: "https://www.microsoft.com/edge/download", icon: :external, external: true }
    ] }
].freeze

ICON_PATHS = {
  arrow: [ "M5 12l14 0", "M5 12l6 6", "M5 12l6 -6" ],
  calendar: [ "M4 5m0 2a2 2 0 0 1 2 -2h12a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2z", "M16 3l0 4", "M8 3l0 4", "M4 11l16 0", "M8 15h2v2h-2z" ],
  external: [ "M12 6h-6a2 2 0 0 0 -2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2 -2v-6", "M11 13l9 -9", "M15 4h5v5" ]
}.freeze

class ErrorPageRenderer
  include ERB::Util
  attr_reader :page, :illustration_markup, :icons, :brand_markup

  def initialize(page, illustration_markup, icons, brand_markup)
    @page, @illustration_markup, @icons, @brand_markup = page, illustration_markup, icons, brand_markup
  end

  # Only trusted project SVG and native icon strings are passed here.
  def raw(value) = value

  def render(template)
    ERB.new(template, trim_mode: "-").result(binding).lines.map(&:rstrip).join("\n") + "\n"
  end
end

icons = ICON_PATHS.transform_values do |paths|
  body = paths.map { |path| %(<path d="#{path}" />) }.join
  %(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false" class="icon">#{body}</svg>)
end
illustration_markup = %w[booking-calendar.svg booking-calendar-dark.svg].map do |file|
  File.read(File.join(ROOT, "public/error-assets", file))
end.join("\n")
brand_markup = File.read(File.join(ROOT, "app/views/layouts/admins/_brand_mark.html.erb")).rstrip
template = File.read(File.join(ROOT, "app/views/admins/shared/_error_page.html.erb"))
pages = ERROR_PAGES.map do |definition|
  page = definition.merge(
    file: definition.fetch(:file, "#{definition.fetch(:status)}.html"),
    badge: definition.fetch(:badge, "#{definition.fetch(:status)} · #{definition.fetch(:label)}"),
    actions: definition.fetch(:actions, [ HOME_ACTION, LIST_ACTION ])
  )
  output = ErrorPageRenderer.new(page, illustration_markup, icons, brand_markup).render(template)
  File.write(File.join(ROOT, "public", page.fetch(:file)), output)
  page
end

links = pages.map do |page|
  label = ERB::Util.h(page.fetch(:badge))
  %(<div class="col-sm-6 col-lg-4"><a href="/#{page.fetch(:file)}" class="card card-link"><div class="card-body"><h2 class="card-title mb-2">#{label}</h2><p class="text-secondary mb-0">#{ERB::Util.h(page.fetch(:description))}</p></div></a></div>)
end.join("\n")
File.write(File.join(ROOT, "public/error-pages.html"), <<~HTML)
  <!doctype html>
  <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="robots" content="noindex, nofollow">
      <title>错误页预览 · Booking</title>
      <link rel="icon" href="/icon.svg?v=2" type="image/svg+xml">
      <link rel="stylesheet" href="/error-assets/tabler.min.css">
      <link rel="stylesheet" href="/error-assets/tabler-themes.min.css">
      <link rel="stylesheet" href="/error-assets/typography.css">
    </head>
    <body>
      <script src="/error-assets/tabler-theme.min.js"></script>
      <main class="page">
        <div class="container-xl py-4">
          <div class="page-header mt-0 mb-4"><div class="row align-items-center"><div class="col"><h1 class="page-title">错误页预览</h1></div><div class="col-auto"><a href="/admins" class="btn">返回后台首页</a></div></div></div>
          <div class="row row-cards row-deck">#{links}</div>
        </div>
      </main>
    </body>
  </html>
HTML
puts "已生成 #{pages.length} 个错误页及 /error-pages.html 预览目录"
