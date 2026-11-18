# 基础设施

本文的 Rails 路径和命令以 `backend/` 为基准。

## 本地与测试

需要 Ruby 3.4.12、PostgreSQL、Redis、ImageMagick。使用 RVM 时在 `backend/` 执行 `rvm use 3.4.12`。运行 `db:prepare` 前，在本机的 `backend/config/database.yml` 为 `development` 和 `test` 分别配置 PostgreSQL 连接，沿用原项目时数据库名为 `booking_web_development` 和 `booking_web_test`。也可以为当前 Rails 环境提供相应的 `DATABASE_URL`。

Sidekiq 默认连接 `redis://localhost:6379/0`，开发缓存使用内存，附件默认存 `backend/storage/`。已有本地环境迁移目录时，继续使用原来配套的 `config/credentials.yml.enc` 与 `config/master.key`，并保留已有附件。

```sh
cd backend
bundle install
bin/rails db:prepare
bin/rails settings:encryption_keys
bin/rails admin:create
bin/rails dartsass:build
bin/dev
```

`settings:encryption_keys` 只在本机加密 credentials 中补齐主密钥，不输出密钥，也不会覆盖已存在的值。`admin:create` 仅在没有管理员时创建 `admin / 123456` 超级管理员；可通过 `ADMIN_USERNAME`、`ADMIN_PASSWORD` 显式覆盖。已有账号时命令停止，不重置账号。

首次生成密钥后再启动 Web 和任务进程。另开终端运行 `bin/jobs`；定时任务由同一进程加载 `config/schedule.yml`，当前为空。任务主要传记录 ID，不传密钥或文件内容。

```sh
RAILS_ENV=test bin/rails db:prepare
bin/rails test test/models/admin_test.rb test/services/storage_settings_test.rb test/integration/admin_management_test.rb
bin/rails zeitwerk:check
bin/rubocop
bin/brakeman --quiet --no-pager
bin/bundler-audit
```

上例只运行管理模块相关测试；日常按改动选择文件，有明确影响再扩大范围。测试固定使用 `tmp/storage/` 和 Active Job 测试适配器，不连接 Redis 或真实 COS。基础存储测试位于 `test/lib/`，包含上传、读取、MiniMagick 缩放、分析及删除；COS 使用 SDK 假响应验证。

## 生产启动参数

启动配置不依赖系统配置表，ENV 优先、credentials 兜底：

| ENV | credentials | 用途 |
| --- | --- | --- |
| `DATABASE_URL` | `database.url` | PostgreSQL 连接 |
| `REDIS_SIDEKIQ_URL` | `redis.sidekiq_url` | 任务 Redis，生产必填 |
| `REDIS_CACHE_URL` | `redis.cache_url` | 缓存 Redis，生产必填 |

通过 credentials 提供数据库连接时，需在本机或部署环境的 `config/database.yml` 中读取 `database.url`。

仓库及镜像不包含本机的 credentials 密文和解密主密钥。各部署环境自行生成并保管 credentials，通过挂载提供密文，`RAILS_MASTER_KEY` 或本地 `config/master.key` 提供解密主密钥。`SECRET_KEY_BASE` 由 Rails 按标准机制读取，容器部署可在运行时通过 ENV 提供。

配置敏感字段使用 Rails Active Record Encryption。主密钥依次读取以下 ENV 或 credentials，不能存回系统配置表：

| ENV | credentials |
| --- | --- |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | `active_record_encryption.primary_key` |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | `active_record_encryption.deterministic_key` |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | `active_record_encryption.key_derivation_salt` |

数据库备份与这些密钥分别保管；丢失旧密钥后无法读取已有密文，不通过重新生成密钥修复。部署先执行迁移并准备密钥，再启动 Web / Sidekiq；所有进程使用同一套密钥。新建表使用 `timestamptz`，已有 Active Storage 时间字段保持原样。

Web 和任务进程分别启动：`RAILS_ENV=production bin/rails server`、`RAILS_ENV=production bin/jobs`。Sidekiq 默认并发 3，可用 `SIDEKIQ_CONCURRENCY` 调整；数据库连接池默认 5，可用 `DB_POOL` 调整，任务进程启动时校验并发不超过连接池。部署还需核算各 Web / Sidekiq 进程的总连接数。

从仓库根目录构建后端镜像，执行 `docker build -t booking_web backend`。

缓存与任务使用独立 Redis 配置。不同逻辑 DB 只隔离键空间；生产优先使用独立实例，任务实例配置持久化与 `noeviction`，避免缓存淘汰策略影响队列。资产预编译时使用 `SECRET_KEY_BASE_DUMMY=1`，不要求 Redis 或 COS 连通。

## COS 与系统配置

第三方配置统一由 `IntegrationSettings.read` 读取，优先级为：系统配置表 > ENV > credentials；仅未配置时回退，配置无效直接报错。无默认云密钥、桶名或地域。

