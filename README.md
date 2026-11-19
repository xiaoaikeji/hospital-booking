# 小艾预约挂号系统

面向单家医院或诊所的预约挂号项目。管理员通过 Rails 后台管理应用和配置，就诊人通过微信小程序浏览医生和门诊排班。项目仍在开发中，小程序的预约流程目前使用本地示例数据。

[功能概览](#功能概览) · [快速开始](#快速开始) · [项目目录](#项目目录) · [许可](#许可)

## 功能概览

| 模块 | 可以做什么 |
| --- | --- |
| 后台管理 | 超级管理员可维护管理员账号、配置存储和默认外观、查看全部后台操作日志。运营和客服可查看自己的操作日志。 |
| 应用管理 | 一家机构可管理多个小程序。超级管理员可为微信小程序配置平台授权、选择代码模板、上传体验版、提交审核和发布版本。后台代小程序上传、提审及发布需要配置微信第三方平台，并取得目标小程序授权。 |
| 就诊小程序 | 可按日期或医生查看排班、选择时段并填写预约信息。当前提交仅校验表单，实际挂号和预约记录仍待接入。 |

## 快速开始

### 管理后台

准备 Ruby 3.4.12、Bundler、PostgreSQL、Redis 和 ImageMagick。启动 PostgreSQL 和 Redis 后，从仓库根目录安装后端依赖。

```sh
cd backend
bundle install
```

按[本地运行指南](docs/setup/本地运行.md#管理后台)配置数据库连接和初始账号。首次新建环境时，在同一终端依次运行下列命令，编辑加密凭据时保存并退出。

```sh
bin/rails credentials:edit
bin/rails db:prepare
bin/rails settings:encryption_keys
bin/rails admin:create
bin/rails dartsass:build
bin/dev
```

在另一个终端进入 `backend/`，运行 `bin/jobs` 启动后台任务。使用初始化时创建的管理员账号登录[本机管理后台](http://localhost:3000/admins/sign_in)。

### 微信小程序

1. 安装 HBuilderX 和微信开发者工具，用 HBuilderX 打开仓库的 `miniapp/` 目录。
2. 选择「运行 → 运行到小程序模拟器 → 微信开发者工具」，进入首页后可打开「预约挂号」查看医生和排班。
3. 需要真机预览时，在 `miniapp/manifest.json` 的 `mp-weixin.appid` 填入自己的小程序 AppID。首次连接开发者工具的设置见[小程序运行指南](docs/setup/本地运行.md#微信小程序)。

## 项目目录

- [backend/](backend/) 包含 Rails 服务端、Tabler 管理页面和后台任务。
- [miniapp/](miniapp/) 包含使用 uni-app 和 Vue 3 编写的微信小程序。
- [docs/](docs/) 提供运行和部署说明。生产环境、Redis 和腾讯云 COS 配置见[后端部署与配置](docs/setup/部署与配置.md)。

## 许可

仓库目前尚未声明项目整体的许可证。随后台分发的第三方组件保留各自的版权与许可声明，包括 [Tabler（MIT）](backend/vendor/licenses/tabler/LICENSE)、[Tom Select（Apache 2.0）](backend/vendor/licenses/tabler/tom-select-LICENSE) 和 [Vanilla Calendar Pro（MIT）](backend/vendor/licenses/tabler/vanilla-calendar-pro-LICENSE)。
