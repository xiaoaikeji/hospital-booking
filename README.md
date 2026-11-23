<h1 align="center">
  <img src="backend/public/icon.svg" width="44" height="44" align="absmiddle" alt="">
  小艾预约挂号系统
</h1>

<p align="center">供单家医院或诊所自部署的微信预约挂号小程序与管理后台。</p>

<p align="center">
  <img src="https://img.shields.io/badge/Rails-8.1-CC342D" alt="Rails 8.1">
  <img src="https://img.shields.io/badge/Tabler-1.7-066FD1" alt="Tabler 1.7">
  <img src="https://img.shields.io/badge/uni--app-Vue_3-317859" alt="uni-app · Vue 3">
</p>

<p align="center">
  <a href="#功能概览">功能概览</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="docs/setup/部署与配置.md">部署指南</a> ·
  <a href="docs/">使用文档</a>
</p>

## 功能概览

小程序支持微信登录、读取本人资料和按需验证账号手机号。当前排班为示例数据，游客 AppID 可在本机体验模拟预约和支付。医院正式下单和支付将在预约业务阶段接入。

| 模块 | 主要功能 |
| --- | --- |
| 门诊预约 | 选时段、查预约 |
| 应用管理 | 小程序与公众号 |
| [页面配置](docs/setup/本地运行.md#联调页面配置) | 设置轮播和菜单 |
| [公众号](docs/setup/通知使用.md) | 菜单与渠道码 |
| [消息通知](docs/notifications.md) | 模板消息与补发 |
| [通用海报](docs/posters.md) | 制作带码海报 |
| 后台管理 | 账号权限与日志 |
| [任务监控](docs/background-jobs.md) | 队列与失败任务 |

超级管理员可维护应用和系统设置、查看全部操作日志。运营和客服可查看自己的操作记录。

## 快速开始

### 管理后台

准备 Ruby 3.4.12、Bundler、PostgreSQL、Redis 和 ImageMagick。启动 PostgreSQL 和 Redis，按本地运行指南配置数据库连接。[数据库配置示例](docs/setup/本地运行.md#管理后台)

首次安装时，从仓库根目录运行以下命令。`credentials:edit` 打开编辑器后，保存并退出，再继续初始化。

```sh
cd backend
bundle install
bin/rails credentials:edit
bin/rails db:prepare
bin/rails settings:encryption_keys
bin/rails admin:create
bin/rails dartsass:build
bin/dev
```

在另一个终端进入 `backend/`，运行 `bin/jobs` 启动后台任务。用刚创建的管理员账号登录。[本机后台](http://localhost:3000/admins/sign_in)

### 微信小程序

1. 用 HBuilderX 打开 `miniapp/`，选择「运行 → 运行到小程序模拟器 → 微信开发者工具」。运行和扫码预览默认连开发后台，发行固定连医院正式后台。临时切换只需修改 `miniapp/config/api.js` 中的 `API_TARGET` 并重新运行。[开发与正式地址的填写位置](docs/setup/本地运行.md#选择小程序后台)
2. 预览示例排班时，进入首页的「预约挂号」。联调登录、轮播和菜单时，在后台登记并启用工程所用的微信 AppID。[小程序联调步骤](docs/setup/本地运行.md#联调页面配置)

## 项目目录

| 目录 | 内容 |
| --- | --- |
| [`backend/`](backend/) | 后台与 API |
| [`miniapp/`](miniapp/) | 微信小程序源码 |
| [`docs/`](docs/) | 安装与使用指南 |

## 许可

项目整体的许可证尚未声明。随附组件的许可可分别查阅 [Tabler（MIT）](backend/vendor/licenses/tabler/LICENSE)、[Tom Select（Apache 2.0）](backend/vendor/licenses/tabler/tom-select-LICENSE) 和 [Vanilla Calendar Pro（MIT）](backend/vendor/licenses/tabler/vanilla-calendar-pro-LICENSE)。