超级管理员在 `/admins/system_settings/storage/edit` 维护存储配置。`settings` 使用唯一 `key` 和 JSONB `settings`，存储配置使用 `active_storage`、`tencent_cos` 两组；SecretId / SecretKey 子字段加密保存。`config.x.integration_settings_reader` 已连接此表，启动及资产编译时不查询设置表。

| 配置项 | ENV | credentials |
| --- | --- | --- |
| 存储方式 | `ACTIVE_STORAGE_SERVICE` | `active_storage.service` |
| SecretId | `TENCENT_COS_SECRET_ID` | `tencent_cos.secret_id` |
| SecretKey | `TENCENT_COS_SECRET_KEY` | `tencent_cos.secret_key` |
| 地域 | `TENCENT_COS_REGION` | `tencent_cos.region` |
| 桶名 | `TENCENT_COS_BUCKET` | `tencent_cos.bucket` |
| API 地址，可选 | `TENCENT_COS_ENDPOINT` | `tencent_cos.endpoint` |

存储方式未指定时使用本地；启用 COS 时设为 `tencent_cos`，并提供四项必填参数 SecretId、SecretKey、地域、桶名。API 地址缺省由地域推导，填写时须为 HTTPS COS API 地址。当前不接 CDN。

本地模式仅显示存储方式，COS 字段隐藏且不提交；切回 COS 后显示已保存配置的状态，密钥仍不回显。保存本地时，若 ENV / credentials 的生效结果也是本地或均未配置，则移除多余的系统存储方式值，来源继续显示 ENV / credentials 或默认；下层配置为 COS 时保留本地覆盖，确保切换有效。切回本地不删除已有 COS 参数。

密钥输入框不回显；未提交或留空保留，填新值才替换。来源以字段 label 后的 Badge 显示，placeholder 随来源变化。“清除系统配置”位于保存按钮旁，确认后仅删除本页的数据库配置，再按 ENV / credentials 回退；没有其他存储方式配置时恢复默认本地。配置缺失、无效或解密失败明确报错，不静默改用低优先级值。保存和清除均带版本校验，过期表单不能覆盖较新的配置。

Active Storage 会缓存连接实例。保存通过事务提交后刷新当前进程；其他 Web 请求和 Sidekiq 任务开始时检查配置指纹，变化时重建服务实例。仅保留指纹和客户端，不在 `Rails.cache` 中缓存密钥明文；已开始的操作继续使用其持有的客户端。配置错误时仍可直接打开设置页修正。

已有 COS 附件时，后台允许轮换密钥，阻止直接变更桶、地域或 API 地址；这些位置参数须先迁移文件，外部 ENV / credentials 的变更也需遵守这一点。切回本地只影响新文件，已有 COS 文件仍保留原服务读取能力。当前未使用真实 COS 凭据做联网验证，部署者配置后需验证自己的桶权限及上传、读取、删除。

默认 Active Storage 公开路由继续关闭；已有管理员认证，文件归属及业务上传、下载接口随业务模型接入。实际上传功能接入时采用[开发约定](../../AGENTS.md)的统一命名规则，本轮不添加业务上传入口。

## 管理员与操作日志

登录使用用户名，Devise 仅接账号密码、记住登录及登录统计，不提供公开注册或邮件找回。全部角色可凭原密码修改本人密码；超级管理员可以创建、编辑、停用账号并重置密码。新建留空密码为 `123456`，编辑留空保留原值；密码重置令旧登录失效，本人改密保留当前登录。停用在后续请求生效，至少保留一个启用超管。

账号管理、配置维护及日志查询仅限超级管理员；运营管理员、客服暂可访问现有只读预览，后续业务权限按用户确认实现。配置修改与账号写入的日志和数据一起提交，失败时整体回滚。

`logs` 保持提供的数据库结构，当前记录登录成功 / 失败、退出、管理员创建 / 编辑、本人改密及存储配置修改；只保存变更字段名等安全信息，不记录密码或 COS 密钥值。日志列表与详情只读，正式业务的分类、关联方式及记录时机后续确定。

## 应用约定

默认语言 `zh-CN`、时区 `Asia/Shanghai`，数据库按 UTC 存储。表单显式添加 `is-invalid` / `invalid-feedback`，Rails 不再生成 `.field_with_errors` 包裹。

后台控制器继承 `Admins::BaseController`。Pagy 仅计算分页，每页 20 条写在 `config/initializers/pagy.rb`，不接系统配置，也不接受客户端 `limit`；继续使用现有 Tabler 分页模板。

当前没有实时推送业务，Action Cable 的 `async` 仅占位；正式启用推送前改用 Redis 等跨进程适配器。日志过滤密钥、手机号、上传文件和搜索词；生产继续写 STDOUT，`/up` 用于应用启动检查，不检查数据库或 Redis 连通性。

真实密钥、证书私钥、`.env`、解密主密钥和真实数据库导出不提交仓库。示例只用占位内容；忽略规则不能替代提交前检查。
